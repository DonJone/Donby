#include "dk_ffi_shim_internal.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/hwcontext.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>

// -----------------------------------------------------------------------------
// Video Decoder, Color/DoVi Uniform Builder & Thumbnail Extraction
// -----------------------------------------------------------------------------

typedef struct {
    void* rust_opaque;
    bool (*is_vt_failed)(void*);
    void (*on_sw_format_selected)(void*);
} DKShimHwFormatCtx;

static enum AVPixelFormat dk_shim_get_hw_format(AVCodecContext* ctx, const enum AVPixelFormat* pix_fmts) {
    DKShimHwFormatCtx* hctx = ctx ? (DKShimHwFormatCtx*)ctx->opaque : NULL;
    bool vt_failed = (hctx && hctx->is_vt_failed) ? hctx->is_vt_failed(hctx->rust_opaque) : false;
    if (!vt_failed) {
        for (const enum AVPixelFormat* p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
            if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
                return *p;
            }
        }
    }
    for (const enum AVPixelFormat* p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p != AV_PIX_FMT_VIDEOTOOLBOX) {
            if (hctx && hctx->on_sw_format_selected) {
                hctx->on_sw_format_selected(hctx->rust_opaque);
            }
            return *p;
        }
    }
    return AV_PIX_FMT_NONE;
}

void* dk_shim_alloc_hw_fmt_ctx(
    void* rust_opaque, bool (*is_vt_failed)(void*), void (*on_sw_format_selected)(void*)
) {
    DKShimHwFormatCtx* p = (DKShimHwFormatCtx*)calloc(1, sizeof(DKShimHwFormatCtx));
    if (p) {
        p->rust_opaque = rust_opaque;
        p->is_vt_failed = is_vt_failed;
        p->on_sw_format_selected = on_sw_format_selected;
    }
    return p;
}

void dk_shim_free_hw_fmt_ctx(void** ptr) {
    if (ptr && *ptr) {
        free(*ptr);
        *ptr = NULL;
    }
}

