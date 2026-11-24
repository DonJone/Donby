#include "donby_kernel.h"

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/hwcontext.h>
#include <libavutil/log.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#include <ass/ass.h>

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>

// Lock C header layout to KernelRust/src/abi.rs at compile time.
_Static_assert(sizeof(DKPlayerState) == 4, "DKPlayerState size drift");
_Static_assert(sizeof(DKRuntimeStats) == 160, "DKRuntimeStats size drift");
_Static_assert(sizeof(DKTrackInfo) == 204, "DKTrackInfo size drift");
_Static_assert(sizeof(DKChapterInfo) == 152, "DKChapterInfo size drift");
_Static_assert(sizeof(DKSubtitleInterval) == 16, "DKSubtitleInterval size drift");
_Static_assert(sizeof(DKSubtitleStyleConfig) == 64, "DKSubtitleStyleConfig size drift");
_Static_assert(sizeof(DKGpuColorUniforms) == 3088, "DKGpuColorUniforms size drift");

typedef struct {
    int32_t codec_type; // 0 = video, 1 = audio, 2 = subtitle, -1 = other
    int32_t codec_id;
    bool is_ass_or_ssa;
    bool is_subrip_or_text;
    bool is_pgs_or_dvd;
    bool disp_default;
    bool disp_forced;
    bool disp_attached_pic;
    int32_t width;
    int32_t height;
    int32_t bit_depth;
    int32_t channels;
    int32_t sample_rate;
    int32_t color_trc;
    int32_t color_primaries;
    uint8_t dovi_profile;
    uint8_t dovi_level;
    uint8_t dovi_compat;
    uint8_t _pad;
    double fps;
    double time_base_sec;
    int64_t bit_rate;
    char codec_name[32];
    char language[32];
    char title[128];
    const uint8_t* extradata;
    int32_t extradata_size;
} DKShimStreamMeta;

extern void dk_rust_forward_ffmpeg_log(int level, const char* message);

// -----------------------------------------------------------------------------
// 1. FFmpeg Logging & Error Codes
// -----------------------------------------------------------------------------

static void dk_shim_ffmpeg_log_cb(void* ptr, int level, const char* fmt, va_list vl) {
    (void)ptr;
    if (level > AV_LOG_WARNING || !fmt) {
        return;
    }
    char line[1024];
    int n = vsnprintf(line, sizeof(line), fmt, vl);
    if (n <= 0) {
        return;
    }
    size_t len = strlen(line);
    while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
        line[--len] = '\0';
    }
    if (len == 0) {
        return;
    }
    int mapped = (level <= AV_LOG_ERROR) ? 2 : 1;
    dk_rust_forward_ffmpeg_log(mapped, line);
}

void dk_shim_install_ffmpeg_log_bridge(void) {
    av_log_set_level(AV_LOG_WARNING);
    av_log_set_callback(dk_shim_ffmpeg_log_cb);
}

int dk_shim_averror_eof(void) { return AVERROR_EOF; }
int dk_shim_averror_exit(void) { return AVERROR_EXIT; }
int dk_shim_averror_eio(void) { return AVERROR(EIO); }
int dk_shim_averror_enosys(void) { return AVERROR(ENOSYS); }
bool dk_shim_is_eof(int err) { return err == AVERROR_EOF; }
bool dk_shim_is_eagain(int err) { return err == AVERROR(EAGAIN); }

void dk_shim_strerror(int err, char* buf, size_t cap) {
    if (!buf || cap == 0) return;
    buf[0] = '\0';
    av_strerror(err, buf, cap);
}

// -----------------------------------------------------------------------------
// 2. Packet & Frame Lifecycle
// -----------------------------------------------------------------------------

void* dk_shim_pkt_alloc(void) { return av_packet_alloc(); }

void dk_shim_pkt_free(void** pkt) {
    if (pkt && *pkt) {
        AVPacket* p = (AVPacket*)(*pkt);
        av_packet_free(&p);
        *pkt = NULL;
    }
}

void* dk_shim_pkt_clone(const void* pkt) {
    return pkt ? av_packet_clone((const AVPacket*)pkt) : NULL;
}

void dk_shim_pkt_unref(void* pkt) {
    if (pkt) av_packet_unref((AVPacket*)pkt);
}

void* dk_shim_pkt_move_alloc(void* src_pkt) {
    if (!src_pkt) return NULL;
    AVPacket* dst = av_packet_alloc();
    if (!dst) return NULL;
    av_packet_move_ref(dst, (AVPacket*)src_pkt);
    return dst;
}

int32_t dk_shim_pkt_stream_index(const void* pkt) {
    return pkt ? ((const AVPacket*)pkt)->stream_index : -1;
}

int32_t dk_shim_pkt_size(const void* pkt) {
    return pkt ? ((const AVPacket*)pkt)->size : 0;
}

void* dk_shim_frame_alloc(void) { return av_frame_alloc(); }

void dk_shim_frame_free(void** frame) {
    if (frame && *frame) {
        AVFrame* f = (AVFrame*)(*frame);
        av_frame_free(&f);
        *frame = NULL;
    }
}

void dk_shim_frame_unref(void* frame) {
    if (frame) av_frame_unref((AVFrame*)frame);
}

// -----------------------------------------------------------------------------
// 3. Format Open, PGS Fast-Probe Bypass, Custom AVIO, Stream & Chapter Accessors
// -----------------------------------------------------------------------------

