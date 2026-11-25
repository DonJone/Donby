import AppKit
import MetalKit
import CoreVideo
import CoreGraphics
import DonbyKernelC

// MARK: - Metal Layer View

public final class DKMetalLayerView: NSView {
    public var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var textureCache: CVMetalTextureCache?
    var commandQueue: MTLCommandQueue?
    var device: MTLDevice?

    // Unified HDR/DoVi/SDR YCbCr pipeline, BGRA fallback pipeline, and linear-blended subtitle overlay pipeline
    var pipelineVideoMaster: MTLRenderPipelineState?
    var pipelineBGRA: MTLRenderPipelineState?
    var pipelineSubtitle: MTLRenderPipelineState?

    let renderLock = NSLock()
    let sizeLock = NSLock()
    let snapshotLock = NSLock()
    var snapshotPixelBuffer: CVPixelBuffer?
    var snapshotColorUniforms = DKGpuColorUniforms()
    var cachedDrawableSize: CGSize = .zero
    private var cachedEDRHeadroom: Float = 1.0
    var layoutGeneration: UInt64 = 0
    private var screenObserver: NSObjectProtocol?
    var _lastRenderSkipReason: String = ""
    var _hasExternalDisplayLink: Bool = false
    public var hasExternalDisplayLink: Bool {
        get {
            sizeLock.lock()
            defer { sizeLock.unlock() }
            return _hasExternalDisplayLink
        }
        set {
            sizeLock.lock()
            _hasExternalDisplayLink = newValue
            sizeLock.unlock()
        }
    }
    public var lastRenderSkipReason: String {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return _lastRenderSkipReason
    }

    // Subtitle GPU texture cache (updated only when subtitle serial changes)
    var subtitleTextures: [MTLTexture?] = [nil, nil, nil]
    var subtitleTextureWriteIdx: Int = 0
    var subtitleTexture: MTLTexture?
    var subtitleTexWidth: Int = 0
    var subtitleTexHeight: Int = 0
    var hasActiveSubtitle: Bool = false
    private var subtitleBoundsY0: Int32 = 0
    private var subtitleBoundsY1: Int32 = 0
    private var subtitleCanvasH: Int32 = 0
    var currentSubtitleLiftNDC: Float = 0.0
    var _subtitleHDRPeakNits: Float = 203.0
    private var _controlsOcclusionHeightPoints: CGFloat = 0.0
    private var _antiOcclusionEnabled: Bool = false
    private var cachedViewPointSize: CGSize = .zero

    public var subtitleHDRPeakNits: Float {
        get { sizeLock.lock(); defer { sizeLock.unlock() }; return _subtitleHDRPeakNits }
        set {
            sizeLock.lock()
            let changed = abs(_subtitleHDRPeakNits - newValue) > 0.5
            _subtitleHDRPeakNits = newValue
            if changed { _needsRedrawOnSameFrame = true }
            let driverActive = _hasExternalDisplayLink
            sizeLock.unlock()
            if changed && !driverActive { renderLastPixelBuffer() }
        }
    }

    public var controlsOcclusionHeightPoints: CGFloat {
        get { sizeLock.lock(); defer { sizeLock.unlock() }; return _controlsOcclusionHeightPoints }
        set {
            sizeLock.lock()
            let changed = abs(_controlsOcclusionHeightPoints - newValue) > 0.5
            _controlsOcclusionHeightPoints = newValue
            if changed { _needsRedrawOnSameFrame = true }
            sizeLock.unlock()
        }
    }

    public var antiOcclusionEnabled: Bool {
        get { sizeLock.lock(); defer { sizeLock.unlock() }; return _antiOcclusionEnabled }
        set {
            sizeLock.lock()
            let changed = (_antiOcclusionEnabled != newValue)
            _antiOcclusionEnabled = newValue
            if changed { _needsRedrawOnSameFrame = true }
            sizeLock.unlock()
        }
    }

    public func updateSubtitleVerticalBounds(y0: Int32, y1: Int32, canvasH: Int32) {
        sizeLock.lock()
        subtitleBoundsY0 = y0
        subtitleBoundsY1 = y1
        subtitleCanvasH = canvasH
        sizeLock.unlock()
    }