int dk_shim_open_video_decoder(
    const void* fmt_raw, int32_t stream_idx, bool hw_decode, int32_t sw_threads,
    void* hw_fmt_ctx_opaque, void** out_codec_ctx, void** out_hw_ctx,
    bool* out_is_hw, char out_dec_name[32]
) {
    const AVFormatContext* fmt = (const AVFormatContext*)fmt_raw;
    if (!fmt || !out_codec_ctx || !out_hw_ctx || !out_is_hw || stream_idx < 0 || (unsigned)stream_idx >= fmt->nb_streams) {
        return -1;
    }
    *out_codec_ctx = NULL;
    *out_hw_ctx = NULL;
    *out_is_hw = false;
    if (out_dec_name) out_dec_name[0] = '\0';

    const AVStream* st = fmt->streams[stream_idx];
    const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return AVERROR_DECODER_NOT_FOUND;

    AVCodecContext* ctx = avcodec_alloc_context3(dec);
    if (!ctx) return AVERROR(ENOMEM);
    avcodec_parameters_to_context(ctx, st->codecpar);
    ctx->opaque = hw_fmt_ctx_opaque;
    ctx->pkt_timebase = st->time_base;

    AVBufferRef* hw_dev = NULL;
    bool using_hw = false;
    if (hw_decode) {
        if (av_hwdevice_ctx_create(&hw_dev, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0 && hw_dev) {
            ctx->hw_device_ctx = av_buffer_ref(hw_dev);
            ctx->get_format = dk_shim_get_hw_format;
            ctx->hwaccel_flags |= AV_HWACCEL_FLAG_IGNORE_LEVEL |
                                  AV_HWACCEL_FLAG_ALLOW_HIGH_DEPTH |
                                  AV_HWACCEL_FLAG_ALLOW_PROFILE_MISMATCH;
            using_hw = true;
        }
    }
    if (!using_hw) {
        ctx->thread_count = sw_threads < 2 ? 2 : (sw_threads > 8 ? 8 : sw_threads);
        ctx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    }

    int ret = avcodec_open2(ctx, dec, NULL);
    if (ret < 0) {
        avcodec_free_context(&ctx);
        if (hw_dev) av_buffer_unref(&hw_dev);
        return ret;
    }

    if (out_dec_name && dec->name) {
        snprintf(out_dec_name, 32, "%s", dec->name);
    }
    *out_codec_ctx = ctx;
    *out_hw_ctx = hw_dev;
    *out_is_hw = using_hw;
    return 0;
}

void dk_shim_unref_hw_ctx(void** hw_ctx) {
    if (hw_ctx && *hw_ctx) {
        AVBufferRef* b = (AVBufferRef*)(*hw_ctx);
        av_buffer_unref(&b);
        *hw_ctx = NULL;
    }
}

static float dk_shim_pq_norm_to_nits(double e) {
    if (e <= 0.0) return 0.0f;
    const double m1 = 2610.0 / 16384.0;
    const double m2 = (2523.0 / 4096.0) * 128.0;
    const double c1 = 3424.0 / 4096.0;
    const double c2 = (2413.0 / 4096.0) * 32.0;
    const double c3 = (2392.0 / 4096.0) * 32.0;
    double ep = pow(e, 1.0 / m2);
    double num = fmax(ep - c1, 0.0);
    double den = fmax(c2 - c3 * ep, 1e-9);
    return (float)(10000.0 * pow(num / den, 1.0 / m1));
}

static void dk_shim_set_default_sdr_uniforms(DKGpuColorUniforms* u) {
    memset(u, 0, sizeof(*u));
    u->transfer_fn = 0;
    u->primaries = 0;
    u->is_full_range = 0;
    u->bit_depth = 8;
    u->source_peak_nits = 203.0f;
    u->edr_headroom = 1.0f;

    const float sy = 255.0f / 219.0f;
    const float sc = 255.0f / 224.0f;
    u->ycc_offset[0] = 16.0f / 255.0f;
    u->ycc_offset[1] = 128.0f / 255.0f;
    u->ycc_offset[2] = 128.0f / 255.0f;
    u->ycc_offset[3] = 1.0f;

    u->yuv_matrix_r0[0] = sy; u->yuv_matrix_r0[1] = 0.0f;              u->yuv_matrix_r0[2] = 1.5748f * sc;
    u->yuv_matrix_r1[0] = sy; u->yuv_matrix_r1[1] = -0.18732427f * sc; u->yuv_matrix_r1[2] = -0.46812427f * sc;
    u->yuv_matrix_r2[0] = sy; u->yuv_matrix_r2[1] = 1.8556f * sc;      u->yuv_matrix_r2[2] = 0.0f;

    u->lin_matrix_r0[0] = 1.0f;
    u->lin_matrix_r1[1] = 1.0f;
    u->lin_matrix_r2[2] = 1.0f;
}

static bool dk_shim_ensure_sw_pool(
    CVPixelBufferPoolRef* inout_pool, int32_t* inout_w, int32_t* inout_h,
    uint32_t* inout_fmt, int width, int height, OSType pix_fmt
) {
    if (*inout_pool && *inout_w == width && *inout_h == height && *inout_fmt == (uint32_t)pix_fmt) {
        return true;
    }
    if (*inout_pool) {
        CVPixelBufferPoolRelease(*inout_pool);
        *inout_pool = NULL;
    }
    CFMutableDictionaryRef io_attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
    CFMutableDictionaryRef pb_attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
    CFNumberRef w_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &width);
    CFNumberRef h_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &height);
    int32_t fmt_i32 = (int32_t)pix_fmt;
    CFNumberRef fmt_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &fmt_i32);

    CFDictionarySetValue(pb_attrs, kCVPixelBufferWidthKey, w_num);
    CFDictionarySetValue(pb_attrs, kCVPixelBufferHeightKey, h_num);
    CFDictionarySetValue(pb_attrs, kCVPixelBufferPixelFormatTypeKey, fmt_num);
    CFDictionarySetValue(pb_attrs, kCVPixelBufferIOSurfacePropertiesKey, io_attrs);
    CFDictionarySetValue(pb_attrs, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);

    CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, pb_attrs, inout_pool);
    CFRelease(fmt_num);
    CFRelease(h_num);
    CFRelease(w_num);
    CFRelease(pb_attrs);
    CFRelease(io_attrs);

    if (status != kCVReturnSuccess || !*inout_pool) {
        *inout_pool = NULL;
        return false;
    }
    *inout_w = width;
    *inout_h = height;
    *inout_fmt = (uint32_t)pix_fmt;
    return true;
}