int dk_shim_open_format(
    const char* url,
    const char* headers_crlf,
    bool is_local_file,
    bool has_start_seek,
    bool is_mpeg_ts,
    bool use_custom_io,
    bool has_seek_cb,
    void* opaque,
    int (*interrupt_cb)(void*),
    int (*read_cb)(void*, uint8_t*, int),
    int64_t (*seek_cb)(void*, int64_t, int),
    void** out_fmt,
    void** out_avio
) {
    if (!out_fmt || !out_avio) return -1;
    *out_fmt = NULL;
    *out_avio = NULL;

    AVFormatContext* fmt = avformat_alloc_context();
    if (!fmt) return AVERROR(ENOMEM);

    fmt->interrupt_callback.callback = interrupt_cb;
    fmt->interrupt_callback.opaque = opaque;

    AVIOContext* custom_avio = NULL;
    if (use_custom_io && read_cb) {
        const int kAvioBufSize = 256 * 1024;
        uint8_t* avio_buf = (uint8_t*)av_malloc((size_t)kAvioBufSize);
        if (avio_buf) {
            custom_avio = avio_alloc_context(
                avio_buf,
                kAvioBufSize,
                0,
                opaque,
                read_cb,
                NULL,
                has_seek_cb ? seek_cb : NULL
            );
            if (custom_avio) {
                fmt->pb = custom_avio;
                fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
            } else {
                av_free(avio_buf);
            }
        }
    }

    AVDictionary* opts = NULL;
    const char* probe_bytes = is_mpeg_ts ? "4194304" : "1048576";
    const char* analyze_us = is_mpeg_ts ? "2000000" : (has_start_seek ? "500000" : "600000");

    if (is_local_file || (use_custom_io && custom_avio)) {
        av_dict_set(&opts, "probesize", probe_bytes, 0);
        av_dict_set(&opts, "analyzeduration", analyze_us, 0);
        av_dict_set(&opts, "fpsprobesize", "4", 0);
        av_dict_set(&opts, "buffer_size", "2097152", 0);
    } else {
        av_dict_set(&opts, "reconnect", "1", 0);
        av_dict_set(&opts, "reconnect_streamed", "1", 0);
        av_dict_set(&opts, "reconnect_at_eof", "0", 0);
        av_dict_set(&opts, "reconnect_on_network_error", "1", 0);
        av_dict_set(&opts, "reconnect_delay_max", "3", 0);
        av_dict_set(&opts, "multiple_requests", "1", 0);
        av_dict_set(&opts, "rw_timeout", "10000000", 0);
        av_dict_set(&opts, "timeout", "10000000", 0);
        av_dict_set(&opts, "probesize", probe_bytes, 0);
        av_dict_set(&opts, "analyzeduration", analyze_us, 0);
        av_dict_set(&opts, "fpsprobesize", "4", 0);
        av_dict_set(&opts, "tcp_nodelay", "1", 0);
        av_dict_set(&opts, "buffer_size", "2097152", 0);
        if (headers_crlf && headers_crlf[0] != '\0') {
            av_dict_set(&opts, "headers", headers_crlf, 0);
        }
    }

    int open_ret = avformat_open_input(
        &fmt,
        (use_custom_io && custom_avio) ? NULL : url,
        NULL,
        &opts
    );
    av_dict_free(&opts);

    if (open_ret < 0 || (interrupt_cb && interrupt_cb(opaque) != 0)) {
        if (open_ret >= 0 && fmt) {
            if (custom_avio) fmt->pb = NULL;
            avformat_close_input(&fmt);
        } else if (fmt) {
            fmt->pb = NULL;
            avformat_free_context(fmt);
            fmt = NULL;
        }
        if (custom_avio) {
            av_freep(&custom_avio->buffer);
            avio_context_free(&custom_avio);
        }
        return (open_ret < 0) ? open_ret : AVERROR_EXIT;
    }

    fmt->fps_probe_size = 4;
    fmt->max_probe_packets = 200;

    unsigned int nb = fmt->nb_streams;
    enum AVDiscard* saved_discard = nb > 0 ? (enum AVDiscard*)calloc(nb, sizeof(enum AVDiscard)) : NULL;
    bool* seeded_dims = nb > 0 ? (bool*)calloc(nb, sizeof(bool)) : NULL;

    for (unsigned int i = 0; i < nb; i++) {
        AVStream* st = fmt->streams[i];
        if (!st || !st->codecpar) continue;
        if (st->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT ||
            st->codecpar->codec_type == AVMEDIA_TYPE_DATA) {
            st->discard = AVDISCARD_ALL;
        } else if (st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            if (saved_discard) saved_discard[i] = st->discard;
            st->discard = AVDISCARD_ALL;
            if ((st->codecpar->codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE ||
                 st->codecpar->codec_id == AV_CODEC_ID_DVD_SUBTITLE) &&
                (st->codecpar->width == 0 || st->codecpar->height == 0)) {
                st->codecpar->width = 1920;
                st->codecpar->height = 1080;
                if (seeded_dims) seeded_dims[i] = true;
            }
        }
    }

    int find_ret = avformat_find_stream_info(fmt, NULL);

    for (unsigned int i = 0; i < fmt->nb_streams && i < nb; i++) {
        AVStream* st = fmt->streams[i];
        if (st && st->codecpar && st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            if (saved_discard) st->discard = saved_discard[i];
            if (seeded_dims && seeded_dims[i]) {
                st->codecpar->width = 0;
                st->codecpar->height = 0;
            }
        }
    }
    free(saved_discard);
    free(seeded_dims);

    if (find_ret < 0 || (interrupt_cb && interrupt_cb(opaque) != 0)) {
        if (custom_avio) fmt->pb = NULL;
        avformat_close_input(&fmt);
        if (custom_avio) {
            av_freep(&custom_avio->buffer);
            avio_context_free(&custom_avio);
        }
        return (find_ret < 0) ? find_ret : AVERROR_EXIT;
    }

    *out_fmt = fmt;
    *out_avio = custom_avio;
    return 0;
}

void dk_shim_close_format(void** fmt_ptr, void** custom_avio_ptr) {
    AVFormatContext* fmt = fmt_ptr ? (AVFormatContext*)(*fmt_ptr) : NULL;
    AVIOContext* custom_avio = custom_avio_ptr ? (AVIOContext*)(*custom_avio_ptr) : NULL;
    if (fmt) {
        if (custom_avio) {
            fmt->pb = NULL;
        }
        avformat_close_input(&fmt);
        *fmt_ptr = NULL;
    }
    if (custom_avio) {
        av_freep(&custom_avio->buffer);
        avio_context_free(&custom_avio);
        *custom_avio_ptr = NULL;
    }
}

void dk_shim_format_summary(
    const void* fmt_raw,
    uint32_t* out_nb_streams,
    uint32_t* out_nb_chapters,
    double* out_duration_sec,
    int64_t* out_bit_rate
) {
    const AVFormatContext* fmt = (const AVFormatContext*)fmt_raw;
    if (!fmt) {
        if (out_nb_streams) *out_nb_streams = 0;
        if (out_nb_chapters) *out_nb_chapters = 0;
        if (out_duration_sec) *out_duration_sec = 0.0;
        if (out_bit_rate) *out_bit_rate = 0;
        return;
    }
    if (out_nb_streams) *out_nb_streams = fmt->nb_streams;
    if (out_nb_chapters) *out_nb_chapters = fmt->nb_chapters;
    if (out_duration_sec) {
        *out_duration_sec = (fmt->duration > 0) ? ((double)fmt->duration / (double)AV_TIME_BASE) : 0.0;
    }
    if (out_bit_rate) *out_bit_rate = fmt->bit_rate;
}

