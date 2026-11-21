import SwiftUI
import AppKit
import MetalKit
import CoreVideo
import CoreGraphics
import DonbyKernelC

// MARK: - Display Link Driver (CVDisplayLink with High-Frequency Common-Mode Timer Fallback)

private final class DisplayLinkDriver {
    private final class CallbackToken {
        private let lock = NSLock()
        private var handler: (() -> Void)?

        init(handler: @escaping () -> Void) {
            self.handler = handler
        }

        func invoke() {
            lock.lock()
            let fn = handler
            lock.unlock()
            fn?()
        }

        func invalidate() {
            lock.lock()
            handler = nil
            lock.unlock()
        }
    }

    private static let lifecycleQueue = DispatchQueue(label: "com.donby.displaylink.lifecycle", qos: .userInitiated)

    private var displayLink: CVDisplayLink?
    private var activeToken: CallbackToken?
    private var fallbackTimer: Timer?
    private var handler: (() -> Void)?
    private let lock = NSLock()
    private var isRunning = false

    func start(handler: @escaping () -> Void) {
        let oldLink: CVDisplayLink?
        let oldToken: CallbackToken?
        let oldTimer: Timer?
        lock.lock()
        oldLink = displayLink
        displayLink = nil
        oldToken = activeToken
        activeToken = nil
        oldTimer = fallbackTimer
        fallbackTimer = nil
        self.handler = handler
        self.isRunning = true
        lock.unlock()

        oldToken?.invalidate()
        stopDisplayLinkAsync(oldLink, token: oldToken)
        invalidateTimer(oldTimer)

        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if status == kCVReturnSuccess, let link = link {
            let token = CallbackToken(handler: handler)
            let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
                guard let userInfo = userInfo else { return kCVReturnSuccess }
                let tok = Unmanaged<CallbackToken>.fromOpaque(userInfo).takeUnretainedValue()
                tok.invoke()
                return kCVReturnSuccess
            }
            CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(token).toOpaque())
            lock.lock()
            let stillRunning = isRunning
            if stillRunning {
                self.displayLink = link
                self.activeToken = token
            }
            lock.unlock()
            if stillRunning {
                CVDisplayLinkStart(link)
            } else {
                token.invalidate()
                stopDisplayLinkAsync(link, token: token)
            }
        } else {
            // Fallback for headless environments or when CVDisplayLink fails:
            // High-frequency 60Hz timer registered in .common mode so it never freezes
            // during window dragging or menu interactions.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                let stillRunning = self.isRunning
                self.lock.unlock()
                guard stillRunning else { return }
                let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    self?.tick()
                }
                RunLoop.main.add(timer, forMode: .common)
                self.lock.lock()
                if self.isRunning {
                    self.fallbackTimer = timer
                } else {
                    timer.invalidate()
                }
                self.lock.unlock()
            }
        }
    }

    private func tick() {
        lock.lock()
        let activeHandler = isRunning ? handler : nil
        lock.unlock()
        activeHandler?()
    }

    func stop() {
        let oldLink: CVDisplayLink?
        let oldToken: CallbackToken?
        let oldTimer: Timer?
        lock.lock()
        isRunning = false
        handler = nil
        oldLink = displayLink
        displayLink = nil
        oldToken = activeToken
        activeToken = nil
        oldTimer = fallbackTimer
        fallbackTimer = nil
        lock.unlock()

        oldToken?.invalidate()
        stopDisplayLinkAsync(oldLink, token: oldToken)
        invalidateTimer(oldTimer)
    }

    private func stopDisplayLinkAsync(_ link: CVDisplayLink?, token: CallbackToken?) {
        guard let link else { return }
        // Never call CVDisplayLinkStop synchronously on the main thread: while tick() is inside
        // Metal nextDrawable() or C++ subtitle locks, blocking main causes a CA/WindowServer deadlock.
        Self.lifecycleQueue.async {
            CVDisplayLinkStop(link)
            withExtendedLifetime((link, token)) {}
        }
    }

    private func invalidateTimer(_ timer: Timer?) {
        guard let timer else { return }
        if Thread.isMainThread {
            timer.invalidate()
        } else {
            DispatchQueue.main.async {
                timer.invalidate()
            }
        }
    }

    deinit {
        stop()
    }
}

// MARK: - Metal Layer View

private struct DKVertexUniforms {
    var scale: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
    var uvRect: SIMD4<Float>
}

private final class DKMetalPipelineSet: @unchecked Sendable {
    let videoPipeline: MTLRenderPipelineState?
    let bgraPipeline: MTLRenderPipelineState?
    let subPipeline: MTLRenderPipelineState?

    private static let cacheLock = NSLock()
    private static var libraryCache: [UInt64: MTLLibrary] = [:]
    private static var pipelineCache: [String: DKMetalPipelineSet] = [:]

    static func cached(device: MTLDevice, shaderSource: String, pixelFormat: MTLPixelFormat) -> DKMetalPipelineSet? {
        let key = "\(device.registryID)|\(pixelFormat.rawValue)"
        cacheLock.lock()
        if let hit = pipelineCache[key] {
            cacheLock.unlock()
            return hit
        }
        let cachedLib = libraryCache[device.registryID]
        cacheLock.unlock()

        let library: MTLLibrary
        if let cachedLib {
            library = cachedLib
        } else {
            guard let compiled = try? device.makeLibrary(source: shaderSource, options: nil) else {
                return nil
            }
            cacheLock.lock()
            library = libraryCache[device.registryID] ?? {
                libraryCache[device.registryID] = compiled
                return compiled
            }()
            cacheLock.unlock()
        }

        guard let created = DKMetalPipelineSet(library: library, device: device, pixelFormat: pixelFormat) else {
            return nil
        }
        cacheLock.lock()
        let result = pipelineCache[key] ?? {
            pipelineCache[key] = created
            return created
        }()
        cacheLock.unlock()
        return result
    }

    private convenience init?(device: MTLDevice, shaderSource: String, pixelFormat: MTLPixelFormat) {
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil) else {
            return nil
        }
        self.init(library: library, device: device, pixelFormat: pixelFormat)
    }

    private init?(library: MTLLibrary, device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let vert = library.makeFunction(name: "vertex_main") else {
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vert
        desc.colorAttachments[0].pixelFormat = pixelFormat

        if let fragMaster = library.makeFunction(name: "fragment_video_master") {
            desc.fragmentFunction = fragMaster
            self.videoPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        } else {
            self.videoPipeline = nil
        }

        if let fragBgra = library.makeFunction(name: "fragment_bgra") {
            desc.fragmentFunction = fragBgra
            self.bgraPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        } else {
            self.bgraPipeline = nil
        }

        if let fragSub = library.makeFunction(name: "fragment_subtitle") {
            let subDesc = MTLRenderPipelineDescriptor()
            subDesc.vertexFunction = vert
            subDesc.fragmentFunction = fragSub
            subDesc.colorAttachments[0].pixelFormat = pixelFormat
            subDesc.colorAttachments[0].isBlendingEnabled = true
            subDesc.colorAttachments[0].sourceRGBBlendFactor = .one
            subDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            subDesc.colorAttachments[0].rgbBlendOperation = .add
            subDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            subDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            subDesc.colorAttachments[0].alphaBlendOperation = .add
            self.subPipeline = try? device.makeRenderPipelineState(descriptor: subDesc)
        } else {
            self.subPipeline = nil
        }
    }
}