static void dk_shim_build_color_uniforms(
    const AVFrame* frame, const AVFormatContext* fmt, int32_t video_stream_idx,
    uint8_t stream_dovi_profile, CVPixelBufferRef pixbuf, DKGpuColorUniforms* u,
    bool* out_is_hdr, bool* out_is_dovi, char out_cs_label[32]
) {
    dk_shim_set_default_sdr_uniforms(u);
    if (out_is_hdr) *out_is_hdr = false;
    if (out_is_dovi) *out_is_dovi = false;
    if (out_cs_label) out_cs_label[0] = '\0';
    if (!frame) return;

    const AVStream* st = (fmt && video_stream_idx >= 0 && (unsigned)video_stream_idx < fmt->nb_streams)
        ? fmt->streams[video_stream_idx]
        : NULL;

    OSType pf = pixbuf ? CVPixelBufferGetPixelFormatType(pixbuf) : 0;
    bool is_10bit_pixbuf = (pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                            pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
                            pf == 0x78343230 || pf == 0x78663230 || pf == 0x70303130);
    u->bit_depth = is_10bit_pixbuf ? 10 : 8;

    AVRational sar = frame->sample_aspect_ratio;
    if ((sar.num <= 0 || sar.den <= 0) && st) {
        sar = st->sample_aspect_ratio;
        if (sar.num <= 0 || sar.den <= 0) sar = st->codecpar->sample_aspect_ratio;
    }
    float sar_f = (sar.num > 0 && sar.den > 0) ? (float)av_q2d(sar) : 1.0f;
    if (!isfinite(sar_f) || sar_f <= 0.05f || sar_f > 10.0f) sar_f = 1.0f;

    enum AVColorTransferCharacteristic trc = frame->color_trc;
    if (trc == AVCOL_TRC_UNSPECIFIED && st) trc = st->codecpar->color_trc;

    enum AVColorPrimaries pri = frame->color_primaries;
    if (pri == AVCOL_PRI_UNSPECIFIED && st) pri = st->codecpar->color_primaries;

    enum AVColorSpace csp = frame->colorspace;
    if (csp == AVCOL_SPC_UNSPECIFIED && st) csp = st->codecpar->color_space;

    enum AVColorRange rng = frame->color_range;
    if (rng == AVCOL_RANGE_UNSPECIFIED && st) rng = st->codecpar->color_range;

    if (pixbuf && trc == AVCOL_TRC_UNSPECIFIED) {
        CFTypeRef tf = CVBufferCopyAttachment(pixbuf, kCVImageBufferTransferFunctionKey, NULL);
        if (tf) {
            if (CFGetTypeID(tf) == CFStringGetTypeID()) {
                CFStringRef s = (CFStringRef)tf;
                if (CFStringCompare(s, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, 0) == kCFCompareEqualTo) {
                    trc = AVCOL_TRC_SMPTE2084;
                } else if (CFStringCompare(s, kCVImageBufferTransferFunction_ITU_R_2100_HLG, 0) == kCFCompareEqualTo) {
                    trc = AVCOL_TRC_ARIB_STD_B67;
                }
            }
            CFRelease(tf);
        }
    }

    bool full_range = (rng == AVCOL_RANGE_JPEG ||
                       pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                       pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
                       pf == 0x78663230);
    u->is_full_range = full_range ? 1 : 0;

    if (trc == AVCOL_TRC_SMPTE2084) {
        u->transfer_fn = 1;
        u->source_peak_nits = 1000.0f;
        if (out_is_hdr) *out_is_hdr = true;
        if (out_cs_label) snprintf(out_cs_label, 32, "BT.2020 PQ (HDR10)");
    } else if (trc == AVCOL_TRC_ARIB_STD_B67) {
        u->transfer_fn = 2;
        u->source_peak_nits = 1000.0f;
        if (out_is_hdr) *out_is_hdr = true;
        if (out_cs_label) snprintf(out_cs_label, 32, "BT.2020 HLG");
    } else {
        u->transfer_fn = 0;
        u->source_peak_nits = 203.0f;
    }

    if (pri == AVCOL_PRI_BT2020) {
        u->primaries = 1;
    } else if (pri == AVCOL_PRI_SMPTE432 || pri == AVCOL_PRI_SMPTE431) {
        u->primaries = 2;
    } else {
        u->primaries = (u->transfer_fn != 0) ? 1 : 0;
    }

    float off_y = 0.0f, off_c = 0.5f, sy = 1.0f, sc = 1.0f;
    if (u->bit_depth >= 10) {
        if (full_range) {
            off_y = 0.0f; off_c = 512.0f / 1024.0f; sy = 1024.0f / 1023.0f; sc = 1024.0f / 1023.0f;
        } else {
            off_y = 64.0f / 1024.0f; off_c = 512.0f / 1024.0f; sy = 1024.0f / 876.0f; sc = 1024.0f / 896.0f;
        }
    } else {
        if (full_range) {
            off_y = 0.0f; off_c = 128.0f / 255.0f; sy = 1.0f; sc = 1.0f;
        } else {
            off_y = 16.0f / 255.0f; off_c = 128.0f / 255.0f; sy = 255.0f / 219.0f; sc = 255.0f / 224.0f;
        }
    }
    u->ycc_offset[0] = off_y;
    u->ycc_offset[1] = off_c;
    u->ycc_offset[2] = off_c;
    u->ycc_offset[3] = sar_f;

    bool use_2020_mtx = (csp == AVCOL_SPC_BT2020_NCL || csp == AVCOL_SPC_BT2020_CL ||
                         (csp == AVCOL_SPC_UNSPECIFIED && u->primaries == 1));
    bool use_601_mtx = (csp == AVCOL_SPC_BT470BG || csp == AVCOL_SPC_SMPTE170M ||
                        (csp == AVCOL_SPC_UNSPECIFIED && u->primaries == 0 && frame->height > 0 && frame->height <= 576));

    if (use_2020_mtx) {
        u->yuv_matrix_r0[0] = sy; u->yuv_matrix_r0[1] = 0.0f;              u->yuv_matrix_r0[2] = 1.4746f * sc;
        u->yuv_matrix_r1[0] = sy; u->yuv_matrix_r1[1] = -0.16455313f * sc; u->yuv_matrix_r1[2] = -0.57135313f * sc;
        u->yuv_matrix_r2[0] = sy; u->yuv_matrix_r2[1] = 1.8814f * sc;      u->yuv_matrix_r2[2] = 0.0f;
    } else if (use_601_mtx) {
        u->yuv_matrix_r0[0] = sy; u->yuv_matrix_r0[1] = 0.0f;              u->yuv_matrix_r0[2] = 1.402f * sc;
        u->yuv_matrix_r1[0] = sy; u->yuv_matrix_r1[1] = -0.34413629f * sc; u->yuv_matrix_r1[2] = -0.71413629f * sc;
        u->yuv_matrix_r2[0] = sy; u->yuv_matrix_r2[1] = 1.772f * sc;       u->yuv_matrix_r2[2] = 0.0f;
    } else {
        u->yuv_matrix_r0[0] = sy; u->yuv_matrix_r0[1] = 0.0f;              u->yuv_matrix_r0[2] = 1.5748f * sc;
        u->yuv_matrix_r1[0] = sy; u->yuv_matrix_r1[1] = -0.18732427f * sc; u->yuv_matrix_r1[2] = -0.46812427f * sc;
        u->yuv_matrix_r2[0] = sy; u->yuv_matrix_r2[1] = 1.8556f * sc;      u->yuv_matrix_r2[2] = 0.0f;
    }

    const AVFrameSideData* mdm_sd = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    if (mdm_sd && mdm_sd->data) {
        const AVMasteringDisplayMetadata* mdm = (const AVMasteringDisplayMetadata*)mdm_sd->data;
        if (mdm->has_luminance) {
            double max_l = av_q2d(mdm->max_luminance);
            if (max_l >= 100.0 && max_l <= 10000.0) u->source_peak_nits = (float)max_l;
        }
    }
    const AVFrameSideData* cll_sd = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
    if (cll_sd && cll_sd->data) {
        const AVContentLightMetadata* cll = (const AVContentLightMetadata*)cll_sd->data;
        if (cll->MaxCLL >= 150 && cll->MaxCLL <= 10000) u->source_peak_nits = (float)cll->MaxCLL;
    }

    const AVFrameSideData* dovi_sd = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
    if (dovi_sd && dovi_sd->data) {
        const AVDOVIMetadata* dovi = (const AVDOVIMetadata*)dovi_sd->data;
        const AVDOVIRpuDataHeader* hdr = av_dovi_get_header(dovi);
        const AVDOVIDataMapping* mapping = av_dovi_get_mapping(dovi);
        const AVDOVIColorMetadata* color = av_dovi_get_color(dovi);

        if (out_is_dovi) *out_is_dovi = true;
        if (out_is_hdr) *out_is_hdr = true;
        if (out_cs_label) {
            snprintf(out_cs_label, 32, stream_dovi_profile == 5 ? "Dolby Vision P5" : "Dolby Vision P8");
        }

        if (color) {
            double m00 = av_q2d(color->ycc_to_rgb_matrix[0]);
            if (fabs(m00) > 0.01 && (stream_dovi_profile == 5 || u->transfer_fn == 1)) {
                u->use_dovi_chain = 1;
                u->transfer_fn = 1;
                u->primaries = 1;

                u->ycc_offset[0] = (float)av_q2d(color->ycc_to_rgb_offset[0]);
                u->ycc_offset[1] = (float)av_q2d(color->ycc_to_rgb_offset[1]);
                u->ycc_offset[2] = (float)av_q2d(color->ycc_to_rgb_offset[2]);
                u->ycc_offset[3] = sar_f;

                u->yuv_matrix_r0[0] = (float)av_q2d(color->ycc_to_rgb_matrix[0]);
                u->yuv_matrix_r0[1] = (float)av_q2d(color->ycc_to_rgb_matrix[1]);
                u->yuv_matrix_r0[2] = (float)av_q2d(color->ycc_to_rgb_matrix[2]);
                u->yuv_matrix_r1[0] = (float)av_q2d(color->ycc_to_rgb_matrix[3]);
                u->yuv_matrix_r1[1] = (float)av_q2d(color->ycc_to_rgb_matrix[4]);
                u->yuv_matrix_r1[2] = (float)av_q2d(color->ycc_to_rgb_matrix[5]);
                u->yuv_matrix_r2[0] = (float)av_q2d(color->ycc_to_rgb_matrix[6]);
                u->yuv_matrix_r2[1] = (float)av_q2d(color->ycc_to_rgb_matrix[7]);
                u->yuv_matrix_r2[2] = (float)av_q2d(color->ycc_to_rgb_matrix[8]);

                const double hpe_lms2rgb[3][3] = {
                    {  3.06441879, -2.16597676,  0.10155818 },
                    { -0.65612108,  1.78554118, -0.12943749 },
                    {  0.01736321, -0.04725154,  1.03004253 }
                };
                double r2l[3][3];
                for (int r = 0; r < 3; r++) {
                    for (int c = 0; c < 3; c++) {
                        r2l[r][c] = av_q2d(color->rgb_to_lms_matrix[r * 3 + c]);
                    }
                }
                for (int c = 0; c < 3; c++) {
                    u->lin_matrix_r0[c] = (float)(hpe_lms2rgb[0][0] * r2l[0][c] + hpe_lms2rgb[0][1] * r2l[1][c] + hpe_lms2rgb[0][2] * r2l[2][c]);
                    u->lin_matrix_r1[c] = (float)(hpe_lms2rgb[1][0] * r2l[0][c] + hpe_lms2rgb[1][1] * r2l[1][c] + hpe_lms2rgb[1][2] * r2l[2][c]);
                    u->lin_matrix_r2[c] = (float)(hpe_lms2rgb[2][0] * r2l[0][c] + hpe_lms2rgb[2][1] * r2l[1][c] + hpe_lms2rgb[2][2] * r2l[2][c]);
                }
            }

            if (color->source_max_pq > 0) {
                float src_nits = dk_shim_pq_norm_to_nits((double)color->source_max_pq / 4095.0);
                if (src_nits >= 150.0f && src_nits <= 10000.0f) {
                    if (u->source_peak_nits >= 999.0f || src_nits < u->source_peak_nits) {
                        u->source_peak_nits = src_nits;
                    }
                }
            }
        }

        const AVDOVIDmData* l6 = av_dovi_find_level(dovi, 6);
        if (l6) {
            if (l6->l6.max_cll >= 150 && l6->l6.max_cll <= 10000) {
                u->source_peak_nits = (float)l6->l6.max_cll;
            } else if (l6->l6.max_luminance >= 150 && l6->l6.max_luminance <= 10000 && u->source_peak_nits >= 999.0f) {
                u->source_peak_nits = (float)l6->l6.max_luminance;
            }
        }

        if (hdr && mapping && hdr->coef_log2_denom > 0 && hdr->coef_log2_denom <= 31) {
            const double denom = (double)(1ULL << hdr->coef_log2_denom);
            const int bl_bits = (hdr->bl_bit_depth >= 8 && hdr->bl_bit_depth <= 16) ? hdr->bl_bit_depth : 10;
            const double pivot_norm = (double)(1 << bl_bits);
            bool any_non_identity = false;

            for (int ch = 0; ch < 3; ch++) {
                const AVDOVIReshapingCurve* curve = &mapping->curves[ch];
                int npiv = curve->num_pivots > 9 ? 9 : curve->num_pivots;
                int npieces = npiv > 1 ? (npiv - 1) : 0;
                u->reshape_pieces[ch] = npieces;
                for (int p = 0; p < npiv; p++) {
                    float pv = (float)((double)curve->pivots[p] / pivot_norm);
                    if (p == npiv - 1 && pv > 0.998f) pv = 1.0f;
                    u->reshape_pivots[ch * 12 + p] = pv;
                }
                for (int pc = 0; pc < npieces && pc < 8; pc++) {
                    float c0 = 0.0f, c1 = 1.0f, c2 = 0.0f;
                    int piece_idx = ch * 8 + pc;
                    if (curve->mapping_idc[pc] == AV_DOVI_MAPPING_POLYNOMIAL) {
                        u->reshape_mmr_meta[piece_idx] = 0;
                        c0 = (float)((double)curve->poly_coef[pc][0] / denom);
                        c1 = (curve->poly_order[pc] >= 1) ? (float)((double)curve->poly_coef[pc][1] / denom) : 0.0f;
                        c2 = (curve->poly_order[pc] >= 2) ? (float)((double)curve->poly_coef[pc][2] / denom) : 0.0f;
                        if (fabsf(c0) > 1e-4f || fabsf(c1 - 1.0f) > 1e-4f || fabsf(c2) > 1e-4f) {
                            any_non_identity = true;
                        }
                    } else if (curve->mapping_idc[pc] == AV_DOVI_MAPPING_MMR) {
                        int order = curve->mmr_order[pc] < 1 ? 1 : (curve->mmr_order[pc] > 3 ? 3 : curve->mmr_order[pc]);
                        u->reshape_mmr_meta[piece_idx] = order;
                        int mbase = piece_idx * 24;
                        u->reshape_mmr_coeffs[mbase + 0] = (float)((double)curve->mmr_constant[pc] / denom);
                        for (int ord = 0; ord < order; ord++) {
                            for (int t = 0; t < 7; t++) {
                                u->reshape_mmr_coeffs[mbase + 1 + ord * 7 + t] =
                                    (float)((double)curve->mmr_coef[pc][ord][t] / denom);
                            }
                        }
                        any_non_identity = true;
                    }
                    int base = piece_idx * 4;
                    u->reshape_coeffs[base + 0] = c0;
                    u->reshape_coeffs[base + 1] = c1;
                    u->reshape_coeffs[base + 2] = c2;
                    u->reshape_coeffs[base + 3] = 0.0f;
                }
            }
            u->has_dovi_reshape = any_non_identity ? 1 : 0;
        }
    } else if (stream_dovi_profile == 5 && u->use_dovi_chain == 0) {
        u->use_dovi_chain = 1;
        u->transfer_fn = 1;
        u->primaries = 1;
        u->ycc_offset[0] = 0.0f; u->ycc_offset[1] = 0.5f; u->ycc_offset[2] = 0.5f; u->ycc_offset[3] = sar_f;
        u->yuv_matrix_r0[0] = 1.0f; u->yuv_matrix_r0[1] =  0.0975689f; u->yuv_matrix_r0[2] =  0.2052264f;
        u->yuv_matrix_r1[0] = 1.0f; u->yuv_matrix_r1[1] = -0.1138765f; u->yuv_matrix_r1[2] =  0.1332172f;
        u->yuv_matrix_r2[0] = 1.0f; u->yuv_matrix_r2[1] =  0.0326151f; u->yuv_matrix_r2[2] = -0.6768872f;
        u->lin_matrix_r0[0] =  3.0644188f; u->lin_matrix_r0[1] = -2.1659768f; u->lin_matrix_r0[2] =  0.1015582f;
        u->lin_matrix_r1[0] = -0.6561211f; u->lin_matrix_r1[1] =  1.7855412f; u->lin_matrix_r1[2] = -0.1294375f;
        u->lin_matrix_r2[0] =  0.0173632f; u->lin_matrix_r2[1] = -0.0472515f; u->lin_matrix_r2[2] =  1.0300425f;
    }
}