bool dk_shim_get_stream_meta(const void* fmt_raw, uint32_t idx, DKShimStreamMeta* out) {
    const AVFormatContext* fmt = (const AVFormatContext*)fmt_raw;
    if (!fmt || !out || idx >= fmt->nb_streams) return false;
    memset(out, 0, sizeof(*out));
    const AVStream* st = fmt->streams[idx];
    if (!st || !st->codecpar) return false;

    const AVCodecParameters* cp = st->codecpar;
    if (cp->codec_type == AVMEDIA_TYPE_VIDEO) out->codec_type = 0;
    else if (cp->codec_type == AVMEDIA_TYPE_AUDIO) out->codec_type = 1;
    else if (cp->codec_type == AVMEDIA_TYPE_SUBTITLE) out->codec_type = 2;
    else out->codec_type = -1;

    out->codec_id = (int32_t)cp->codec_id;
    out->is_ass_or_ssa = (cp->codec_id == AV_CODEC_ID_ASS || cp->codec_id == AV_CODEC_ID_SSA);
    out->is_subrip_or_text = (cp->codec_id == AV_CODEC_ID_SUBRIP || cp->codec_id == AV_CODEC_ID_SRT || cp->codec_id == AV_CODEC_ID_TEXT);
    out->is_pgs_or_dvd = (cp->codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE || cp->codec_id == AV_CODEC_ID_DVD_SUBTITLE);

    out->disp_default = (st->disposition & AV_DISPOSITION_DEFAULT) != 0;
    out->disp_forced = (st->disposition & AV_DISPOSITION_FORCED) != 0;
    out->disp_attached_pic = (st->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0;

    out->width = cp->width;
    out->height = cp->height;
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get((enum AVPixelFormat)cp->format);
    out->bit_depth = (desc && desc->comp[0].depth > 0) ? desc->comp[0].depth : 8;
    out->channels = cp->ch_layout.nb_channels;
    out->sample_rate = cp->sample_rate;
    out->color_trc = (int32_t)cp->color_trc;
    out->color_primaries = (int32_t)cp->color_primaries;

    double fps = av_q2d(st->avg_frame_rate);
    if (fps <= 0.0 || !isfinite(fps)) {
        fps = av_q2d(st->r_frame_rate);
    }
    out->fps = (fps > 0.0 && isfinite(fps)) ? fps : 0.0;
    out->time_base_sec = av_q2d(st->time_base);
    out->bit_rate = cp->bit_rate;

    for (int sd_i = 0; sd_i < cp->nb_coded_side_data; sd_i++) {
        const AVPacketSideData* sd = &cp->coded_side_data[sd_i];
        if (sd->type == AV_PKT_DATA_DOVI_CONF && sd->data && sd->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
            const AVDOVIDecoderConfigurationRecord* dc = (const AVDOVIDecoderConfigurationRecord*)sd->data;
            out->dovi_profile = dc->dv_profile;
            out->dovi_level = dc->dv_level;
            out->dovi_compat = dc->dv_bl_signal_compatibility_id;
        }
    }

    const char* cname = avcodec_get_name(cp->codec_id);
    if (cname) snprintf(out->codec_name, sizeof(out->codec_name), "%s", cname);

    const AVDictionaryEntry* l = av_dict_get(st->metadata, "language", NULL, 0);
    if (l && l->value) snprintf(out->language, sizeof(out->language), "%s", l->value);

    const AVDictionaryEntry* t = av_dict_get(st->metadata, "title", NULL, 0);
    if (t && t->value) snprintf(out->title, sizeof(out->title), "%s", t->value);

    out->extradata = cp->extradata;
    out->extradata_size = cp->extradata_size;
    return true;
}

bool dk_shim_get_chapter_info(const void* fmt_raw, uint32_t idx, DKChapterInfo* out) {
    const AVFormatContext* fmt = (const AVFormatContext*)fmt_raw;
    if (!fmt || !out || idx >= fmt->nb_chapters) return false;
    memset(out, 0, sizeof(*out));
    const AVChapter* ch = fmt->chapters[idx];
    if (!ch) return false;
    out->index = (int32_t)idx;
    double tb = av_q2d(ch->time_base);
    out->start_sec = (ch->start != AV_NOPTS_VALUE) ? ((double)ch->start * tb) : 0.0;
    out->end_sec = (ch->end != AV_NOPTS_VALUE) ? ((double)ch->end * tb) : out->start_sec;
    const AVDictionaryEntry* t = av_dict_get(ch->metadata, "title", NULL, 0);
    if (t && t->value) snprintf(out->title, sizeof(out->title), "%s", t->value);
    return true;
}

void dk_shim_clear_avio_error(void* fmt_raw) {
    AVFormatContext* fmt = (AVFormatContext*)fmt_raw;
    if (fmt && fmt->pb) {
        fmt->pb->error = 0;
        fmt->pb->eof_reached = 0;
    }
}

int64_t dk_shim_avio_bytes_read(const void* fmt_raw) {
    const AVFormatContext* fmt = (const AVFormatContext*)fmt_raw;
    return (fmt && fmt->pb) ? fmt->pb->bytes_read : 0;
}

void dk_shim_avio_retry_reseek(void* fmt_raw) {
    AVFormatContext* fmt = (AVFormatContext*)fmt_raw;
    if (fmt && fmt->pb) {
        int64_t pos = avio_tell(fmt->pb);
        dk_shim_clear_avio_error(fmt);
        if (pos >= 0) {
            avio_seek(fmt->pb, pos, SEEK_SET);
            dk_shim_clear_avio_error(fmt);
        }
    }
}

int dk_shim_seek_format(void* fmt_raw, double target_sec, bool allow_fallback) {
    AVFormatContext* fmt = (AVFormatContext*)fmt_raw;
    if (!fmt) return -1;
    dk_shim_clear_avio_error(fmt);
    int64_t ts = (int64_t)(target_sec * (double)AV_TIME_BASE);
    int ret = avformat_seek_file(fmt, -1, INT64_MIN, ts, ts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0 && allow_fallback) {
        dk_shim_clear_avio_error(fmt);
        ret = av_seek_frame(fmt, -1, ts, AVSEEK_FLAG_BACKWARD);
    }
    dk_shim_clear_avio_error(fmt);
    return ret;
}

int dk_shim_read_frame(
    void* fmt_raw,
    void* pkt_raw,
    int32_t* out_stream_idx,
    int32_t* out_size,
    bool* out_corrupt,
    double* out_pkt_sec,
    bool* out_has_pts,
    const uint8_t** out_data
) {
    AVFormatContext* fmt = (AVFormatContext*)fmt_raw;
    AVPacket* pkt = (AVPacket*)pkt_raw;
    if (!fmt || !pkt) return -1;
    int ret = av_read_frame(fmt, pkt);
    if (ret < 0) return ret;

    if (out_stream_idx) *out_stream_idx = pkt->stream_index;
    if (out_size) *out_size = pkt->size;
    if (out_corrupt) *out_corrupt = (pkt->flags & AV_PKT_FLAG_CORRUPT) != 0;
    if (out_data) *out_data = pkt->data;

    int64_t raw_ts = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
    if (raw_ts != AV_NOPTS_VALUE && pkt->stream_index >= 0 && (unsigned)pkt->stream_index < fmt->nb_streams) {
        double sec = (double)raw_ts * av_q2d(fmt->streams[pkt->stream_index]->time_base);
        if (isfinite(sec)) {
            if (out_pkt_sec) *out_pkt_sec = sec;
            if (out_has_pts) *out_has_pts = true;
        } else {
            if (out_pkt_sec) *out_pkt_sec = 0.0;
            if (out_has_pts) *out_has_pts = false;
        }
    } else {
        if (out_pkt_sec) *out_pkt_sec = 0.0;
        if (out_has_pts) *out_has_pts = false;
    }
    return 0;
}

bool dk_shim_is_hevc_stream(const void* fmt_raw, int32_t stream_idx) {
    const AVFormatContext* fmt = (const AVFormatContext*)fmt_raw;
    if (!fmt || stream_idx < 0 || (unsigned)stream_idx >= fmt->nb_streams) return false;
    const AVStream* st = fmt->streams[stream_idx];
    return st && st->codecpar && st->codecpar->codec_id == AV_CODEC_ID_HEVC;
}

// -----------------------------------------------------------------------------
// 4. Video Decoder, Color/DoVi Uniform Builder & Thumbnail Extraction
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
    void* rust_opaque,
    bool (*is_vt_failed)(void*),
    void (*on_sw_format_selected)(void*)
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
    const void* fmt_raw,
    int32_t stream_idx,
    bool hw_decode,
    int32_t sw_threads,
    void* hw_fmt_ctx_opaque,
    void** out_codec_ctx,
    void** out_hw_ctx,
    bool* out_is_hw,
    char out_dec_name[32]
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

void dk_shim_close_codec(void** codec_ctx) {
    if (codec_ctx && *codec_ctx) {
        AVCodecContext* c = (AVCodecContext*)(*codec_ctx);
        avcodec_free_context(&c);
        *codec_ctx = NULL;
    }
}

void dk_shim_unref_hw_ctx(void** hw_ctx) {
    if (hw_ctx && *hw_ctx) {
        AVBufferRef* b = (AVBufferRef*)(*hw_ctx);
        av_buffer_unref(&b);
        *hw_ctx = NULL;
    }
}

int dk_shim_send_packet(void* codec_ctx, const void* pkt) {
    if (!codec_ctx) return -1;
    return avcodec_send_packet((AVCodecContext*)codec_ctx, (const AVPacket*)pkt);
}

int dk_shim_receive_frame(void* codec_ctx, void* frame) {
    if (!codec_ctx || !frame) return -1;
    return avcodec_receive_frame((AVCodecContext*)codec_ctx, (AVFrame*)frame);
}

void dk_shim_flush_codec(void* codec_ctx) {
    if (codec_ctx) avcodec_flush_buffers((AVCodecContext*)codec_ctx);
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
    CVPixelBufferPoolRef* inout_pool,
    int32_t* inout_w,
    int32_t* inout_h,
    uint32_t* inout_fmt,
    int width,
    int height,
    OSType pix_fmt
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
    const AVFrame* frame,
    const AVFormatContext* fmt,
    int32_t video_stream_idx,
    uint8_t stream_dovi_profile,
    CVPixelBufferRef pixbuf,
    DKGpuColorUniforms* u,
    bool* out_is_hdr,
    bool* out_is_dovi,
    char out_cs_label[32]
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
    const void* frame_raw,
    const void* fmt_raw,
    int32_t video_stream_idx,
    uint8_t stream_dovi_profile,
    double fallback_fps,
    double prev_pts,
    double drop_until_pts,
    bool* out_dropped,
    double* out_pts,
    void** inout_sws,
    void** inout_pool,
    int32_t* inout_pool_w,
    int32_t* inout_pool_h,
    uint32_t* inout_pool_fmt,
    DKGpuColorUniforms* out_color,
    bool* out_is_hw,
    bool* out_is_hdr,
    bool* out_is_dovi,
    char out_cs_label[32]
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

// -----------------------------------------------------------------------------
// 5. Audio Decoder, SwrContext Resampler, VAD Mono Tap & AudioQueue
// -----------------------------------------------------------------------------

static bool dk_shim_configure_swr(
    const AVCodecContext* codec_ctx,
    const AVChannelLayout* src_layout,
    enum AVSampleFormat src_fmt,
    int src_rate,
    struct SwrContext** inout_swr,
    int32_t* out_fmt,
    int32_t* out_rate,
    int32_t* out_ch
) {
    if (*inout_swr) {
        swr_free(inout_swr);
    }
    AVChannelLayout out_layout;
    av_channel_layout_default(&out_layout, 2);

    AVChannelLayout in_layout;
    memset(&in_layout, 0, sizeof(in_layout));
    if (src_layout && src_layout->nb_channels > 0) {
        av_channel_layout_copy(&in_layout, src_layout);
    } else if (codec_ctx && codec_ctx->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&in_layout, &codec_ctx->ch_layout);
    } else {
        av_channel_layout_default(&in_layout, 2);
    }

    int in_rate = src_rate > 0 ? src_rate : (codec_ctx && codec_ctx->sample_rate > 0 ? codec_ctx->sample_rate : 48000);
    enum AVSampleFormat in_fmt = src_fmt != AV_SAMPLE_FMT_NONE ? src_fmt :
        (codec_ctx && codec_ctx->sample_fmt != AV_SAMPLE_FMT_NONE ? codec_ctx->sample_fmt : AV_SAMPLE_FMT_FLTP);
    int in_channels = in_layout.nb_channels;

    struct SwrContext* swr = NULL;
    int ret = swr_alloc_set_opts2(
        &swr, &out_layout, AV_SAMPLE_FMT_FLT, 48000,
        &in_layout, in_fmt, in_rate, 0, NULL
    );
    av_channel_layout_uninit(&out_layout);
    av_channel_layout_uninit(&in_layout);

    if (ret < 0 || !swr) return false;
    if (in_channels > 2) {
        av_opt_set_double(swr, "clev", 0.78, 0);
        av_opt_set_double(swr, "slev", 0.707, 0);
        av_opt_set_double(swr, "lfe_mix_level", 0.20, 0);
    }
    if (swr_init(swr) < 0) {
        swr_free(&swr);
        return false;
    }
    *inout_swr = swr;
    if (out_fmt) *out_fmt = (int32_t)in_fmt;
    if (out_rate) *out_rate = in_rate;
    if (out_ch) *out_ch = in_channels;
    return true;
}

int dk_shim_open_audio_decoder(
    const void* fmt_raw,
    int32_t stream_idx,
    void** out_codec_ctx,
    void** out_swr,
    int32_t* out_swr_fmt,
    int32_t* out_swr_rate,
    int32_t* out_swr_ch,
    char out_dec_name[32]
) {
    const AVFormatContext* fmt = (const AVFormatContext*)fmt_raw;
    if (!fmt || !out_codec_ctx || !out_swr || stream_idx < 0 || (unsigned)stream_idx >= fmt->nb_streams) return -1;
    *out_codec_ctx = NULL;
    *out_swr = NULL;
    if (out_dec_name) out_dec_name[0] = '\0';

    const AVStream* st = fmt->streams[stream_idx];
    const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return AVERROR_DECODER_NOT_FOUND;

    AVCodecContext* ctx = avcodec_alloc_context3(dec);
    if (!ctx) return AVERROR(ENOMEM);
    avcodec_parameters_to_context(ctx, st->codecpar);
    ctx->pkt_timebase = st->time_base;
    int ret = avcodec_open2(ctx, dec, NULL);
    if (ret < 0) {
        avcodec_free_context(&ctx);
        return ret;
    }

    struct SwrContext* swr = NULL;
    dk_shim_configure_swr(ctx, &ctx->ch_layout, ctx->sample_fmt, ctx->sample_rate, &swr, out_swr_fmt, out_swr_rate, out_swr_ch);
    if (out_dec_name && dec->name) snprintf(out_dec_name, 32, "%s", dec->name);
    *out_codec_ctx = ctx;
    *out_swr = swr;
    return 0;
}

void dk_shim_close_swr(void** swr) {
    if (swr && *swr) {
        struct SwrContext* s = (struct SwrContext*)(*swr);
        swr_free(&s);
        *swr = NULL;
    }
}

int32_t dk_shim_audio_frame_prepare(
    const void* frame_raw,
    const void* codec_ctx_raw,
    const void* fmt_raw,
    int32_t audio_stream_idx,
    void** inout_swr,
    int32_t* inout_fmt,
    int32_t* inout_rate,
    int32_t* inout_ch,
    double drop_until_pts,
    bool* out_dropped,
    double* out_pts,
    bool* out_has_pts
) {
    const AVFrame* frame = (const AVFrame*)frame_raw;
    const AVCodecContext* codec_ctx = (const AVCodecContext*)codec_ctx_raw;
    const AVFormatContext* fmt = (const AVFormatContext*)fmt_raw;
    if (out_dropped) *out_dropped = false;
    if (!frame || !inout_swr) return 0;

    int f_rate = frame->sample_rate > 0 ? frame->sample_rate : 48000;
    enum AVSampleFormat f_fmt = (enum AVSampleFormat)frame->format;
    int f_ch = frame->ch_layout.nb_channels > 0 ? frame->ch_layout.nb_channels : 2;

    if (!*inout_swr || (int32_t)f_fmt != *inout_fmt || f_rate != *inout_rate || f_ch != *inout_ch) {
        struct SwrContext* swr = (struct SwrContext*)(*inout_swr);
        dk_shim_configure_swr(codec_ctx, &frame->ch_layout, f_fmt, f_rate, &swr, inout_fmt, inout_rate, inout_ch);
        *inout_swr = swr;
    }
    if (!*inout_swr) return 0;

    double pts = 0.0;
    bool has_pts = false;
    if (fmt && audio_stream_idx >= 0 && (unsigned)audio_stream_idx < fmt->nb_streams) {
        double tb = av_q2d(fmt->streams[audio_stream_idx]->time_base);
        if (frame->best_effort_timestamp != AV_NOPTS_VALUE) {
            pts = (double)frame->best_effort_timestamp * tb;
            has_pts = true;
        } else if (frame->pts != AV_NOPTS_VALUE) {
            pts = (double)frame->pts * tb;
            has_pts = true;
        }
    }
    if (out_pts) *out_pts = pts;
    if (out_has_pts) *out_has_pts = has_pts;

    if (drop_until_pts > 0.0 && (pts + ((double)frame->nb_samples / (double)f_rate)) < drop_until_pts - 0.03) {
        if (out_dropped) *out_dropped = true;
        return 0;
    }

    struct SwrContext* swr = (struct SwrContext*)(*inout_swr);
    int max_out = (int)av_rescale_rnd(swr_get_delay(swr, f_rate) + frame->nb_samples, 48000, f_rate, AV_ROUND_UP);
    if (max_out <= 0) max_out = frame->nb_samples * 2;
    return max_out;
}

int32_t dk_shim_audio_frame_convert(
    const void* frame_raw,
    void* swr_raw,
    float* out_stereo_48k,
    int32_t max_out_samples,
    float* out_vad_mono_48k
) {
    const AVFrame* frame = (const AVFrame*)frame_raw;
    struct SwrContext* swr = (struct SwrContext*)swr_raw;
    if (!frame || !swr || !out_stereo_48k || max_out_samples <= 0) return 0;

    uint8_t* out_ptrs[1] = { (uint8_t*)out_stereo_48k };
    int converted = swr_convert(swr, out_ptrs, max_out_samples, (const uint8_t* const*)frame->data, frame->nb_samples);
    if (converted <= 0) return 0;

    if (out_vad_mono_48k) {
        const float* fc = NULL;
        const float* fl = NULL;
        const float* fr = NULL;
        if (frame->sample_rate == 48000 &&
            frame->format == AV_SAMPLE_FMT_FLTP &&
            frame->ch_layout.nb_channels >= 5 &&
            frame->nb_samples == converted) {
            int fc_idx = av_channel_layout_index_from_channel(&frame->ch_layout, AV_CHAN_FRONT_CENTER);
            int fl_idx = av_channel_layout_index_from_channel(&frame->ch_layout, AV_CHAN_FRONT_LEFT);
            int fr_idx = av_channel_layout_index_from_channel(&frame->ch_layout, AV_CHAN_FRONT_RIGHT);
            if (fc_idx >= 0 && fc_idx < frame->ch_layout.nb_channels &&
                fl_idx >= 0 && fl_idx < frame->ch_layout.nb_channels &&
                fr_idx >= 0 && fr_idx < frame->ch_layout.nb_channels &&
                frame->data[fc_idx] && frame->data[fl_idx] && frame->data[fr_idx]) {
                fc = (const float*)frame->data[fc_idx];
                fl = (const float*)frame->data[fl_idx];
                fr = (const float*)frame->data[fr_idx];
            }
        }
        for (int i = 0; i < converted; i++) {
            out_vad_mono_48k[i] = fc
                ? (0.78f * fc[i] + 0.11f * (fl[i] + fr[i]))
                : (0.5f * (out_stereo_48k[i * 2] + out_stereo_48k[i * 2 + 1]));
        }
    }
    return converted;
}

typedef void (*DKShimAqCallbackFn)(void* rust_ctx, void* aq, void* buf, float* dst_floats, uint32_t cap_floats);

typedef struct {
    void* rust_ctx;
    DKShimAqCallbackFn cb;
} DKShimAqTrampoline;

static void dk_shim_audio_queue_cb(void* custom_data, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    DKShimAqTrampoline* tr = (DKShimAqTrampoline*)custom_data;
    if (!tr || !tr->cb || !inBuffer) return;
    uint32_t cap_floats = inBuffer->mAudioDataBytesCapacity / sizeof(float);
    tr->cb(tr->rust_ctx, inAQ, inBuffer, (float*)inBuffer->mAudioData, cap_floats);
}

bool dk_shim_aq_create(
    DKShimAqCallbackFn cb,
    void* rust_ctx,
    float rate,
    float effective_vol,
    void** out_aq,
    void** out_trampoline,
    void* out_bufs[4]
) {
    if (!out_aq || !out_trampoline || !out_bufs) return false;
    *out_aq = NULL;
    *out_trampoline = NULL;
    for (int i = 0; i < 4; i++) out_bufs[i] = NULL;

    DKShimAqTrampoline* tr = (DKShimAqTrampoline*)calloc(1, sizeof(DKShimAqTrampoline));
    if (!tr) return false;
    tr->rust_ctx = rust_ctx;
    tr->cb = cb;

    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate = 48000.0;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = 8;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = 8;
    asbd.mChannelsPerFrame = 2;
    asbd.mBitsPerChannel = 32;

    AudioQueueRef aq = NULL;
    OSStatus st = AudioQueueNewOutput(&asbd, dk_shim_audio_queue_cb, tr, NULL, NULL, 0, &aq);
    if (st != noErr || !aq) {
        free(tr);
        return false;
    }

    UInt32 timePitch = 1;
    AudioQueueSetProperty(aq, kAudioQueueProperty_EnableTimePitch, &timePitch, sizeof(timePitch));
    AudioQueueSetParameter(aq, kAudioQueueParam_PlayRate, rate);
    AudioQueueSetParameter(aq, kAudioQueueParam_Volume, effective_vol);

    for (int i = 0; i < 4; i++) {
        AudioQueueBufferRef b = NULL;
        AudioQueueAllocateBuffer(aq, 8192, &b);
        out_bufs[i] = b;
    }
    *out_aq = aq;
    *out_trampoline = tr;
    return true;
}

void dk_shim_aq_fill_and_enqueue(
    void* aq_raw,
    void* buf_raw,
    void (*fill_fn)(void* ctx, float* dst, uint32_t cap_floats),
    void* ctx
) {
    AudioQueueRef aq = (AudioQueueRef)aq_raw;
    AudioQueueBufferRef buf = (AudioQueueBufferRef)buf_raw;
    if (!aq || !buf || !fill_fn) return;
    uint32_t cap_floats = buf->mAudioDataBytesCapacity / sizeof(float);
    fill_fn(ctx, (float*)buf->mAudioData, cap_floats);
    buf->mAudioDataByteSize = buf->mAudioDataBytesCapacity;
    AudioQueueEnqueueBuffer(aq, buf, 0, NULL);
}

void dk_shim_aq_commit_and_enqueue(void* aq_raw, void* buf_raw) {
    AudioQueueRef aq = (AudioQueueRef)aq_raw;
    AudioQueueBufferRef buf = (AudioQueueBufferRef)buf_raw;
    if (!aq || !buf) return;
    buf->mAudioDataByteSize = buf->mAudioDataBytesCapacity;
    AudioQueueEnqueueBuffer(aq, buf, 0, NULL);
}

int32_t dk_shim_aq_prime_and_start(void* aq_raw) {
    AudioQueueRef aq = (AudioQueueRef)aq_raw;
    if (!aq) return -1;
    AudioQueuePrime(aq, 0, NULL);
    return (int32_t)AudioQueueStart(aq, NULL);
}

int32_t dk_shim_aq_start_only(void* aq_raw) {
    AudioQueueRef aq = (AudioQueueRef)aq_raw;
    return aq ? (int32_t)AudioQueueStart(aq, NULL) : -1;
}

void dk_shim_aq_pause(void* aq_raw) {
    if (aq_raw) AudioQueuePause((AudioQueueRef)aq_raw);
}

void dk_shim_aq_stop_reset(void* aq_raw) {
    if (aq_raw) {
        AudioQueueStop((AudioQueueRef)aq_raw, true);
        AudioQueueReset((AudioQueueRef)aq_raw);
    }
}

void dk_shim_aq_reset_only(void* aq_raw) {
    if (aq_raw) AudioQueueReset((AudioQueueRef)aq_raw);
}

void dk_shim_aq_stop_dispose(void** aq_ptr, void** trampoline_ptr) {
    if (aq_ptr && *aq_ptr) {
        AudioQueueRef aq = (AudioQueueRef)(*aq_ptr);
        AudioQueueStop(aq, true);
        AudioQueueDispose(aq, true);
        *aq_ptr = NULL;
    }
    if (trampoline_ptr && *trampoline_ptr) {
        free(*trampoline_ptr);
        *trampoline_ptr = NULL;
    }
}

void dk_shim_aq_set_rate(void* aq_raw, float rate) {
    if (aq_raw) AudioQueueSetParameter((AudioQueueRef)aq_raw, kAudioQueueParam_PlayRate, rate);
}

void dk_shim_aq_set_volume(void* aq_raw, float vol) {
    if (aq_raw) AudioQueueSetParameter((AudioQueueRef)aq_raw, kAudioQueueParam_Volume, vol);
}

bool dk_shim_aq_get_sample_time(void* aq_raw, int64_t* out_sample_time) {
    if (!aq_raw || !out_sample_time) return false;
    AudioTimeStamp ts;
    memset(&ts, 0, sizeof(ts));
    OSStatus err = AudioQueueGetCurrentTime((AudioQueueRef)aq_raw, NULL, &ts, NULL);
    if (err == noErr && (ts.mFlags & kAudioTimeStampSampleTimeValid)) {
        *out_sample_time = (int64_t)ts.mSampleTime;
        return true;
    }
    return false;
}

// -----------------------------------------------------------------------------
// 6. Subtitle Decoder, CFStringTransform & libass Struct Accessors
// -----------------------------------------------------------------------------

size_t dk_shim_cf_transform_utf8(
    const uint8_t* src_bytes,
    size_t src_len,
    int32_t mode,
    uint8_t* dst_buf,
    size_t dst_cap
) {
    if (!src_bytes || src_len == 0 || mode == 0 || !dst_buf || dst_cap == 0) return 0;
    CFStringRef src = CFStringCreateWithBytes(
        kCFAllocatorDefault, src_bytes, (CFIndex)src_len, kCFStringEncodingUTF8, false
    );
    if (!src) return 0;
    CFMutableStringRef mut = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, src);
    CFRelease(src);
    if (!mut) return 0;
    CFStringRef transform_id = (mode == 1) ? CFSTR("Hant-Hans") : CFSTR("Hans-Hant");
    CFStringTransform(mut, NULL, transform_id, false);
    Boolean ok = CFStringGetCString(mut, (char*)dst_buf, (CFIndex)dst_cap, kCFStringEncodingUTF8);
    CFRelease(mut);
    if (!ok) return 0;
    return strlen((const char*)dst_buf);
}