public final class DKMetalLayerView: NSView {
    public var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var textureCache: CVMetalTextureCache?
    private var commandQueue: MTLCommandQueue?
    private var device: MTLDevice?

    // Unified HDR/DoVi/SDR YCbCr pipeline, BGRA fallback pipeline, and linear-blended subtitle overlay pipeline
    private var pipelineVideoMaster: MTLRenderPipelineState?
    private var pipelineBGRA: MTLRenderPipelineState?
    private var pipelineSubtitle: MTLRenderPipelineState?

    private let renderLock = NSLock()
    private let sizeLock = NSLock()
    private let snapshotLock = NSLock()
    private var snapshotPixelBuffer: CVPixelBuffer?
    private var snapshotColorUniforms = DKGpuColorUniforms()
    private var cachedDrawableSize: CGSize = .zero
    private var cachedEDRHeadroom: Float = 1.0
    private var layoutGeneration: UInt64 = 0
    private var screenObserver: NSObjectProtocol?

    // Subtitle GPU texture cache (updated only when subtitle serial changes)
    private var subtitleTextures: [MTLTexture?] = [nil, nil, nil]
    private var subtitleTextureWriteIdx: Int = 0
    private var subtitleTexture: MTLTexture?
    private var subtitleTexWidth: Int = 0
    private var subtitleTexHeight: Int = 0
    private var hasActiveSubtitle: Bool = false
    private var subtitleBoundsY0: Int32 = 0
    private var subtitleBoundsY1: Int32 = 0
    private var subtitleCanvasH: Int32 = 0
    private var currentSubtitleLiftNDC: Float = 0.0
    private var _subtitleHDRPeakNits: Float = 203.0
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
            sizeLock.unlock()
            if changed { renderLastPixelBuffer() }
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

    public private(set) var lastPixelBuffer: CVPixelBuffer?
    public static weak var activeInstance: DKMetalLayerView?
    public private(set) var lastColorUniforms = DKGpuColorUniforms()
    private var _needsRedrawOnSameFrame: Bool = false
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
            self.updateScreenHeadroom()
            self.needsRedrawOnSameFrame = true
            self.renderLastPixelBuffer()
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
        renderLastPixelBuffer()
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

    nonisolated public static let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexUniforms {
        float2 scale;
        float2 pad;
        float4 uvRect; // (uMin, vMin, uMax, vMax)
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
        float2 subParams;
    };

    struct DKGpuColorUniformsMSL {
        int transfer_fn;
        int primaries;
        int is_full_range;
        int bit_depth;

        int use_dovi_chain;
        int has_dovi_reshape;
        float source_peak_nits;
        float edr_headroom;

        float4 ycc_offset;
        float4 yuv_matrix_r0;
        float4 yuv_matrix_r1;
        float4 yuv_matrix_r2;

        float4 lin_matrix_r0;
        float4 lin_matrix_r1;
        float4 lin_matrix_r2;

        int4 reshape_pieces;
        float reshape_pivots[36];
        float reshape_coeffs[96];
        int reshape_mmr_meta[24];
        float reshape_mmr_coeffs[576];
    };

    static_assert(sizeof(DKGpuColorUniformsMSL) == 3088, "DKGpuColorUniformsMSL layout mismatch");

    vertex VertexOut vertex_main(uint vertexID [[vertex_id]],
                                 constant VertexUniforms &vu [[buffer(0)]]) {
        float2 positions[4] = {
            float2(-1.0f, -1.0f),
            float2( 1.0f, -1.0f),
            float2(-1.0f,  1.0f),
            float2( 1.0f,  1.0f)
        };
        float2 texCoords[4] = {
            float2(vu.uvRect.x, vu.uvRect.w),
            float2(vu.uvRect.z, vu.uvRect.w),
            float2(vu.uvRect.x, vu.uvRect.y),
            float2(vu.uvRect.z, vu.uvRect.y)
        };
        VertexOut out;
        out.position = float4(positions[vertexID] * vu.scale + float2(0.0f, vu.pad.y), 0.0f, 1.0f);
        out.texCoord = texCoords[vertexID];
        out.subParams = vu.pad;
        return out;
    }

    inline float3 srgb_to_linear(float3 c) {
        c = max(c, 0.0f);
        float3 lo = c / 12.92f;
        float3 hi = pow((c + 0.055f) / 1.055f, 2.4f);
        return select(hi, lo, c <= 0.04045f);
    }

    inline float3 pq_eotf_nits(float3 e) {
        const float m1 = 2610.0f / 16384.0f;
        const float m2 = (2523.0f / 4096.0f) * 128.0f;
        const float c1 = 3424.0f / 4096.0f;
        const float c2 = (2413.0f / 4096.0f) * 32.0f;
        const float c3 = (2392.0f / 4096.0f) * 32.0f;
        float3 ep = pow(clamp(e, 0.0f, 1.0f), 1.0f / m2);
        float3 num = max(ep - c1, 0.0f);
        float3 den = max(c2 - c3 * ep, 1e-6f);
        return 10000.0f * pow(num / den, 1.0f / m1);
    }

    inline float nits_to_pq_scalar(float nits) {
        float y = clamp(nits / 10000.0f, 0.0f, 1.0f);
        const float m1 = 2610.0f / 16384.0f;
        const float m2 = (2523.0f / 4096.0f) * 128.0f;
        const float c1 = 3424.0f / 4096.0f;
        const float c2 = (2413.0f / 4096.0f) * 32.0f;
        const float c3 = (2392.0f / 4096.0f) * 32.0f;
        float ym = pow(y, m1);
        return pow((c1 + c2 * ym) / (1.0f + c3 * ym), m2);
    }

    inline float pq_to_nits_scalar(float e) {
        const float m1 = 2610.0f / 16384.0f;
        const float m2 = (2523.0f / 4096.0f) * 128.0f;
        const float c1 = 3424.0f / 4096.0f;
        const float c2 = (2413.0f / 4096.0f) * 32.0f;
        const float c3 = (2392.0f / 4096.0f) * 32.0f;
        float ep = pow(clamp(e, 0.0f, 1.0f), 1.0f / m2);
        float num = max(ep - c1, 0.0f);
        float den = max(c2 - c3 * ep, 1e-6f);
        return 10000.0f * pow(num / den, 1.0f / m1);
    }