CVPixelBufferRef dk_shim_process_video_frame(
    const void* frame_raw, const void* fmt_raw, int32_t video_stream_idx,
    uint8_t stream_dovi_profile, double fallback_fps, double prev_pts,
    double drop_until_pts, bool* out_dropped, double* out_pts,
    void** inout_sws, void** inout_pool, int32_t* inout_pool_w,
    int32_t* inout_pool_h, uint32_t* inout_pool_fmt,
    DKGpuColorUniforms* out_color, bool* out_is_hw, bool* out_is_hdr,
    bool* out_is_dovi, char out_cs_label[32]
) {
    const AVFrame* frame = (const AVFrame*)frame_raw;
    const AVFormatContext* fmt = (const AVFormatContext*)fmt_raw;
    if (out_dropped) *out_dropped = false;
    if (!frame) return NULL;

    double pts = -1.0;
    if (fmt && video_stream_idx >= 0 && (unsigned)video_stream_idx < fmt->nb_streams) {
        double tb = av_q2d(fmt->streams[video_stream_idx]->time_base);
        if (frame->best_effort_timestamp != AV_NOPTS_VALUE) {
            pts = (double)frame->best_effort_timestamp * tb;
        } else if (frame->pts != AV_NOPTS_VALUE) {
            pts = (double)frame->pts * tb;
        }
    }
    if (pts < 0.0) {
        double safe_fps = fallback_fps > 1.0 ? fallback_fps : 24.0;
        pts = (prev_pts >= 0.0) ? (prev_pts + 1.0 / safe_fps) : 0.0;
    }
    if (out_pts) *out_pts = pts;

    if (drop_until_pts > 0.0 && pts < drop_until_pts - 0.04) {
        if (out_dropped) *out_dropped = true;
        return NULL;
    }

    bool is_hw = (frame->format == AV_PIX_FMT_VIDEOTOOLBOX);
    if (out_is_hw) *out_is_hw = is_hw;

    CVPixelBufferRef pixbuf = NULL;
    if (is_hw) {
        pixbuf = (CVPixelBufferRef)frame->data[3];
        if (pixbuf) CVPixelBufferRetain(pixbuf);
    } else {
        int width = frame->width;
        int height = frame->height;
        if (width <= 0 || height <= 0) return NULL;

        const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get((enum AVPixelFormat)frame->format);
        bool is_high_depth = (desc && desc->comp[0].depth > 8);
        enum AVPixelFormat dst_av_fmt = is_high_depth ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
        OSType dst_cv_fmt = is_high_depth
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

        struct SwsContext* sws = (struct SwsContext*)(*inout_sws);
        sws = sws_getCachedContext(
            sws, width, height, (enum AVPixelFormat)frame->format,
            width, height, dst_av_fmt, SWS_BILINEAR, NULL, NULL, NULL
        );
        *inout_sws = sws;
        if (!sws) return NULL;

        CVPixelBufferPoolRef pool = (CVPixelBufferPoolRef)(*inout_pool);
        if (!dk_shim_ensure_sw_pool(&pool, inout_pool_w, inout_pool_h, inout_pool_fmt, width, height, dst_cv_fmt)) {
            *inout_pool = pool;
            return NULL;
        }
        *inout_pool = pool;

        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixbuf) != kCVReturnSuccess || !pixbuf) {
            return NULL;
        }

        CVPixelBufferLockBaseAddress(pixbuf, 0);
        uint8_t* dst_data[4] = {
            (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixbuf, 0),
            (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixbuf, 1),
            NULL, NULL
        };
        int dst_linesize[4] = {
            (int)CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 0),
            (int)CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 1),
            0, 0
        };
        sws_scale(sws, (const uint8_t* const*)frame->data, frame->linesize, 0, height, dst_data, dst_linesize);
        CVPixelBufferUnlockBaseAddress(pixbuf, 0);
    }

    if (pixbuf && out_color) {
        dk_shim_build_color_uniforms(
            frame, fmt, video_stream_idx, stream_dovi_profile, pixbuf,
            out_color, out_is_hdr, out_is_dovi, out_cs_label
        );
    }
    return pixbuf;
}