int dk_shim_open_sub_decoder(
    const void* fmt_raw,
    int32_t stream_idx,
    void** out_codec_ctx,
    const uint8_t** out_hdr,
    int32_t* out_hdr_len,
    char out_dec_name[32]
) {
    const AVFormatContext* fmt = (const AVFormatContext*)fmt_raw;
    if (!fmt || !out_codec_ctx || stream_idx < 0 || (unsigned)stream_idx >= fmt->nb_streams) return -1;
    *out_codec_ctx = NULL;
    if (out_hdr) *out_hdr = NULL;
    if (out_hdr_len) *out_hdr_len = 0;
    if (out_dec_name) out_dec_name[0] = '\0';

    const AVStream* st = fmt->streams[stream_idx];
    if (st->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) return -1;

    const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return AVERROR_DECODER_NOT_FOUND;

    AVCodecContext* ctx = avcodec_alloc_context3(dec);
    if (!ctx) return AVERROR(ENOMEM);
    avcodec_parameters_to_context(ctx, st->codecpar);
    ctx->pkt_timebase = st->time_base;
    int ret = avcodec_open2(ctx, dec, NULL);
    if (ret < 0) {
        avcodec_free_context(&ctx);
        return ret;
    }
    if (out_hdr && out_hdr_len && ctx->subtitle_header && ctx->subtitle_header_size > 0) {
        *out_hdr = ctx->subtitle_header;
        *out_hdr_len = ctx->subtitle_header_size;
    }
    if (out_dec_name && dec->name) snprintf(out_dec_name, 32, "%s", dec->name);
    *out_codec_ctx = ctx;
    return 0;
}

