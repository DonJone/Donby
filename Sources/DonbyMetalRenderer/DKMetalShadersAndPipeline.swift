import AppKit
import Metal
import simd
import DonbyKernelC

// MARK: - Metal Vertex Uniforms & Pipeline Cache

struct DKToneMapConstants {
    var wSrc: Float
    var maxLum: Float
    var ks: Float
    var dstPeakNits: Float

    init(uniforms: DKGpuColorUniforms) {
        let headroom = max(uniforms.edr_headroom, 1.0)
        let dstPeak = Float(203.0) * headroom
        let srcPeak: Float = (uniforms.transfer_fn == 2)
            ? max(uniforms.source_peak_nits, 1000.0)
            : max(uniforms.source_peak_nits, 203.0)
        let w = max(Self.nitsToPQ(srcPeak), 1e-4)
        let mLum = min(max(Self.nitsToPQ(dstPeak) / w, 0.05), 1.0)
        let k = max(1.5 * mLum - 0.5, 0.10)
        self.wSrc = w
        self.maxLum = mLum
        self.ks = k
        self.dstPeakNits = dstPeak
    }

    private static func nitsToPQ(_ nits: Float) -> Float {
        let y = min(max(nits / 10000.0, 0.0), 1.0)
        let m1: Float = 2610.0 / 16384.0
        let m2: Float = (2523.0 / 4096.0) * 128.0
        let c1: Float = 3424.0 / 4096.0
        let c2: Float = (2413.0 / 4096.0) * 32.0
        let c3: Float = (2392.0 / 4096.0) * 32.0
        let ym = powf(y, m1)
        return powf((c1 + c2 * ym) / (1.0 + c3 * ym), m2)
    }
}

struct DKSubtitleFragmentUniforms {
    var edr_headroom: Float
    var transfer_fn: Int32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

struct DKVertexUniforms {
    var scale: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
    var uvRect: SIMD4<Float>
}

final class DKMetalPipelineSet: @unchecked Sendable {
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

// MARK: - Embedded Metal Shader Source & Pipeline Prewarming

extension DKMetalLayerView {
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

    struct DKToneMapConstantsMSL {
        float wSrc;
        float maxLum;
        float ks;
        float dstPeakNits;
    };

    struct DKSubtitleFragmentUniformsMSL {
        float edr_headroom;
        int transfer_fn;
        uint pad0;
        uint pad1;
    };

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
    inline float bt2390_eetf_nits(float inNits, float srcPeakNits, constant DKToneMapConstantsMSL &tm) {
        if (tm.dstPeakNits >= srcPeakNits - 1.0f) {
            return min(inNits, tm.dstPeakNits);
        }
        float e1 = clamp(nits_to_pq_scalar(inNits) / tm.wSrc, 0.0f, 1.0f);
        float maxLum = tm.maxLum;
        float ks = tm.ks;
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
        return pq_to_nits_scalar(clamp(e2 * tm.wSrc, 0.0f, 1.0f));
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
                                          constant DKGpuColorUniformsMSL &u [[buffer(0)]],
                                          constant DKToneMapConstantsMSL &tm [[buffer(1)]]) {
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
                    float mappedNits = bt2390_eetf_nits(sigNits, srcPeak, tm);
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
                    float mappedNits = bt2390_eetf_nits(sigNits, srcPeak, tm);
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
                                      constant DKSubtitleFragmentUniformsMSL &u [[buffer(0)]]) {
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
        guard let dev = DKMetalLayerView.preferredMetalDevice(for: nil) ?? MTLCreateSystemDefaultDevice() else { return }
        let targetFormat = DKMetalLayerView.preferredLayerFormat(device: dev, screen: nil).pixelFormat
        _ = DKMetalPipelineSet.cached(device: dev, shaderSource: Self.metalShaderSource, pixelFormat: targetFormat)
    }
}