    public func stepSubtitleLiftAnimation(dt: Float) -> Bool {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        let targetNDC: Float
        let viewH = Float(max(1.0, cachedViewPointSize.height))
        if !_antiOcclusionEnabled || _controlsOcclusionHeightPoints <= 0.5 {
            targetNDC = 0.0
        } else if subtitleCanvasH <= 0 || subtitleBoundsY1 <= subtitleBoundsY0 {
            // Keep existing lift offset across brief inter-cue silence so newly appearing subtitles
            // NEVER play a bottom-to-top slide-up entrance animation.
            return false
        } else {
            let subBottomRatio = Float(subtitleBoundsY1) / Float(subtitleCanvasH)
            let subTopRatio = Float(subtitleBoundsY0) / Float(subtitleCanvasH)
            let subBottomNDC = 1.0 - 2.0 * subBottomRatio
            let subTopNDC = 1.0 - 2.0 * subTopRatio
            let controlsTopNDC = -1.0 + 2.0 * (Float(_controlsOcclusionHeightPoints) / viewH)
            if subBottomNDC < controlsTopNDC {
                let rawLift = controlsTopNDC - subBottomNDC
                let maxLift = max(0.0, 0.92 - subTopNDC)
                targetNDC = min(maxLift, max(0.0, rawLift))
            } else {
                targetNDC = 0.0
            }
        }
        // Traditional instant cinema placement: snap directly to target position with zero bottom-up slide animation.
        if abs(targetNDC - currentSubtitleLiftNDC) > 0.0001 {
            currentSubtitleLiftNDC = targetNDC
            _needsRedrawOnSameFrame = true
            return true
        }
        return false
    }

    public internal(set) var lastPixelBuffer: CVPixelBuffer?
    public static weak var activeInstance: DKMetalLayerView?
    public internal(set) var lastColorUniforms = DKGpuColorUniforms()
    var _needsRedrawOnSameFrame: Bool = false
    public var needsRedrawOnSameFrame: Bool {
        get {
            sizeLock.lock()
            defer { sizeLock.unlock() }
            return _needsRedrawOnSameFrame
        }
        set {
            sizeLock.lock()
            _needsRedrawOnSameFrame = newValue
            sizeLock.unlock()
        }
    }
    public var onDetachFromWindow: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupMetal()
        registerScreenObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupMetal()
        registerScreenObserver()
    }

    deinit {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.isOpaque = true
        return layer
    }

    private func registerScreenObserver() {
        updateScreenHeadroom()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let prevHeadroom = self.currentEDRHeadroom
            self.updateScreenHeadroom()
            let headroomChanged = abs(self.currentEDRHeadroom - prevHeadroom) > 0.001
            if headroomChanged {
                self.needsRedrawOnSameFrame = true
                // Never contend on renderLock / nextDrawable() synchronously on the main thread
                // while CVDisplayLink is active: macOS EDR ramp fires didChangeScreenParameters
                // at 60Hz for ~1s on first HDR/EDR layer presentation.
                if !self.hasExternalDisplayLink {
                    self.renderLastPixelBuffer()
                }
            }
        }
    }

    private func updateScreenHeadroom() {
        let screen = window?.screen ?? NSScreen.main
        let headroom = Float(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
        sizeLock.lock()
        cachedEDRHeadroom = max(1.0, headroom)
        sizeLock.unlock()
    }

    public var currentEDRHeadroom: Float {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return cachedEDRHeadroom
    }

    public override func layout() {
        super.layout()
        updateDrawableSize()
        updateScreenHeadroom()
        needsRedrawOnSameFrame = true
        if !hasExternalDisplayLink {
            renderLastPixelBuffer()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Self.activeInstance = self
        }
        updateDrawableSize()
        updateScreenHeadroom()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            if Self.activeInstance === self {
                Self.activeInstance = nil
            }
            onDetachFromWindow?()
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        updateScreenHeadroom()
    }

    public func currentFrameSnapshotInput() -> (pixelBuffer: CVPixelBuffer, colorUniforms: DKGpuColorUniforms, edrHeadroom: Float)? {
        snapshotLock.lock()
        let pb = snapshotPixelBuffer
        let uniforms = snapshotColorUniforms
        snapshotLock.unlock()
        guard let pb else { return nil }
        return (pb, uniforms, currentEDRHeadroom)
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let targetSize = CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )

        if metalLayer.drawableSize != targetSize {
            metalLayer.drawableSize = targetSize
        }

        sizeLock.lock()
        cachedDrawableSize = targetSize
        cachedViewPointSize = size
        layoutGeneration &+= 1
        sizeLock.unlock()
    }

    private func setupMetal() {
        guard let dev = MTLCreateSystemDefaultDevice() else { return }
        assert(MemoryLayout<DKGpuColorUniforms>.stride == 3088, "Swift DKGpuColorUniforms stride mismatch")
        self.device = dev
        self.metalLayer.device = dev
        self.metalLayer.pixelFormat = .rgba16Float
        self.metalLayer.wantsExtendedDynamicRangeContent = true
        self.metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        self.metalLayer.framebufferOnly = true
        self.commandQueue = dev.makeCommandQueue()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &textureCache)

        if let pipelines = DKMetalPipelineSet.cached(device: dev, shaderSource: Self.metalShaderSource, pixelFormat: .rgba16Float) {
            self.pipelineVideoMaster = pipelines.videoPipeline
            self.pipelineBGRA = pipelines.bgraPipeline
            self.pipelineSubtitle = pipelines.subPipeline
        } else {
            print("[DonbyMetal] Pipeline create failed")
        }
    }
}