typedef void (*DKShimSubTextCb)(
    void* ctx,
    const uint8_t* text,
    size_t len,
    bool is_ass_rect,
    bool evt_forced,
    int64_t start_ms,
    int64_t dur_ms
);
typedef void (*DKShimSubBitmapBeginCb)(
    void* ctx,
    double cue_start,
    double cue_end,
    int32_t canvas_w,
    int32_t canvas_h,
    uint32_t num_rects
);
typedef void (*DKShimSubBitmapRectCb)(
    void* ctx,
    int32_t x,
    int32_t y,
    int32_t w,
    int32_t h,
    int32_t linesize,
    const uint8_t* indices,
    const uint32_t* palette256,
    bool rect_forced
);
typedef void (*DKShimSubBitmapEndCb)(void* ctx);

void dk_shim_decode_subtitle_pkt(
    const void* fmt_raw,
    int32_t stream_idx,
    void* sub_codec_ctx_raw,
    const void* pkt_raw,
    int32_t fallback_storage_w,
    int32_t fallback_storage_h,
    void* cb_ctx,
    DKShimSubTextCb on_text,
    DKShimSubBitmapBeginCb on_bmp_begin,
    DKShimSubBitmapRectCb on_bmp_rect,
    DKShimSubBitmapEndCb on_bmp_end
) {
    const AVFormatContext* fmt = (const AVFormatContext*)fmt_raw;
    const AVPacket* pkt = (const AVPacket*)pkt_raw;
    if (!fmt || !pkt || stream_idx < 0 || (unsigned)stream_idx >= fmt->nb_streams) return;
    const AVStream* st = fmt->streams[stream_idx];
    bool stream_forced = (st->disposition & AV_DISPOSITION_FORCED) != 0;

    int64_t raw_ts = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
    int64_t pkt_pts_ms = (raw_ts != AV_NOPTS_VALUE)
        ? av_rescale_q(raw_ts, st->time_base, (AVRational){1, 1000})
        : 0;
    int64_t pkt_dur_ms = (pkt->duration > 0)
        ? av_rescale_q(pkt->duration, st->time_base, (AVRational){1, 1000})
        : 3500;

    if ((st->codecpar->codec_id == AV_CODEC_ID_ASS || st->codecpar->codec_id == AV_CODEC_ID_SSA) &&
        pkt->data && pkt->size > 0) {
        if (on_text) {
            on_text(cb_ctx, pkt->data, (size_t)pkt->size, true, stream_forced, pkt_pts_ms, pkt_dur_ms);
        }
        return;
    }

    AVCodecContext* codec_ctx = (AVCodecContext*)sub_codec_ctx_raw;
    if (!codec_ctx) return;

    AVSubtitle sub;
    memset(&sub, 0, sizeof(sub));
    int got_sub = 0;
    int ret = avcodec_decode_subtitle2(codec_ctx, &sub, &got_sub, (AVPacket*)pkt);
    if (ret < 0 || !got_sub) {
        avsubtitle_free(&sub);
        return;
    }

    int64_t base_ms = (sub.pts != AV_NOPTS_VALUE) ? (sub.pts / 1000) : pkt_pts_ms;
    int64_t start_ms = base_ms + (int64_t)sub.start_display_time;
    int64_t dur_ms = (sub.end_display_time > sub.start_display_time && sub.end_display_time < 3600000)
        ? (int64_t)(sub.end_display_time - sub.start_display_time)
        : pkt_dur_ms;

    if (sub.format == 0) {
        double cue_start = (double)start_ms / 1000.0;
        double cue_end = (sub.end_display_time > sub.start_display_time && sub.end_display_time < 3600000)
            ? ((double)(base_ms + (int64_t)sub.end_display_time) / 1000.0)
            : (cue_start + 12.0);
        int32_t cw = (codec_ctx->width > 0) ? codec_ctx->width : fallback_storage_w;
        int32_t ch = (codec_ctx->height > 0) ? codec_ctx->height : fallback_storage_h;

        if (on_bmp_begin) on_bmp_begin(cb_ctx, cue_start, cue_end, cw, ch, sub.num_rects);
        if (sub.num_rects > 0 && on_bmp_rect) {
            for (unsigned r = 0; r < sub.num_rects; r++) {
                const AVSubtitleRect* rect = sub.rects[r];
                if (!rect || rect->type != SUBTITLE_BITMAP || rect->w <= 0 || rect->h <= 0 || !rect->data[0] || !rect->data[1]) {
                    continue;
                }
                bool r_forced = stream_forced || ((rect->flags & AV_SUBTITLE_FLAG_FORCED) != 0);
                on_bmp_rect(
                    cb_ctx,
                    rect->x, rect->y, rect->w, rect->h, rect->linesize[0],
                    rect->data[0], (const uint32_t*)rect->data[1], r_forced
                );
            }
        }
        if (on_bmp_end) on_bmp_end(cb_ctx);
    } else if (on_text) {
        for (unsigned r = 0; r < sub.num_rects; r++) {
            const AVSubtitleRect* rect = sub.rects[r];
            if (!rect) continue;
            bool evt_forced = stream_forced || ((rect->flags & AV_SUBTITLE_FLAG_FORCED) != 0);
            if (rect->type == SUBTITLE_ASS && rect->ass) {
                on_text(cb_ctx, (const uint8_t*)rect->ass, strlen(rect->ass), true, evt_forced, start_ms, dur_ms);
            } else if (rect->type == SUBTITLE_TEXT && rect->text) {
                on_text(cb_ctx, (const uint8_t*)rect->text, strlen(rect->text), false, evt_forced, start_ms, dur_ms);
            }
        }
    }

    avsubtitle_free(&sub);
}