    // ITU-R BT.2390-10 Hermite spline perceptual tone mapping in PQ domain
    inline float bt2390_eetf_nits(float inNits, float srcPeakNits, float dstPeakNits) {
        if (dstPeakNits >= srcPeakNits - 1.0f) {
            return min(inNits, dstPeakNits);
        }
        float wSrc = max(nits_to_pq_scalar(srcPeakNits), 1e-4f);
        float e1 = clamp(nits_to_pq_scalar(inNits) / wSrc, 0.0f, 1.0f);
        float maxLum = clamp(nits_to_pq_scalar(dstPeakNits) / wSrc, 0.05f, 1.0f);
        float ks = max(1.5f * maxLum - 0.5f, 0.10f);
        float e2 = e1;
        if (e1 > ks) {
            float t = clamp((e1 - ks) / max(1.0f - ks, 1e-5f), 0.0f, 1.0f);
            float t2 = t * t;
            float t3 = t2 * t;
            float p0 = 2.0f * t3 - 3.0f * t2 + 1.0f;
            float p1 = t3 - 2.0f * t2 + t;
            float p2 = -2.0f * t3 + 3.0f * t2;
            e2 = p0 * ks + p1 * (1.0f - ks) + p2 * maxLum;
        }
        return pq_to_nits_scalar(clamp(e2 * wSrc, 0.0f, 1.0f));
    }

    inline float3 hlg_inverse_oetf(float3 e) {
        const float a = 0.17883277f;
        const float b = 1.0f - 4.0f * a;
        const float c = 0.5f - a * log(4.0f * a);
        e = clamp(e, 0.0f, 1.0f);
        float3 lo = (e * e) / 3.0f;
        float3 hi = (exp((e - c) / a) + b) / 12.0f;
        return select(hi, lo, e <= 0.5f);
    }

    inline float3 eval_dovi_reshape(float3 raw, constant DKGpuColorUniformsMSL &u) {
        float3 outv = raw;
        float x = raw.x, y = raw.y, z = raw.z;
        float xy = x * y, xz = x * z, yz = y * z, xyz = xy * z;
        for (int ch = 0; ch < 3; ch++) {
            int np = u.reshape_pieces[ch];
            if (np <= 0) continue;
            float v = raw[ch];
            int piv_base = ch * 12;
            int pc = 0;
            for (int i = 0; i < np - 1 && i < 7; i++) {
                if (v >= u.reshape_pivots[piv_base + i + 1]) {
                    pc = i + 1;
                } else {
                    break;
                }
            }
            int piece_idx = ch * 8 + pc;
            int mmr_order = u.reshape_mmr_meta[piece_idx];
            if (mmr_order <= 0) {
                int cbase = piece_idx * 4;
                float c0 = u.reshape_coeffs[cbase + 0];
                float c1 = u.reshape_coeffs[cbase + 1];
                float c2 = u.reshape_coeffs[cbase + 2];
                outv[ch] = clamp(c0 + v * (c1 + v * c2), 0.0f, 1.0f);
            } else {
                int mbase = piece_idx * 24;
                float acc = u.reshape_mmr_coeffs[mbase + 0];
                float t1[7] = { x, y, z, xy, xz, yz, xyz };
                for (int k = 0; k < 7; k++) {
                    acc += u.reshape_mmr_coeffs[mbase + 1 + k] * t1[k];
                }
                if (mmr_order >= 2) {
                    for (int k = 0; k < 7; k++) {
                        float t2 = t1[k] * t1[k];
                        acc += u.reshape_mmr_coeffs[mbase + 8 + k] * t2;
                    }
                }
                if (mmr_order >= 3) {
                    for (int k = 0; k < 7; k++) {
                        float t3 = t1[k] * t1[k] * t1[k];
                        acc += u.reshape_mmr_coeffs[mbase + 15 + k] * t3;
                    }
                }
                outv[ch] = clamp(acc, 0.0f, 1.0f);
            }
        }
        return outv;
    }

    inline float3 gamut_map_to_linear_p3(float3 rgb, int primaries) {
        float3 p3;
        if (primaries == 1) {
            // ITU-R BT.2020 -> Display P3 (D65)
            p3 = float3(
                dot(float3( 1.3435783f, -0.2821797f, -0.0613986f), rgb),
                dot(float3(-0.0652975f,  1.0757879f, -0.0104905f), rgb),
                dot(float3( 0.0028218f, -0.0195985f,  1.0167767f), rgb)
            );
        } else if (primaries == 0) {
            // ITU-R BT.709 -> Display P3 (D65)
            p3 = float3(
                dot(float3(0.8224620f, 0.1775380f, 0.0f), rgb),
                dot(float3(0.0331942f, 0.9668058f, 0.0f), rgb),
                dot(float3(0.0170826f, 0.0723974f, 0.9105199f), rgb)
            );
        } else {
            p3 = rgb;
        }

        // Analytical luminance-preserving gamut compression for ultra-wide BT.2020 colors outside P3
        float minC = min(p3.r, min(p3.g, p3.b));
        if (minC < 0.0f) {
            float lum = dot(p3, float3(0.2289746f, 0.6917385f, 0.0792869f));
            if (lum > 1e-5f) {
                float t = clamp(lum / (lum - minC), 0.0f, 1.0f);
                p3 = mix(float3(lum), p3, t);
            }
            p3 = max(p3, 0.0f);
        }
        return p3;
    }

