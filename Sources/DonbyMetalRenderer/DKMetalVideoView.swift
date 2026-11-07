import SwiftUI
import AppKit
import MetalKit
import CoreVideo
import CoreGraphics
import DonbyKernelC

// MARK: - Display Link Driver (CVDisplayLink with High-Frequency Common-Mode Timer Fallback)

private final class DisplayLinkDriver {
    private var displayLink: CVDisplayLink?
    private var fallbackTimer: Timer?
    private var handler: (() -> Void)?
    private let lock = NSLock()
    private var isRunning = false

    func start(handler: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }

        stopInternal()

        self.handler = handler
        self.isRunning = true

        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if status == kCVReturnSuccess, let link = link {
            let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
                guard let userInfo = userInfo else { return kCVReturnSuccess }
                let driver = Unmanaged<DisplayLinkDriver>.fromOpaque(userInfo).takeUnretainedValue()
                driver.tick()
                return kCVReturnSuccess
            }
            CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
            CVDisplayLinkStart(link)
            self.displayLink = link
        } else {
            // Fallback for headless environments or when CVDisplayLink fails:
            // High-frequency 60Hz timer registered in .common mode so it never freezes
            // during window dragging or menu interactions.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRunning else { return }
                let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    self?.tick()
                }
                RunLoop.main.add(timer, forMode: .common)
                self.fallbackTimer = timer
            }
        }
    }

    private func tick() {
        guard isRunning else { return }
        handler?()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopInternal()
    }

    private func stopInternal() {
        isRunning = false
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        if let timer = fallbackTimer {
            timer.invalidate()
            fallbackTimer = nil
        }
        handler = nil
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
    private var cachedDrawableSize: CGSize = .zero
    private var cachedEDRHeadroom: Float = 1.0
    private var screenObserver: NSObjectProtocol?

    // Subtitle GPU texture cache (updated only when subtitle serial changes)
    private var subtitleTexture: MTLTexture?
    private var subtitleTexWidth: Int = 0
    private var subtitleTexHeight: Int = 0
    private var hasActiveSubtitle: Bool = false

    public private(set) var lastPixelBuffer: CVPixelBuffer?
    public private(set) var lastColorUniforms = DKGpuColorUniforms()
    public var needsRedrawOnSameFrame: Bool = false
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
        updateDrawableSize()
        updateScreenHeadroom()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            onDetachFromWindow?()
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        updateScreenHeadroom()
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
        sizeLock.unlock()
    }

    public static let metalShaderSource = """
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
        out.position = float4(positions[vertexID] * vu.scale, 0.0f, 1.0f);
        out.texCoord = texCoords[vertexID];
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
        float paperWhite = (u.transfer_fn != 0)
            ? mix(0.90f, 0.98f, clamp((max(u.edr_headroom, 1.0f) - 1.0f) / 1.5f, 0.0f, 1.0f))
            : 0.88f;
        float3 lin = srgb_to_linear(srgb) * paperWhite;
        float3 p3 = gamut_map_to_linear_p3(lin, 0);
        return float4(p3 * sub.a, sub.a);
    }
    """

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

        do {
            let library = try dev.makeLibrary(source: Self.metalShaderSource, options: nil)
            guard let vert = library.makeFunction(name: "vertex_main") else {
                print("[DonbyMetal] Failed to find vertex_main function")
                return
            }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vert
            desc.colorAttachments[0].pixelFormat = .rgba16Float

            if let fragMaster = library.makeFunction(name: "fragment_video_master") {
                desc.fragmentFunction = fragMaster
                self.pipelineVideoMaster = try dev.makeRenderPipelineState(descriptor: desc)
            }

            if let fragBGRA = library.makeFunction(name: "fragment_bgra") {
                desc.fragmentFunction = fragBGRA
                self.pipelineBGRA = try dev.makeRenderPipelineState(descriptor: desc)
            }

            if let fragSub = library.makeFunction(name: "fragment_subtitle") {
                let subDesc = MTLRenderPipelineDescriptor()
                subDesc.vertexFunction = vert
                subDesc.fragmentFunction = fragSub
                subDesc.colorAttachments[0].pixelFormat = .rgba16Float
                subDesc.colorAttachments[0].isBlendingEnabled = true
                subDesc.colorAttachments[0].sourceRGBBlendFactor = .one
                subDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                subDesc.colorAttachments[0].rgbBlendOperation = .add
                subDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
                subDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                subDesc.colorAttachments[0].alphaBlendOperation = .add
                self.pipelineSubtitle = try dev.makeRenderPipelineState(descriptor: subDesc)
            }
        } catch {
            print("[DonbyMetal] Pipeline create failed:", error)
        }
    }

    public func updateSubtitleOverlay(rgbaPtr: UnsafePointer<UInt8>?, width: Int, height: Int) {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard let ptr = rgbaPtr, width > 0, height > 0, let dev = device else {
            hasActiveSubtitle = false
            return
        }

        if subtitleTexture == nil || subtitleTexWidth != width || subtitleTexHeight != height {
            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            texDesc.usage = [.shaderRead]
            subtitleTexture = dev.makeTexture(descriptor: texDesc)
            subtitleTexWidth = width
            subtitleTexHeight = height
        }

        if let tex = subtitleTexture {
            let region = MTLRegionMake2D(0, 0, width, height)
            tex.replace(region: region, mipmapLevel: 0, withBytes: ptr, bytesPerRow: width * 4)
            hasActiveSubtitle = true
        }
    }

    public func renderLastPixelBuffer() {
        guard let pixbuf = lastPixelBuffer else { return }
        renderPixelBuffer(pixbuf, colorUniforms: lastColorUniforms)
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

    public func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, colorUniforms: DKGpuColorUniforms? = nil) {
        guard renderLock.try() else { return }
        defer { renderLock.unlock() }

        self.lastPixelBuffer = pixelBuffer
        var uniforms = colorUniforms ?? self.lastColorUniforms
        uniforms.edr_headroom = currentEDRHeadroom
        self.lastColorUniforms = uniforms
        self.needsRedrawOnSameFrame = false

        if metalLayer.drawableSize.width <= 0 || metalLayer.drawableSize.height <= 0 {
            updateDrawableSize()
        }

        guard let queue = commandQueue,
              let cache = textureCache,
              let drawable = metalLayer.nextDrawable() else {
            return
        }

        let cleanWidth = CVPixelBufferGetWidth(pixelBuffer)
        let cleanHeight = CVPixelBufferGetHeight(pixelBuffer)
        let sar = Double(uniforms.ycc_offset.3 > 0.05 ? uniforms.ycc_offset.3 : 1.0)
        let videoWidth = Double(cleanWidth) * sar
        let videoHeight = Double(cleanHeight)
        var scale = calculateScale(videoWidth: videoWidth, videoHeight: videoHeight)

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let pipeline = pipelineVideoMaster else { return }
            uniforms.bit_depth = 8
            renderBiPlanar(pixelBuffer: pixelBuffer,
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
            guard let pipeline = pipelineVideoMaster else { return }
            if uniforms.bit_depth < 10 { uniforms.bit_depth = 10 }
            renderBiPlanar(pixelBuffer: pixelBuffer,
                           pipeline: pipeline,
                           scale: &scale,
                           uniforms: &uniforms,
                           drawable: drawable,
                           queue: queue,
                           cache: cache,
                           is10Bit: true)

        case kCVPixelFormatType_32BGRA,
             0x42475241: // 'BGRA'
            guard let pipeline = pipelineBGRA else { return }
            renderBGRA(pixelBuffer: pixelBuffer,
                       pipeline: pipeline,
                       scale: &scale,
                       drawable: drawable,
                       queue: queue,
                       cache: cache)

        default:
            let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
            if planeCount == 2 {
                guard let pipeline = pipelineVideoMaster else { return }
                renderBiPlanar(pixelBuffer: pixelBuffer,
                               pipeline: pipeline,
                               scale: &scale,
                               uniforms: &uniforms,
                               drawable: drawable,
                               queue: queue,
                               cache: cache,
                               is10Bit: false)
            } else {
                guard let pipeline = pipelineBGRA else { return }
                renderBGRA(pixelBuffer: pixelBuffer,
                           pipeline: pipeline,
                           scale: &scale,
                           drawable: drawable,
                           queue: queue,
                           cache: cache)
            }
        }
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
        var subVU = DKVertexUniforms(scale: scale, uvRect: SIMD4<Float>(0, 0, 1, 1))
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
                                is10Bit: Bool) {
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
            return
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
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
    }

    private func renderBGRA(pixelBuffer: CVPixelBuffer,
                            pipeline: MTLRenderPipelineState,
                            scale: inout SIMD2<Float>,
                            drawable: CAMetalDrawable,
                            queue: MTLCommandQueue,
                            cache: CVMetalTextureCache) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var bgraTextureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &bgraTextureRef
        )

        guard status == kCVReturnSuccess,
              let bgraTex = bgraTextureRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
            return
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
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
    }

    /// Renders a decoded `CVPixelBuffer` + `DKGpuColorUniforms` (+ optional RGBA8 subtitle bitmap)
    /// offscreen through the exact production Metal HDR/DoVi shader into a Display P3 `CGImage`.
    public static func renderOffscreenCGImage(
        pixelBuffer: CVPixelBuffer,
        colorUniforms: DKGpuColorUniforms,
        edrHeadroom: Float = 1.0,
        subtitleRGBA: UnsafePointer<UInt8>? = nil,
        subtitleWidth: Int = 0,
        subtitleHeight: Int = 0,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil
    ) -> CGImage? {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache) == kCVReturnSuccess,
              let texCache = cache else { return nil }

        guard let library = try? dev.makeLibrary(source: metalShaderSource, options: nil),
              let vert = library.makeFunction(name: "vertex_main"),
              let fragMaster = library.makeFunction(name: "fragment_video_master") else { return nil }

        let pipeDesc = MTLRenderPipelineDescriptor()
        pipeDesc.vertexFunction = vert
        pipeDesc.fragmentFunction = fragMaster
        pipeDesc.colorAttachments[0].pixelFormat = .rgba16Float
        guard let videoPipe = try? dev.makeRenderPipelineState(descriptor: pipeDesc) else { return nil }

        let cleanW = CVPixelBufferGetWidth(pixelBuffer)
        let cleanH = CVPixelBufferGetHeight(pixelBuffer)
        let outW = outputWidth ?? cleanW
        let outH = outputHeight ?? cleanH
        guard outW > 0, outH > 0 else { return nil }

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: outW,
            height: outH,
            mipmapped: false
        )
        outDesc.usage = [.renderTarget, .shaderRead]
        outDesc.storageMode = .shared
        guard let outTex = dev.makeTexture(descriptor: outDesc) else { return nil }

        let pf = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let is10Bit = (pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                       pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
                       pf == 0x78343230 || pf == 0x78663230 || pf == 0x70303130)
        let widthY = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let heightY = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let widthUV = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let heightUV = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        var yRef: CVMetalTexture?
        var uvRef: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, pixelBuffer, nil, is10Bit ? .r16Unorm : .r8Unorm, widthY, heightY, 0, &yRef) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, pixelBuffer, nil, is10Bit ? .rg16Unorm : .rg8Unorm, widthUV, heightUV, 1, &uvRef) == kCVReturnSuccess,
              let yTex = yRef.flatMap({ CVMetalTextureGetTexture($0) }),
              let uvTex = uvRef.flatMap({ CVMetalTextureGetTexture($0) }) else { return nil }

        var uniforms = colorUniforms
        uniforms.edr_headroom = max(1.0, edrHeadroom)
        if is10Bit && uniforms.bit_depth < 10 { uniforms.bit_depth = 10 }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = outTex
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) else { return nil }

        let uMax = widthY > 0 ? min(1.0, Float(cleanW) / Float(widthY)) : 1.0
        let vMax = heightY > 0 ? min(1.0, Float(cleanH) / Float(heightY)) : 1.0
        var vu = DKVertexUniforms(scale: SIMD2<Float>(1, 1), uvRect: SIMD4<Float>(0, 0, uMax, vMax))
        enc.setRenderPipelineState(videoPipe)
        enc.setVertexBytes(&vu, length: MemoryLayout<DKVertexUniforms>.stride, index: 0)
        enc.setFragmentTexture(yTex, index: 0)
        enc.setFragmentTexture(uvTex, index: 1)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<DKGpuColorUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        if let subPtr = subtitleRGBA, subtitleWidth > 0, subtitleHeight > 0,
           let fragSub = library.makeFunction(name: "fragment_subtitle") {
            let subPipeDesc = MTLRenderPipelineDescriptor()
            subPipeDesc.vertexFunction = vert
            subPipeDesc.fragmentFunction = fragSub
            subPipeDesc.colorAttachments[0].pixelFormat = .rgba16Float
            subPipeDesc.colorAttachments[0].isBlendingEnabled = true
            subPipeDesc.colorAttachments[0].sourceRGBBlendFactor = .one
            subPipeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            subPipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            subPipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            if let subPipe = try? dev.makeRenderPipelineState(descriptor: subPipeDesc) {
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
        }

        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        // Convert linear Display P3 Float16 -> 8-bit Display P3 RGBA for clean CGImage export
        var rawF16 = [UInt16](repeating: 0, count: outW * outH * 4)
        outTex.getBytes(&rawF16, bytesPerRow: outW * 8, from: MTLRegionMake2D(0, 0, outW, outH), mipmapLevel: 0)

        func linearToSRGBByte(_ v: Float) -> UInt8 {
            let c = max(0.0, min(1.0, v))
            let s = (c <= 0.0031308) ? (12.92 * c) : (1.055 * pow(c, 1.0 / 2.4) - 0.055)
            return UInt8(max(0.0, min(255.0, (s * 255.0).rounded())))
        }

        var rgba8 = [UInt8](repeating: 255, count: outW * outH * 4)
        for i in 0..<(outW * outH) {
            let r = Float(Float16(bitPattern: rawF16[i * 4 + 0]))
            let g = Float(Float16(bitPattern: rawF16[i * 4 + 1]))
            let b = Float(Float16(bitPattern: rawF16[i * 4 + 2]))
            rgba8[i * 4 + 0] = linearToSRGBByte(r)
            rgba8[i * 4 + 1] = linearToSRGBByte(g)
            rgba8[i * 4 + 2] = linearToSRGBByte(b)
            rgba8[i * 4 + 3] = 255
        }

        guard let cs = CGColorSpace(name: CGColorSpace.displayP3),
              let provider = CGDataProvider(data: Data(rgba8) as CFData) else { return nil }
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

    public init(playerHandle: OpaquePointer?) {
        self.playerHandle = playerHandle
    }

    public func makeNSView(context: Context) -> DKMetalLayerView {
        let view = DKMetalLayerView()
        let coordinator = context.coordinator
        view.onDetachFromWindow = { [weak coordinator] in
            coordinator?.stopDisplayLink()
        }
        context.coordinator.startDisplayLink(for: view, player: playerHandle)
        return view
    }

    public func updateNSView(_ nsView: DKMetalLayerView, context: Context) {
        if context.coordinator.player != playerHandle {
            context.coordinator.updatePlayer(playerHandle)
        }
    }

    public static func dismantleNSView(_ nsView: DKMetalLayerView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
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
        var lastPts: Double = -1.0
        var lastBufferPtr: UnsafeMutableRawPointer?
        var lastSubSerial: UInt64 = UInt64.max

        public func startDisplayLink(for view: DKMetalLayerView, player: OpaquePointer?) {
            self.view = view
            self.lastPts = -1.0
            self.lastBufferPtr = nil
            self.lastSubSerial = UInt64.max
            playerLock.lock()
            self._player = player
            playerLock.unlock()

            driver.start { [weak self] in
                self?.tick()
            }
        }

        public func updatePlayer(_ newPlayer: OpaquePointer?) {
            if newPlayer == nil {
                driver.stop()
            }
            playerLock.lock()
            _player = newPlayer
            lastPts = -1.0
            lastBufferPtr = nil
            lastSubSerial = UInt64.max
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
            playerLock.unlock()
            guard let p = p, let v = v else { return }
            var pts: Double = 0
            var colorUniforms = DKGpuColorUniforms()
            guard let unmanagedBuf = dk_player_acquire_frame(p, &pts, &colorUniforms) else {
                return
            }
            let pixbuf = unmanagedBuf.takeRetainedValue()
            let bufPtr = Unmanaged.passUnretained(pixbuf).toOpaque()

            let masterPos = dk_player_get_position(p)
            let subClockPts = masterPos > 0 ? masterPos : max(0.0, pts)
            let cleanW = Int32(max(640, CVPixelBufferGetWidth(pixbuf)))
            let cleanH = Int32(max(360, CVPixelBufferGetHeight(pixbuf)))
            var subRgba: UnsafePointer<UInt8>? = nil
            var subW: Int32 = 0
            var subH: Int32 = 0
            var subSerial: UInt64 = 0
            let hasSub = dk_player_get_subtitle_rgba(p, subClockPts, cleanW, cleanH, &subRgba, &subW, &subH, &subSerial)

            var subtitleChanged = false
            if subSerial != lastSubSerial {
                lastSubSerial = subSerial
                subtitleChanged = true
                if hasSub, let ptr = subRgba, subW > 0, subH > 0 {
                    v.updateSubtitleOverlay(rgbaPtr: ptr, width: Int(subW), height: Int(subH))
                } else {
                    v.updateSubtitleOverlay(rgbaPtr: nil, width: 0, height: 0)
                }
            }

            // Deduplication: if PTS and pointer match the last displayed frame and the view
            // has not resized and subtitle overlay has not changed, avoid redundant GPU load
            if bufPtr == lastBufferPtr && pts == lastPts && !subtitleChanged && !v.needsRedrawOnSameFrame {
                return
            }

            lastPts = pts
            lastBufferPtr = bufPtr
            v.renderPixelBuffer(pixbuf, colorUniforms: colorUniforms)
        }

        deinit {
            stopDisplayLink()
        }
    }
}