void dk_shim_ass_track_meta(
    const void* track_raw,
    int32_t* out_n_styles,
    int32_t* out_n_events,
    int32_t* out_play_res_y,
    bool* out_has_event_format
) {
    const ASS_Track* tr = (const ASS_Track*)track_raw;
    if (!tr) {
        if (out_n_styles) *out_n_styles = 0;
        if (out_n_events) *out_n_events = 0;
        if (out_play_res_y) *out_play_res_y = 0;
        if (out_has_event_format) *out_has_event_format = false;
        return;
    }
    if (out_n_styles) *out_n_styles = tr->n_styles;
    if (out_n_events) *out_n_events = tr->n_events;
    if (out_play_res_y) *out_play_res_y = tr->PlayResY;
    if (out_has_event_format) *out_has_event_format = (tr->event_format != NULL);
}

bool dk_shim_ass_style_read(
    const void* track_raw,
    int32_t idx,
    const char** out_name,
    const char** out_font_name,
    double* out_font_size,
    double* out_outline,
    int32_t* out_margin_v,
    uint32_t* out_primary_colour,
    double* out_scale_x,
    double* out_scale_y,
    int32_t* out_alignment,
    int32_t* out_border_style
) {
    const ASS_Track* tr = (const ASS_Track*)track_raw;
    if (!tr || !tr->styles || idx < 0 || idx >= tr->n_styles) return false;
    const ASS_Style* st = &tr->styles[idx];
    if (out_name) *out_name = st->Name;
    if (out_font_name) *out_font_name = st->FontName;
    if (out_font_size) *out_font_size = st->FontSize;
    if (out_outline) *out_outline = st->Outline;
    if (out_margin_v) *out_margin_v = st->MarginV;
    if (out_primary_colour) *out_primary_colour = st->PrimaryColour;
    if (out_scale_x) *out_scale_x = st->ScaleX;
    if (out_scale_y) *out_scale_y = st->ScaleY;
    if (out_alignment) *out_alignment = st->Alignment;
    if (out_border_style) *out_border_style = st->BorderStyle;
    return true;
}

