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
    let metalWorkQueue = DispatchQueue(label: "com.donby.metal.work", qos: .userInteractive)
    var snapshotPixelBuffer: CVPixelBuffer?
    var snapshotColorUniforms = DKGpuColorUniforms()
    var cachedDrawableSize: CGSize = .zero
    private var cachedEDRHeadroom: Float = 1.0
    var layoutGeneration: UInt64 = 0
    private var screenObserver: NSObjectProtocol?
    var _lastRenderSkipReason: String = ""
    var _hasExternalDisplayLink: Bool = false

    struct PendingMetalConfig {
        let device: MTLDevice
        let pixelFormat: MTLPixelFormat
        let edr: Bool
        let colorSpace: CGColorSpace?
        let pipelines: DKMetalPipelineSet?
    }
    var _pendingMetalConfig: PendingMetalConfig?
    var _pendingClearFrame: Bool = false
    var _pendingSubtitleClear: Bool = false
    var _clearEpoch: UInt64 = 0
    var _redrawRequestGeneration: UInt64 = 0
    var _renderedRedrawGeneration: UInt64 = 0
    private var configuredDisplayID: CGDirectDisplayID?
    private var configuredPotentialEDR: Float = -1.0
    private var configuredDeviceRegistryID: UInt64 = 0
    private var configuredPixelFormat: MTLPixelFormat = .invalid
    private var hasConfiguredPipelines: Bool = false

    private var lastDrawableResizeUptime: TimeInterval = 0
    var liveResizeWorkItem: DispatchWorkItem?
    private let liveResizeThrottleInterval: TimeInterval = 0.35
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
    private var subtitleLiftDirty: Bool = false

    var currentDrawableSize: CGSize {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return cachedDrawableSize
    }

    public var subtitleHDRPeakNits: Float {
        get { sizeLock.lock(); defer { sizeLock.unlock() }; return _subtitleHDRPeakNits }
        set {
            sizeLock.lock()
            let changed = abs(_subtitleHDRPeakNits - newValue) > 0.5
            _subtitleHDRPeakNits = newValue
            if changed { _redrawRequestGeneration &+= 1 }
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
            if changed {
                _redrawRequestGeneration &+= 1
                subtitleLiftDirty = true
            }
            sizeLock.unlock()
        }
    }

    public var antiOcclusionEnabled: Bool {
        get { sizeLock.lock(); defer { sizeLock.unlock() }; return _antiOcclusionEnabled }
        set {
            sizeLock.lock()
            let changed = (_antiOcclusionEnabled != newValue)
            _antiOcclusionEnabled = newValue
            if changed {
                _redrawRequestGeneration &+= 1
                subtitleLiftDirty = true
            }
            sizeLock.unlock()
        }
    }

    public func updateSubtitleVerticalBounds(y0: Int32, y1: Int32, canvasH: Int32) {
        sizeLock.lock()
        if subtitleBoundsY0 != y0 || subtitleBoundsY1 != y1 || subtitleCanvasH != canvasH {
            subtitleBoundsY0 = y0
            subtitleBoundsY1 = y1
            subtitleCanvasH = canvasH
            subtitleLiftDirty = true
        }
        sizeLock.unlock()
    }

    public func stepSubtitleLiftAnimation(dt: Float) -> Bool {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        guard subtitleLiftDirty else { return false }
        let targetNDC: Float
        let viewH = Float(max(1.0, cachedViewPointSize.height))
        if !_antiOcclusionEnabled || _controlsOcclusionHeightPoints <= 0.5 {
            targetNDC = 0.0
        } else if subtitleCanvasH <= 0 || subtitleBoundsY1 <= subtitleBoundsY0 {
            // Keep existing lift offset across brief inter-cue silence so newly appearing subtitles
            // NEVER play a bottom-to-top slide-up entrance animation.
            subtitleLiftDirty = false
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
        subtitleLiftDirty = false
        // Traditional instant cinema placement: snap directly to target position with zero bottom-up slide animation.
        if abs(targetNDC - currentSubtitleLiftNDC) > 0.0001 {
            currentSubtitleLiftNDC = targetNDC
            _redrawRequestGeneration &+= 1
            return true
        }
        return false
    }

    public internal(set) var lastPixelBuffer: CVPixelBuffer?
    public static weak var activeInstance: DKMetalLayerView?
    public internal(set) var lastColorUniforms = DKGpuColorUniforms()
    public var needsRedrawOnSameFrame: Bool {
        get {
            sizeLock.lock()
            defer { sizeLock.unlock() }
            return _redrawRequestGeneration != _renderedRedrawGeneration
        }
        set {
            sizeLock.lock()
            if newValue {
                _redrawRequestGeneration &+= 1
            } else {
                _renderedRedrawGeneration = _redrawRequestGeneration
            }
            sizeLock.unlock()
        }
    }

    public func requestRedraw() {
        sizeLock.lock()
        _redrawRequestGeneration &+= 1
        sizeLock.unlock()
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
        liveResizeWorkItem?.cancel()
        liveResizeWorkItem = nil
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
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
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
            self.reconfigureMetalIfNeeded(for: self.window?.screen)
            let prevHeadroom = self.currentEDRHeadroom
            self.updateScreenHeadroom()
            let headroomChanged = abs(self.currentEDRHeadroom - prevHeadroom) > 0.001
            if headroomChanged {
                self.requestRedraw()
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
        let sizeChanged = updateDrawableSize(force: false)
        updateScreenHeadroom()
        if sizeChanged {
            requestRedraw()
            if !hasExternalDisplayLink {
                renderLastPixelBuffer()
            }
        }
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        liveResizeWorkItem?.cancel()
        liveResizeWorkItem = nil
        let sizeChanged = updateDrawableSize(force: true)
        if sizeChanged {
            requestRedraw()
            if !hasExternalDisplayLink {
                renderLastPixelBuffer()
            }
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Self.activeInstance = self
        }
        reconfigureMetalIfNeeded(for: window?.screen)
        _ = updateDrawableSize(force: true)
        updateScreenHeadroom()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            liveResizeWorkItem?.cancel()
            liveResizeWorkItem = nil
            if Self.activeInstance === self {
                Self.activeInstance = nil
            }
            onDetachFromWindow?()
            releasePlaybackResourcesOnExit()
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reconfigureMetalIfNeeded(for: window?.screen)
        _ = updateDrawableSize(force: true)
        updateScreenHeadroom()
        requestRedraw()
        if !hasExternalDisplayLink {
            renderLastPixelBuffer()
        }
    }

    public func currentFrameSnapshotInput() -> (pixelBuffer: CVPixelBuffer, colorUniforms: DKGpuColorUniforms, edrHeadroom: Float)? {
        snapshotLock.lock()
        let pb = snapshotPixelBuffer
        let uniforms = snapshotColorUniforms
        snapshotLock.unlock()
        guard let pb else { return nil }
        return (pb, uniforms, currentEDRHeadroom)
    }

    @discardableResult
    func updateDrawableSize(force: Bool = false) -> Bool {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return false }

        let targetSize = CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )

        sizeLock.lock()
        let pointSizeChanged = (size != cachedViewPointSize)
        if pointSizeChanged {
            cachedViewPointSize = size
            subtitleLiftDirty = true
        }
        let prevDrawableSize = cachedDrawableSize
        sizeLock.unlock()

        if targetSize == prevDrawableSize && metalLayer.drawableSize == targetSize {
            return false
        }

        // During AppKit live-resize drag, skip drawableSize reallocations entirely until viewDidEndLiveResize().
        // CAMetalLayer's contentsGravity = .resizeAspect scales the existing drawable smoothly on WindowServer GPU.
        if !force && inLiveResize && prevDrawableSize != .zero {
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        let shouldCoalesce = !force
            && prevDrawableSize != .zero
            && (now - lastDrawableResizeUptime) < liveResizeThrottleInterval

        if shouldCoalesce {
            lastDrawableResizeUptime = now
            liveResizeWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.liveResizeWorkItem = nil
                if !self.inLiveResize, self.updateDrawableSize(force: true) {
                    self.requestRedraw()
                    if !self.hasExternalDisplayLink {
                        self.renderLastPixelBuffer()
                    }
                }
            }
            liveResizeWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + liveResizeThrottleInterval, execute: item)
            return false
        }

        liveResizeWorkItem?.cancel()
        liveResizeWorkItem = nil
        lastDrawableResizeUptime = now

        if metalLayer.drawableSize != targetSize {
            metalLayer.drawableSize = targetSize
        }

        sizeLock.lock()
        let changed = (targetSize != cachedDrawableSize || pointSizeChanged)
        if changed {
            cachedDrawableSize = targetSize
            cachedViewPointSize = size
            layoutGeneration &+= 1
            _redrawRequestGeneration &+= 1
            subtitleLiftDirty = true
        }
        sizeLock.unlock()
        return changed
    }

    nonisolated public static func preferredMetalDevice(for screen: NSScreen?) -> MTLDevice? {
        let targetScreen = screen ?? NSScreen.main
        if let num = targetScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayID = CGDirectDisplayID(num.uint32Value)
            if let displayDev = CGDirectDisplayCopyCurrentMetalDevice(displayID) {
                return displayDev
            }
        }
        return MTLCreateSystemDefaultDevice() ?? MTLCopyAllDevices().first
    }

    nonisolated static func preferredLayerFormat(
        device: MTLDevice,
        screen: NSScreen?
    ) -> (pixelFormat: MTLPixelFormat, edr: Bool, colorSpace: CGColorSpace?) {
        let sdrColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB)
        let edrColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        let potentialEDR = Float(
            screen?.maximumPotentialExtendedDynamicRangeColorComponentValue
                ?? screen?.maximumExtendedDynamicRangeColorComponentValue
                ?? 1.0
        )

        #if arch(x86_64)
        if device.isLowPower && potentialEDR <= 1.01 {
            return (.bgra8Unorm_srgb, false, sdrColorSpace)
        }
        #endif

        if DKMetalPipelineSet.cached(device: device, shaderSource: Self.metalShaderSource, pixelFormat: .rgba16Float) != nil {
            return (.rgba16Float, true, edrColorSpace)
        }
        return (.bgra8Unorm_srgb, false, sdrColorSpace)
    }

    private func setupMetal() {
        assert(MemoryLayout<DKGpuColorUniforms>.stride == 3088, "Swift DKGpuColorUniforms stride mismatch")
        reconfigureMetalIfNeeded(for: window?.screen ?? NSScreen.main)
    }

    private func reconfigureMetalIfNeeded(for screen: NSScreen?) {
        let targetScreen = screen ?? NSScreen.main
        let displayID: CGDirectDisplayID = {
            if let num = targetScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                return CGDirectDisplayID(num.uint32Value)
            }
            return 0
        }()
        let potentialEDR = Float(
            targetScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue
                ?? targetScreen?.maximumExtendedDynamicRangeColorComponentValue
                ?? 1.0
        )

        sizeLock.lock()
        let fastHit = (configuredDisplayID == displayID
            && abs(configuredPotentialEDR - potentialEDR) <= 0.005
            && hasConfiguredPipelines
            && _pendingMetalConfig == nil)
        sizeLock.unlock()
        if fastHit {
            return
        }

        guard let dev = Self.preferredMetalDevice(for: targetScreen) else { return }
        let targetFormat = Self.preferredLayerFormat(device: dev, screen: targetScreen)

        sizeLock.lock()
        let unchanged = (configuredDeviceRegistryID == dev.registryID
            && configuredPixelFormat == targetFormat.pixelFormat
            && hasConfiguredPipelines
            && _pendingMetalConfig == nil)
        if unchanged {
            configuredDisplayID = displayID
            configuredPotentialEDR = potentialEDR
            sizeLock.unlock()
            return
        }
        sizeLock.unlock()

        let pipelines = DKMetalPipelineSet.cached(
            device: dev,
            shaderSource: Self.metalShaderSource,
            pixelFormat: targetFormat.pixelFormat
        )
        let config = PendingMetalConfig(
            device: dev,
            pixelFormat: targetFormat.pixelFormat,
            edr: targetFormat.edr,
            colorSpace: targetFormat.colorSpace,
            pipelines: pipelines
        )

        sizeLock.lock()
        _pendingMetalConfig = config
        configuredDisplayID = displayID
        configuredPotentialEDR = potentialEDR
        configuredDeviceRegistryID = dev.registryID
        configuredPixelFormat = targetFormat.pixelFormat
        hasConfiguredPipelines = (pipelines?.videoPipeline != nil)
        _redrawRequestGeneration &+= 1
        sizeLock.unlock()

        if renderLock.try() {
            applyPendingMetalConfigLocked()
            renderLock.unlock()
        }
    }

    func applyPendingMetalConfigLocked() {
        sizeLock.lock()
        let config = _pendingMetalConfig
        _pendingMetalConfig = nil
        sizeLock.unlock()
        guard let config else { return }

        let deviceChanged = (self.device?.registryID != config.device.registryID)
        self.device = config.device

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.metalLayer.device = config.device
        self.metalLayer.pixelFormat = config.pixelFormat
        self.metalLayer.wantsExtendedDynamicRangeContent = config.edr
        self.metalLayer.colorspace = config.colorSpace
        self.metalLayer.contentsGravity = .resizeAspect
        self.metalLayer.framebufferOnly = true
        CATransaction.commit()

        if deviceChanged || self.commandQueue == nil {
            self.commandQueue = config.device.makeCommandQueue()
            var newCache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, config.device, nil, &newCache)
            self.textureCache = newCache
            self.subtitleTextures = [nil, nil, nil]
            self.subtitleTexture = nil
            self.subtitleTextureWriteIdx = 0
            self.hasActiveSubtitle = false
        }

        if let pipelines = config.pipelines {
            self.pipelineVideoMaster = pipelines.videoPipeline
            self.pipelineBGRA = pipelines.bgraPipeline
            self.pipelineSubtitle = pipelines.subPipeline
        } else {
            print("[DonbyMetal] Pipeline create failed for format \(config.pixelFormat.rawValue)")
        }
    }
}