    fragment float4 fragment_video_master(VertexOut in [[stage_in]],
                                          texture2d<float, access::sample> texY [[texture(0)]],
                                          texture2d<float, access::sample> texUV [[texture(1)]],
                                          constant DKGpuColorUniformsMSL &u [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float ySample = texY.sample(s, in.texCoord).r;
        float2 uvSample = texUV.sample(s, in.texCoord).rg;
        float3 raw = float3(ySample, uvSample.x, uvSample.y);

        // 'x420' / 'xf20' / 'p010' store 10-bit codes in MSB (code10 * 64);
        // multiplying unorm16 (/65535) by 65535/65536 yields exact code10 / 1024.0
        if (u.bit_depth >= 10) {
            raw *= (65535.0f / 65536.0f);
        }

        if (u.has_dovi_reshape != 0) {
            raw = eval_dovi_reshape(raw, u);
        }

        float3 ycc = raw - u.ycc_offset.xyz;
        float3 nl = float3(
            dot(u.yuv_matrix_r0.xyz, ycc),
            dot(u.yuv_matrix_r1.xyz, ycc),
            dot(u.yuv_matrix_r2.xyz, ycc)
        );

        const float kRefWhiteNits = 203.0f;
        float headroom = max(u.edr_headroom, 1.0f);
        float dstPeakNits = kRefWhiteNits * headroom;
        float3 linearRGB;

        if (u.transfer_fn == 1) {
            // SMPTE ST 2084 PQ (HDR10 & Dolby Vision)
            float3 nits = pq_eotf_nits(nl);
            float3 lin = float3(
                dot(u.lin_matrix_r0.xyz, nits),
                dot(u.lin_matrix_r1.xyz, nits),
                dot(u.lin_matrix_r2.xyz, nits)
            );
            lin = max(lin, 0.0f);

            float srcPeak = max(u.source_peak_nits, 203.0f);
            if (srcPeak > dstPeakNits + 1.0f) {
                float maxC = max(lin.r, max(lin.g, lin.b));
                float lumC = dot(lin, float3(0.2627002f, 0.6779981f, 0.0593017f));
                float sigNits = mix(maxC, lumC, 0.25f);
                if (sigNits > 1e-4f) {
                    float mappedNits = bt2390_eetf_nits(sigNits, srcPeak, dstPeakNits);
                    lin *= (mappedNits / sigNits);
                }
                float postMax = max(lin.r, max(lin.g, lin.b));
                if (postMax > dstPeakNits) {
                    lin *= (dstPeakNits / postMax);
                }
            }

            linearRGB = lin / kRefWhiteNits;
            if (headroom < 2.5f) {
                float adapt = mix(1.06f, 1.0f, clamp((headroom - 1.0f) / 1.5f, 0.0f, 1.0f));
                float lumLin = max(dot(linearRGB, float3(0.2627002f, 0.6779981f, 0.0593017f)), 1e-6f);
                linearRGB *= pow(min(lumLin, 1.0f), adapt - 1.0f);
            }
        } else if (u.transfer_fn == 2) {
            // ARIB STD-B67 HLG
            float3 scene = hlg_inverse_oetf(nl);
            float ys = max(dot(scene, float3(0.2627002f, 0.6779981f, 0.0593017f)), 1e-6f);
            float3 lin = scene * pow(ys, 0.2f) * 1000.0f;
            float srcPeak = max(u.source_peak_nits, 1000.0f);
            if (srcPeak > dstPeakNits + 1.0f) {
                float maxC = max(lin.r, max(lin.g, lin.b));
                float lumC = dot(lin, float3(0.2627002f, 0.6779981f, 0.0593017f));
                float sigNits = mix(maxC, lumC, 0.25f);
                if (sigNits > 1e-4f) {
                    float mappedNits = bt2390_eetf_nits(sigNits, srcPeak, dstPeakNits);
                    lin *= (mappedNits / sigNits);
                }
                float postMax = max(lin.r, max(lin.g, lin.b));
                if (postMax > dstPeakNits) {
                    lin *= (dstPeakNits / postMax);
                }
            }
            linearRGB = lin / kRefWhiteNits;
        } else {
            // SDR (sRGB / ITU-R BT.709)
            linearRGB = srgb_to_linear(clamp(nl, 0.0f, 1.0f));
        }

        float3 outP3 = gamut_map_to_linear_p3(linearRGB, u.primaries);
        return float4(outP3, 1.0f);
    }

    // 32-bit BGRA fallback converted to Linear Display P3
    fragment float4 fragment_bgra(VertexOut in [[stage_in]],
                                  texture2d<float, access::sample> tex [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 c = tex.sample(s, in.texCoord);
        float3 lin = srgb_to_linear(c.rgb);
        float3 outP3 = gamut_map_to_linear_p3(lin, 0);
        return float4(outP3, c.a);
    }

    // Premultiplied RGBA8 subtitle overlay blended in linear Display P3 light with steady SDR/HDR paper-white calibration
    fragment float4 fragment_subtitle(VertexOut in [[stage_in]],
                                      texture2d<float, access::sample> texSub [[texture(0)]],
                                      constant DKGpuColorUniformsMSL &u [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 sub = texSub.sample(s, in.texCoord);
        if (sub.a <= 1e-4f) {
            return float4(0.0f);
        }
        float3 srgb = clamp(sub.rgb / max(sub.a, 1.0f / 255.0f), 0.0f, 1.0f);
        float targetNits = (in.subParams.x >= 100.0f) ? in.subParams.x : 203.0f;
        float headroom = max(u.edr_headroom, 1.0f);
        float paperWhite;
        if (u.transfer_fn != 0 && headroom > 1.01f) {
            // Calibrated HDR subtitle luminance: maps user peak nit selection cleanly without clipping or glare
            float requestedGain = clamp(targetNits / 203.0f, 0.72f, 2.20f);
            paperWhite = min(requestedGain, headroom * 0.92f);
        } else {
            // SDR / EDR-disabled display: crisp reference white without dulling PGS/ASS glyphs
            paperWhite = 0.94f;
        }
        float3 lin = srgb_to_linear(srgb) * paperWhite;
        float3 p3 = gamut_map_to_linear_p3(lin, 0);
        return float4(p3 * sub.a, sub.a);
    }
    """

    nonisolated public static func prewarmPipelines() {
        guard let dev = MTLCreateSystemDefaultDevice() else { return }
        _ = DKMetalPipelineSet.cached(device: dev, shaderSource: Self.metalShaderSource, pixelFormat: .rgba16Float)
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

    public func updateSubtitleOverlay(rgbaPtr: UnsafePointer<UInt8>?, width: Int, height: Int) {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard let ptr = rgbaPtr, width > 0, height > 0, let dev = device else {
            hasActiveSubtitle = false
            return
        }

        if subtitleTexWidth != width || subtitleTexHeight != height {
            subtitleTextures = [nil, nil, nil]
            subtitleTexture = nil
            subtitleTextureWriteIdx = 0
            subtitleTexWidth = width
            subtitleTexHeight = height
        }

        // Rotate across a 3-slot MTLTexture ring so CPU replace(region:) NEVER overwrites a texture still read by an in-flight GPU frame!
        let slot = subtitleTextureWriteIdx
        subtitleTextureWriteIdx = (slot + 1) % 3
        if subtitleTextures[slot] == nil {
            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            texDesc.usage = [.shaderRead]
            subtitleTextures[slot] = dev.makeTexture(descriptor: texDesc)
        }

        if let tex = subtitleTextures[slot] {
            let region = MTLRegionMake2D(0, 0, width, height)
            tex.replace(region: region, mipmapLevel: 0, withBytes: ptr, bytesPerRow: width * 4)
            subtitleTexture = tex
            hasActiveSubtitle = true
        }
    }

    public func clearDisplayedFrame() {
        renderLock.lock()
        lastPixelBuffer = nil
        renderLock.unlock()
        snapshotLock.lock()
        snapshotPixelBuffer = nil
        snapshotLock.unlock()
    }

    public func renderLastPixelBuffer() {
        guard renderLock.try() else { return }
        defer { renderLock.unlock() }
        guard let pixbuf = lastPixelBuffer else { return }
        _ = renderLocked(pixbuf, colorUniforms: lastColorUniforms)
    }

    private func calculateScale(videoWidth: Double, videoHeight: Double) -> SIMD2<Float> {
        sizeLock.lock()
        var viewWidth = Double(cachedDrawableSize.width)
        var viewHeight = Double(cachedDrawableSize.height)
        sizeLock.unlock()

        if viewWidth <= 0 || viewHeight <= 0 {
            viewWidth = Double(bounds.width)
            viewHeight = Double(bounds.height)
        }

        guard viewWidth > 0, viewHeight > 0, videoWidth > 0, videoHeight > 0 else {
            return SIMD2<Float>(1.0, 1.0)
        }

        let viewAspect = Float(viewWidth / viewHeight)
        let videoAspect = Float(videoWidth / videoHeight)

        if videoAspect > viewAspect {
            // Video is wider than the viewport -> Letterbox (black bars top & bottom)
            return SIMD2<Float>(1.0, max(0.01, viewAspect / videoAspect))
        } else {
            // Video is taller than the viewport -> Pillarbox (black bars left & right)
            return SIMD2<Float>(max(0.01, videoAspect / viewAspect), 1.0)
        }
    }

    @discardableResult
    public func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, colorUniforms: DKGpuColorUniforms? = nil) -> Bool {
        guard renderLock.try() else { return false }
        defer { renderLock.unlock() }
        return renderLocked(pixelBuffer, colorUniforms: colorUniforms)
    }

    nonisolated private static func isTenBitBiPlanar(_ pf: OSType) -> Bool {
        pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
        pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
        pf == 0x78343230 || // 'x420'
        pf == 0x78663230 || // 'xf20'
        pf == 0x70303130 || // 'p010'
        pf == 0x73343230    // 's420'
    }

    private func renderLocked(_ pixelBuffer: CVPixelBuffer, colorUniforms: DKGpuColorUniforms?) -> Bool {
        sizeLock.lock()
        let drawableSize = cachedDrawableSize
        let gen = layoutGeneration
        sizeLock.unlock()
        guard drawableSize.width > 0, drawableSize.height > 0 else { return false }

        var uniforms = colorUniforms ?? self.lastColorUniforms
        uniforms.edr_headroom = currentEDRHeadroom

        guard let queue = commandQueue,
              let cache = textureCache,
              let drawable = metalLayer.nextDrawable() else {
            return false
        }

        let cleanWidth = CVPixelBufferGetWidth(pixelBuffer)
        let cleanHeight = CVPixelBufferGetHeight(pixelBuffer)
        let sar = Double(uniforms.ycc_offset.3 > 0.05 ? uniforms.ycc_offset.3 : 1.0)
        let videoWidth = Double(cleanWidth) * sar
        let videoHeight = Double(cleanHeight)
        var scale = calculateScale(videoWidth: videoWidth, videoHeight: videoHeight)

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let rendered: Bool

        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let pipeline = pipelineVideoMaster else { return false }
            uniforms.bit_depth = 8
            rendered = renderBiPlanar(pixelBuffer: pixelBuffer,
                                      pipeline: pipeline,
                                      scale: &scale,
                                      uniforms: &uniforms,
                                      drawable: drawable,
                                      queue: queue,
                                      cache: cache,
                                      is10Bit: false)

        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             0x78343230, // 'x420'
             0x78663230, // 'xf20'
             0x70303130, // 'p010'
             0x73343230: // 's420'
            guard let pipeline = pipelineVideoMaster else { return false }
            if uniforms.bit_depth < 10 { uniforms.bit_depth = 10 }
            rendered = renderBiPlanar(pixelBuffer: pixelBuffer,
                                      pipeline: pipeline,
                                      scale: &scale,
                                      uniforms: &uniforms,
                                      drawable: drawable,
                                      queue: queue,
                                      cache: cache,
                                      is10Bit: true)

        case kCVPixelFormatType_32BGRA,
             0x42475241: // 'BGRA'
            guard let pipeline = pipelineBGRA else { return false }
            rendered = renderBGRA(pixelBuffer: pixelBuffer,
                                  pipeline: pipeline,
                                  scale: &scale,
                                  drawable: drawable,
                                  queue: queue,
                                  cache: cache)

        default:
            let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
            if planeCount == 2 {
                guard let pipeline = pipelineVideoMaster else { return false }
                rendered = renderBiPlanar(pixelBuffer: pixelBuffer,
                                          pipeline: pipeline,
                                          scale: &scale,
                                          uniforms: &uniforms,
                                          drawable: drawable,
                                          queue: queue,
                                          cache: cache,
                                          is10Bit: false)
            } else {
                guard let pipeline = pipelineBGRA else { return false }
                rendered = renderBGRA(pixelBuffer: pixelBuffer,
                                      pipeline: pipeline,
                                      scale: &scale,
                                      drawable: drawable,
                                      queue: queue,
                                      cache: cache)
            }
        }

        if rendered {
            self.lastPixelBuffer = pixelBuffer
            self.lastColorUniforms = uniforms
            snapshotLock.lock()
            self.snapshotPixelBuffer = pixelBuffer
            self.snapshotColorUniforms = uniforms
            snapshotLock.unlock()
            sizeLock.lock()
            if layoutGeneration == gen {
                _needsRedrawOnSameFrame = false
            }
            sizeLock.unlock()
        }
        return rendered
    }

    /// Computes the full-window subtitle canvas (including letterbox black bars) and exact letterbox margins
    /// so ASS, SRT, and PGS subtitles can render freely into top/bottom black bars at crisp resolution.
    public func subtitleViewportMetrics(videoWidth: Int, videoHeight: Int) -> (canvasW: Int32, canvasH: Int32, marginT: Int32, marginB: Int32, marginL: Int32, marginR: Int32) {
        sizeLock.lock()
        let drawSize = cachedDrawableSize
        sizeLock.unlock()

        let vidW = max(1, videoWidth)
        let vidH = max(1, videoHeight)
        let viewW = drawSize.width > 16 ? drawSize.width : CGFloat(vidW)
        let viewH = drawSize.height > 16 ? drawSize.height : CGFloat(vidH)
        let viewAspect = max(0.25, min(6.0, viewW / max(1.0, viewH)))
        let videoAspect = max(0.25, min(6.0, CGFloat(vidW) / CGFloat(vidH)))

        // Normalize full-window subtitle canvas to <=1920px long edge for crisp typography & fast libass rasterization
        let maxEdge: CGFloat = 1920.0
        let canvasWFloat: CGFloat
        let canvasHFloat: CGFloat
        if viewAspect >= 1.0 {
            canvasWFloat = min(maxEdge, max(960.0, viewW))
            canvasHFloat = max(360.0, (canvasWFloat / viewAspect).rounded())
        } else {
            canvasHFloat = min(maxEdge, max(640.0, viewH))
            canvasWFloat = max(360.0, (canvasHFloat * viewAspect).rounded())
        }
        let canvasW = Int32(max(360, Int(canvasWFloat.rounded())))
        let canvasH = Int32(max(360, Int(canvasHFloat.rounded())))

        let dispW: Int32
        let dispH: Int32
        if videoAspect > viewAspect {
            // Letterboxed (black bars on top & bottom, e.g. 2.39:1 movie on 16:10 display)
            dispW = canvasW
            dispH = Int32(max(1, min(Int(canvasH), Int((CGFloat(canvasW) / videoAspect).rounded()))))
        } else {
            // Pillarboxed (black bars on left & right)
            dispH = canvasH
            dispW = Int32(max(1, min(Int(canvasW), Int((CGFloat(canvasH) * videoAspect).rounded()))))
        }
        let marginT = max(0, (canvasH - dispH) / 2)
        let marginB = max(0, canvasH - dispH - marginT)
        let marginL = max(0, (canvasW - dispW) / 2)
        let marginR = max(0, canvasW - dispW - marginL)
        return (canvasW, canvasH, marginT, marginB, marginL, marginR)
    }

    private func encodeSubtitleOverlayIfNeeded(
        encoder: MTLRenderCommandEncoder,
        scale: SIMD2<Float>,
        uniforms: inout DKGpuColorUniforms
    ) {
        guard hasActiveSubtitle,
              let subPipe = pipelineSubtitle,
              let subTex = subtitleTexture else {
            return
        }
        sizeLock.lock()
        let peakNits = _subtitleHDRPeakNits
        // Subtitle texture already covers the full window viewport (including letterbox bars),
        // so draw at full NDC scale (1, 1) and apply full-viewport liftNDC directly.
        let liftNDC = currentSubtitleLiftNDC
        sizeLock.unlock()
        var subVU = DKVertexUniforms(
            scale: SIMD2<Float>(1.0, 1.0),
            pad: SIMD2<Float>(peakNits, liftNDC),
            uvRect: SIMD4<Float>(0, 0, 1, 1)
        )
        encoder.setRenderPipelineState(subPipe)
        encoder.setVertexBytes(&subVU, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
        encoder.setFragmentTexture(subTex, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DKGpuColorUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func renderBiPlanar(pixelBuffer: CVPixelBuffer,
                                pipeline: MTLRenderPipelineState,
                                scale: inout SIMD2<Float>,
                                uniforms: inout DKGpuColorUniforms,
                                drawable: CAMetalDrawable,
                                queue: MTLCommandQueue,
                                cache: CVMetalTextureCache,
                                is10Bit: Bool) -> Bool {
        let widthY = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let heightY = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let widthUV = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let heightUV = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let cleanW = CVPixelBufferGetWidth(pixelBuffer)
        let cleanH = CVPixelBufferGetHeight(pixelBuffer)

        let yPixelFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let uvPixelFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

        var yTextureRef: CVMetalTexture?
        let statusY = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            yPixelFormat, widthY, heightY, 0, &yTextureRef
        )

        var uvTextureRef: CVMetalTexture?
        let statusUV = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            uvPixelFormat, widthUV, heightUV, 1, &uvTextureRef
        )

        guard statusY == kCVReturnSuccess, statusUV == kCVReturnSuccess,
              let yTex = yTextureRef.flatMap({ CVMetalTextureGetTexture($0) }),
              let uvTex = uvTextureRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
            return false
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return false
        }

        let uMax = widthY > 0 ? min(1.0, Float(cleanW) / Float(widthY)) : 1.0
        let vMax = heightY > 0 ? min(1.0, Float(cleanH) / Float(heightY)) : 1.0
        var vu = DKVertexUniforms(scale: scale, uvRect: SIMD4<Float>(0.0, 0.0, uMax, vMax))

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vu, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DKGpuColorUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encodeSubtitleOverlayIfNeeded(encoder: encoder, scale: scale, uniforms: &uniforms)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
        CVMetalTextureCacheFlush(cache, 0)
        return true
    }

    private func renderBGRA(pixelBuffer: CVPixelBuffer,
                            pipeline: MTLRenderPipelineState,
                            scale: inout SIMD2<Float>,
                            drawable: CAMetalDrawable,
                            queue: MTLCommandQueue,
                            cache: CVMetalTextureCache) -> Bool {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var bgraTextureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &bgraTextureRef
        )

        guard status == kCVReturnSuccess,
              let bgraTex = bgraTextureRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
            return false
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return false
        }

        var vu = DKVertexUniforms(scale: scale, uvRect: SIMD4<Float>(0.0, 0.0, 1.0, 1.0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vu, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
        encoder.setFragmentTexture(bgraTex, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        var sdrUniforms = DKGpuColorUniforms()
        sdrUniforms.edr_headroom = currentEDRHeadroom
        encodeSubtitleOverlayIfNeeded(encoder: encoder, scale: scale, uniforms: &sdrUniforms)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
        CVMetalTextureCacheFlush(cache, 0)
        return true
    }

    /// Renders a decoded `CVPixelBuffer` + `DKGpuColorUniforms` (+ optional RGBA8 subtitle bitmap)
    /// offscreen through the exact production Metal HDR/DoVi shader into a Display P3 `CGImage`.
    private final class OffscreenMetalContext: @unchecked Sendable {
        static let shared = OffscreenMetalContext()
        let lock = NSLock()
        let device: MTLDevice?
        let queue: MTLCommandQueue?
        let texCache: CVMetalTextureCache?
        let videoPipeline: MTLRenderPipelineState?
        let bgraPipeline: MTLRenderPipelineState?
        let subPipeline: MTLRenderPipelineState?
        var stagingTexture: MTLTexture?
        var stagingSize: (width: Int, height: Int) = (0, 0)

        private init() {
            guard let dev = MTLCreateSystemDefaultDevice(),
                  let q = dev.makeCommandQueue() else {
                self.device = nil; self.queue = nil; self.texCache = nil
                self.videoPipeline = nil; self.bgraPipeline = nil; self.subPipeline = nil
                return
            }
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
            self.device = dev
            self.queue = q
            self.texCache = cache

            let pipelines = DKMetalPipelineSet.cached(
                device: dev,
                shaderSource: DKMetalLayerView.metalShaderSource,
                pixelFormat: .rgba8Unorm_srgb
            )
            self.videoPipeline = pipelines?.videoPipeline
            self.bgraPipeline = pipelines?.bgraPipeline
            self.subPipeline = pipelines?.subPipeline
        }
    }

    nonisolated public static func renderOffscreenCGImage(
        pixelBuffer: CVPixelBuffer,
        colorUniforms: DKGpuColorUniforms,
        edrHeadroom: Float = 1.0,
        subtitleRGBA: UnsafePointer<UInt8>? = nil,
        subtitleWidth: Int = 0,
        subtitleHeight: Int = 0,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        maxDimension: Int? = nil
    ) -> CGImage? {
        let ctx = OffscreenMetalContext.shared
        ctx.lock.lock()
        defer { ctx.lock.unlock() }

        guard let dev = ctx.device,
              let queue = ctx.queue,
              let texCache = ctx.texCache,
              let videoPipe = ctx.videoPipeline else { return nil }

        let cleanW = CVPixelBufferGetWidth(pixelBuffer)
        let cleanH = CVPixelBufferGetHeight(pixelBuffer)
        var outW = outputWidth ?? cleanW
        var outH = outputHeight ?? cleanH
        if outputWidth == nil && outputHeight == nil, let maxDim = maxDimension, maxDim > 0 {
            let longest = max(cleanW, cleanH)
            if longest > maxDim {
                let ratio = Double(maxDim) / Double(longest)
                outW = max(2, Int((Double(cleanW) * ratio).rounded()))
                outH = max(2, Int((Double(cleanH) * ratio).rounded()))
            }
        }
        guard outW > 0, outH > 0 else { return nil }

        if ctx.stagingTexture == nil || ctx.stagingSize.width != outW || ctx.stagingSize.height != outH {
            let outDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb,
                width: outW,
                height: outH,
                mipmapped: false
            )
            outDesc.usage = [.renderTarget, .shaderRead]
            outDesc.storageMode = .shared
            ctx.stagingTexture = dev.makeTexture(descriptor: outDesc)
            ctx.stagingSize = (outW, outH)
        }
        guard let outTex = ctx.stagingTexture else { return nil }

        let pf = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var uniforms = colorUniforms
        uniforms.edr_headroom = max(1.0, edrHeadroom)

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = outTex
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) else { return nil }

        if pf == kCVPixelFormatType_32BGRA || pf == 0x42475241 {
            guard let bgraPipe = ctx.bgraPipeline else { enc.endEncoding(); return nil }
            var bgraRef: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, pixelBuffer, nil, .bgra8Unorm, cleanW, cleanH, 0, &bgraRef) == kCVReturnSuccess,
                  let bgraTex = bgraRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
                enc.endEncoding()
                return nil
            }
            var vu = DKVertexUniforms(scale: SIMD2<Float>(1, 1), uvRect: SIMD4<Float>(0, 0, 1, 1))
            enc.setRenderPipelineState(bgraPipe)
            enc.setVertexBytes(&vu, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
            enc.setFragmentTexture(bgraTex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else {
            let is10Bit = isTenBitBiPlanar(pf)
            if is10Bit && uniforms.bit_depth < 10 { uniforms.bit_depth = 10 }
            let widthY = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let heightY = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let widthUV = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let heightUV = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

            var yRef: CVMetalTexture?
            var uvRef: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, pixelBuffer, nil, is10Bit ? .r16Unorm : .r8Unorm, widthY, heightY, 0, &yRef) == kCVReturnSuccess,
                  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, pixelBuffer, nil, is10Bit ? .rg16Unorm : .rg8Unorm, widthUV, heightUV, 1, &uvRef) == kCVReturnSuccess,
                  let yTex = yRef.flatMap({ CVMetalTextureGetTexture($0) }),
                  let uvTex = uvRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
                enc.endEncoding()
                return nil
            }

            let uMax = widthY > 0 ? min(1.0, Float(cleanW) / Float(widthY)) : 1.0
            let vMax = heightY > 0 ? min(1.0, Float(cleanH) / Float(heightY)) : 1.0
            var vu = DKVertexUniforms(scale: SIMD2<Float>(1, 1), uvRect: SIMD4<Float>(0, 0, uMax, vMax))
            enc.setRenderPipelineState(videoPipe)
            enc.setVertexBytes(&vu, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
            enc.setFragmentTexture(yTex, index: 0)
            enc.setFragmentTexture(uvTex, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<DKGpuColorUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if let subPtr = subtitleRGBA, subtitleWidth > 0, subtitleHeight > 0,
           let subPipe = ctx.subPipeline {
            let sDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: subtitleWidth, height: subtitleHeight, mipmapped: false)
            if let sTex = dev.makeTexture(descriptor: sDesc) {
                sTex.replace(region: MTLRegionMake2D(0, 0, subtitleWidth, subtitleHeight), mipmapLevel: 0, withBytes: subPtr, bytesPerRow: subtitleWidth * 4)
                var svu = DKVertexUniforms(scale: SIMD2<Float>(1, 1), uvRect: SIMD4<Float>(0, 0, 1, 1))
                enc.setRenderPipelineState(subPipe)
                enc.setVertexBytes(&svu, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
                enc.setFragmentTexture(sTex, index: 0)
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<DKGpuColorUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        CVMetalTextureCacheFlush(texCache, 0)

        // GPU hardware already encoded linear Display P3 -> sRGB Display P3 RGBA8 via .rgba8Unorm_srgb
        var rgba8Data = Data(count: outW * outH * 4)
        rgba8Data.withUnsafeMutableBytes { rawBuf in
            if let base = rawBuf.baseAddress {
                outTex.getBytes(base, bytesPerRow: outW * 4, from: MTLRegionMake2D(0, 0, outW, outH), mipmapLevel: 0)
            }
        }

        guard let cs = CGColorSpace(name: CGColorSpace.displayP3),
              let provider = CGDataProvider(data: rgba8Data as CFData) else { return nil }
        return CGImage(
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: outW * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

// MARK: - SwiftUI Representable

public struct DKMetalVideoView: NSViewRepresentable {
    public let playerHandle: OpaquePointer?
    public let controlsOcclusionHeight: CGFloat
    public let subtitleHDRPeakNits: Float
    public let antiOcclusionEnabled: Bool
    public let subtitleStyleRevision: Int
    public let onFirstFrameRendered: (() -> Void)?

    public init(
        playerHandle: OpaquePointer?,
        controlsOcclusionHeight: CGFloat = 0,
        subtitleHDRPeakNits: Float = 203.0,
        antiOcclusionEnabled: Bool = false,
        subtitleStyleRevision: Int = 0,
        onFirstFrameRendered: (() -> Void)? = nil
    ) {
        self.playerHandle = playerHandle
        self.controlsOcclusionHeight = controlsOcclusionHeight
        self.subtitleHDRPeakNits = subtitleHDRPeakNits
        self.antiOcclusionEnabled = antiOcclusionEnabled
        self.subtitleStyleRevision = subtitleStyleRevision
        self.onFirstFrameRendered = onFirstFrameRendered
    }

    public func makeNSView(context: Context) -> DKMetalLayerView {
        let view = DKMetalLayerView()
        view.controlsOcclusionHeightPoints = controlsOcclusionHeight
        view.subtitleHDRPeakNits = subtitleHDRPeakNits
        view.antiOcclusionEnabled = antiOcclusionEnabled
        let coordinator = context.coordinator
        coordinator.lastSubtitleStyleRevision = subtitleStyleRevision
        coordinator.onFirstFrameRendered = onFirstFrameRendered
        view.onDetachFromWindow = { [weak coordinator] in
            coordinator?.stopDisplayLink()
        }
        context.coordinator.startDisplayLink(for: view, player: playerHandle)
        return view
    }

    public func updateNSView(_ nsView: DKMetalLayerView, context: Context) {
        nsView.controlsOcclusionHeightPoints = controlsOcclusionHeight
        nsView.subtitleHDRPeakNits = subtitleHDRPeakNits
        nsView.antiOcclusionEnabled = antiOcclusionEnabled
        context.coordinator.onFirstFrameRendered = onFirstFrameRendered
        if context.coordinator.lastSubtitleStyleRevision != subtitleStyleRevision {
            context.coordinator.lastSubtitleStyleRevision = subtitleStyleRevision
            nsView.needsRedrawOnSameFrame = true
        }
        if context.coordinator.player != playerHandle {
            context.coordinator.updatePlayer(playerHandle)
        }
    }

    public static func dismantleNSView(_ nsView: DKMetalLayerView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: DKMetalLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public final class Coordinator {
        private let playerLock = NSLock()
        private var _player: OpaquePointer?
        public var player: OpaquePointer? {
            get {
                playerLock.lock()
                defer { playerLock.unlock() }
                return _player
            }
            set {
                updatePlayer(newValue)
            }
        }
        private weak var view: DKMetalLayerView?
        private let driver = DisplayLinkDriver()
        fileprivate var lastSubtitleStyleRevision: Int = 0
        var lastPts: Double = -1.0
        var lastBufferPtr: UnsafeMutableRawPointer?
        var lastSubSerial: UInt64 = UInt64.max
        private var lastPausedCheckTime: TimeInterval = 0
        private var didNotifyFirstFrame: Bool = false
        private var _onFirstFrameRendered: (() -> Void)?
        public var onFirstFrameRendered: (() -> Void)? {
            get {
                playerLock.lock()
                defer { playerLock.unlock() }
                return _onFirstFrameRendered
            }
            set {
                playerLock.lock()
                _onFirstFrameRendered = newValue
                playerLock.unlock()
            }
        }

        private final class SubtitleSyncBox {
            unowned let view: DKMetalLayerView
            var updatedSerial: UInt64
            var changed: Bool = false

            init(view: DKMetalLayerView, serial: UInt64) {
                self.view = view
                self.updatedSerial = serial
            }
        }

        public func startDisplayLink(for view: DKMetalLayerView, player: OpaquePointer?) {
            playerLock.lock()
            self.view = view
            self.lastPts = -1.0
            self.lastBufferPtr = nil
            self.lastSubSerial = UInt64.max
            self._player = player
            self.didNotifyFirstFrame = false
            playerLock.unlock()

            driver.start { [weak self] in
                self?.tick()
            }
        }

        public func updatePlayer(_ newPlayer: OpaquePointer?) {
            if newPlayer == nil {
                driver.stop()
                view?.clearDisplayedFrame()
            }
            playerLock.lock()
            _player = newPlayer
            lastPts = -1.0
            lastBufferPtr = nil
            lastSubSerial = UInt64.max
            didNotifyFirstFrame = false
            playerLock.unlock()
            view?.updateSubtitleOverlay(rgbaPtr: nil, width: 0, height: 0)
            if newPlayer != nil && view != nil {
                driver.start { [weak self] in
                    self?.tick()
                }
            }
        }

        public func stopDisplayLink() {
            driver.stop()
            playerLock.lock()
            _player = nil
            lastPts = -1.0
            lastBufferPtr = nil
            lastSubSerial = UInt64.max
            playerLock.unlock()
        }

        private func tick() {
            playerLock.lock()
            let p = _player
            let v = self.view
            let prevPts = lastPts
            let prevBufferPtr = lastBufferPtr
            let prevSubSerial = lastSubSerial
            playerLock.unlock()
            guard let p = p, let v = v else { return }

            let liftAnimating = v.stepSubtitleLiftAnimation(dt: Float(1.0 / 60.0))
            let needsRedraw = v.needsRedrawOnSameFrame || liftAnimating
            let state = dk_player_get_state(p)
            if !needsRedraw && prevBufferPtr != nil && (state == DK_STATE_PAUSED || state == DK_STATE_ENDED) {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPausedCheckTime < 0.05 {
                    return
                }
                lastPausedCheckTime = now
            }

            var pts: Double = 0
            var colorUniforms = DKGpuColorUniforms()
            guard let unmanagedBuf = dk_player_acquire_frame(p, &pts, &colorUniforms) else {
                return
            }
            let pixbuf = unmanagedBuf.takeRetainedValue()
            let bufPtr = Unmanaged.passUnretained(pixbuf).toOpaque()

            let masterPos = dk_player_get_position(p)
            let subClockPts = masterPos > 0 ? masterPos : max(0.0, pts)
            let videoW = max(640, CVPixelBufferGetWidth(pixbuf))
            let videoH = max(360, CVPixelBufferGetHeight(pixbuf))
            let vp = v.subtitleViewportMetrics(videoWidth: videoW, videoHeight: videoH)
            dk_player_set_subtitle_viewport(p, vp.canvasW, vp.canvasH, Int32(videoW), Int32(videoH), vp.marginT, vp.marginB, vp.marginL, vp.marginR)
            let syncBox = SubtitleSyncBox(view: v, serial: prevSubSerial)
            let boxPtr = Unmanaged.passUnretained(syncBox).toOpaque()
            dk_player_sync_subtitle_rgba(p, subClockPts, vp.canvasW, vp.canvasH, prevSubSerial, { rgba, w, h, serial, ctx in
                guard let ctx else { return }
                let box = Unmanaged<SubtitleSyncBox>.fromOpaque(ctx).takeUnretainedValue()
                box.updatedSerial = serial
                box.changed = true
                if let rgba, w > 0, h > 0 {
                    box.view.updateSubtitleOverlay(rgbaPtr: rgba, width: Int(w), height: Int(h))
                } else {
                    box.view.updateSubtitleOverlay(rgbaPtr: nil, width: 0, height: 0)
                }
            }, boxPtr)
            let subtitleChanged = syncBox.changed
            if subtitleChanged {
                var by0: Int32 = 0
                var by1: Int32 = 0
                var bch: Int32 = 0
                if dk_player_get_subtitle_vertical_bounds(p, &by0, &by1, &bch) {
                    v.updateSubtitleVerticalBounds(y0: by0, y1: by1, canvasH: bch)
                } else {
                    v.updateSubtitleVerticalBounds(y0: 0, y1: 0, canvasH: 0)
                }
                _ = v.stepSubtitleLiftAnimation(dt: Float(1.0 / 60.0))
            }

            // Deduplication: if PTS and pointer match the last displayed frame and the view
            // has not resized and subtitle overlay has not changed, avoid redundant GPU load
            if bufPtr == prevBufferPtr && pts == prevPts && !subtitleChanged && !needsRedraw {
                return
            }

            if v.renderPixelBuffer(pixbuf, colorUniforms: colorUniforms) {
                var notifyCallback: (() -> Void)? = nil
                playerLock.lock()
                if _player == p {
                    lastPts = pts
                    lastBufferPtr = bufPtr
                    lastSubSerial = syncBox.updatedSerial
                    if !didNotifyFirstFrame {
                        didNotifyFirstFrame = true
                        notifyCallback = _onFirstFrameRendered
                    }
                }
                playerLock.unlock()
                if let notifyCallback {
                    DispatchQueue.main.async {
                        notifyCallback()
                    }
                }
            } else if subtitleChanged {
                v.needsRedrawOnSameFrame = true
            }
        }

        deinit {
            stopDisplayLink()
        }
    }
}