void dk_shim_ass_style_write(
    void* track_raw,
    int32_t idx,
    const char* desired_font,
    uint32_t primary_colour,
    double font_size,
    double outline,
    int32_t margin_v,
    double scale_x,
    double scale_y,
    int32_t alignment,
    int32_t border_style,
    bool update_box_metrics
) {
    ASS_Track* tr = (ASS_Track*)track_raw;
    if (!tr || !tr->styles || idx < 0 || idx >= tr->n_styles) return;
    ASS_Style* st = &tr->styles[idx];
    if (desired_font) {
        if (!st->FontName || strcmp(st->FontName, desired_font) != 0) {
            if (st->FontName) free(st->FontName);
            st->FontName = strdup(desired_font);
        }
    }
    st->PrimaryColour = primary_colour;
    if (update_box_metrics) {
        st->FontSize = font_size;
        st->Outline = outline;
        st->MarginV = margin_v;
        st->ScaleX = scale_x;
        st->ScaleY = scale_y;
        st->Alignment = alignment;
        st->BorderStyle = border_style;
    }
}

bool dk_shim_ass_event_read(
    const void* track_raw,
    int32_t idx,
    int64_t* out_start_ms,
    int64_t* out_dur_ms,
    int32_t* out_style_idx,
    int32_t* out_margin_v,
    const char** out_text
) {
    const ASS_Track* tr = (const ASS_Track*)track_raw;
    if (!tr || !tr->events || idx < 0 || idx >= tr->n_events) return false;
    const ASS_Event* ev = &tr->events[idx];
    if (out_start_ms) *out_start_ms = (int64_t)ev->Start;
    if (out_dur_ms) *out_dur_ms = (int64_t)ev->Duration;
    if (out_style_idx) *out_style_idx = ev->Style;
    if (out_margin_v) *out_margin_v = ev->MarginV;
    if (out_text) *out_text = ev->Text;
    return true;
}

void dk_shim_ass_event_zero_margin_v(void* track_raw, int32_t idx) {
    ASS_Track* tr = (ASS_Track*)track_raw;
    if (!tr || !tr->events || idx < 0 || idx >= tr->n_events) return;
    tr->events[idx].MarginV = 0;
}

const void* dk_shim_ass_image_read(
    const void* img_raw,
    int32_t* out_w,
    int32_t* out_h,
    int32_t* out_stride,
    const uint8_t** out_bitmap,
    uint32_t* out_color,
    int32_t* out_dst_x,
    int32_t* out_dst_y
) {
    const ASS_Image* img = (const ASS_Image*)img_raw;
    if (!img) return NULL;
    if (out_w) *out_w = img->w;
    if (out_h) *out_h = img->h;
    if (out_stride) *out_stride = img->stride;
    if (out_bitmap) *out_bitmap = img->bitmap;
    if (out_color) *out_color = img->color;
    if (out_dst_x) *out_dst_x = img->dst_x;
    if (out_dst_y) *out_dst_y = img->dst_y;
    return img->next;
}