void dk_shim_release_sw_video_res(void** sws, void** pool) {
    if (sws && *sws) {
        sws_freeContext((struct SwsContext*)(*sws));
        *sws = NULL;
    }
    if (pool && *pool) {
        CVPixelBufferPoolRelease((CVPixelBufferPoolRef)(*pool));
        *pool = NULL;
    }
}

void dk_shim_retain_pixbuf(CVPixelBufferRef pb) {
    if (pb) CVPixelBufferRetain(pb);
}

void dk_shim_release_pixbuf(CVPixelBufferRef pb) {
    if (pb) CVPixelBufferRelease(pb);
}

CGImageRef dk_shim_extract_thumbnail(const char* path, double target_sec) {
    if (!path || !path[0]) return NULL;

    AVFormatContext* fmt_ctx = NULL;
    AVDictionary* opts = NULL;
    av_dict_set(&opts, "scan_all_pmts", "1", 0);
    if (avformat_open_input(&fmt_ctx, path, NULL, &opts) < 0) {
        if (opts) av_dict_free(&opts);
        return NULL;
    }
    if (opts) av_dict_free(&opts);

    if (avformat_find_stream_info(fmt_ctx, NULL) < 0) {
        avformat_close_input(&fmt_ctx);
        return NULL;
    }

    int video_stream_idx = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (video_stream_idx < 0) {
        avformat_close_input(&fmt_ctx);
        return NULL;
    }

    AVStream* st = fmt_ctx->streams[video_stream_idx];
    const AVCodec* decoder = avcodec_find_decoder(st->codecpar->codec_id);
    if (!decoder) {
        avformat_close_input(&fmt_ctx);
        return NULL;
    }

    AVCodecContext* codec_ctx = avcodec_alloc_context3(decoder);
    if (!codec_ctx) {
        avformat_close_input(&fmt_ctx);
        return NULL;
    }
    if (avcodec_parameters_to_context(codec_ctx, st->codecpar) < 0) {
        avcodec_free_context(&codec_ctx);
        avformat_close_input(&fmt_ctx);
        return NULL;
    }
    codec_ctx->thread_count = 2;
    if (avcodec_open2(codec_ctx, decoder, NULL) < 0) {
        avcodec_free_context(&codec_ctx);
        avformat_close_input(&fmt_ctx);
        return NULL;
    }

    if (target_sec > 0.05) {
        int64_t ts = (int64_t)(target_sec * (double)AV_TIME_BASE);
        av_seek_frame(fmt_ctx, -1, ts, AVSEEK_FLAG_BACKWARD);
        avcodec_flush_buffers(codec_ctx);
    }

    AVPacket* pkt = av_packet_alloc();
    AVFrame* frame = av_frame_alloc();
    bool got_frame = false;

    int max_total_pkts = 1500;
    int max_video_pkts = 120;
    while (max_total_pkts-- > 0 && max_video_pkts > 0 && av_read_frame(fmt_ctx, pkt) >= 0) {
        if (pkt->stream_index == video_stream_idx) {
            max_video_pkts--;
            if (avcodec_send_packet(codec_ctx, pkt) == 0) {
                if (avcodec_receive_frame(codec_ctx, frame) == 0) {
                    got_frame = true;
                    av_packet_unref(pkt);
                    break;
                }
            }
        }
        av_packet_unref(pkt);
    }
    if (!got_frame) {
        avcodec_send_packet(codec_ctx, NULL);
        if (avcodec_receive_frame(codec_ctx, frame) == 0) {
            got_frame = true;
        }
    }

    CGImageRef result_cg = NULL;
    if (got_frame && frame->width > 0 && frame->height > 0) {
        int src_w = frame->width;
        int src_h = frame->height;
        int dst_w = src_w;
        int dst_h = src_h;
        if (dst_w > 640) {
            dst_h = (dst_h * 640) / dst_w;
            dst_w = 640;
        }
        dst_w = (dst_w / 2) * 2;
        dst_h = (dst_h / 2) * 2;
        if (dst_w < 16) dst_w = 16;
        if (dst_h < 16) dst_h = 16;

        struct SwsContext* sws = sws_getContext(
            src_w, src_h, (enum AVPixelFormat)frame->format,
            dst_w, dst_h, AV_PIX_FMT_RGBA,
            SWS_FAST_BILINEAR, NULL, NULL, NULL
        );
        if (sws) {
            size_t byte_len = (size_t)dst_w * (size_t)dst_h * 4;
            uint8_t* rgba_data = (uint8_t*)malloc(byte_len);
            if (rgba_data) {
                uint8_t* dst_data[4] = { rgba_data, NULL, NULL, NULL };
                int dst_linesize[4] = { dst_w * 4, 0, 0, 0 };
                sws_scale(sws, (const uint8_t* const*)frame->data, frame->linesize, 0, src_h, dst_data, dst_linesize);

                CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CFDataRef cf_data = CFDataCreate(kCFAllocatorDefault, rgba_data, (CFIndex)byte_len);
                CGDataProviderRef provider = CGDataProviderCreateWithCFData(cf_data);

                result_cg = CGImageCreate(
                    (size_t)dst_w, (size_t)dst_h, 8, 32, (size_t)(dst_w * 4), cs,
                    (CGBitmapInfo)kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault,
                    provider, NULL, true, kCGRenderingIntentDefault
                );

                CGDataProviderRelease(provider);
                CFRelease(cf_data);
                CGColorSpaceRelease(cs);
                free(rgba_data);
            }
            sws_freeContext(sws);
        }
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&codec_ctx);
    avformat_close_input(&fmt_ctx);
    return result_cg;
}
