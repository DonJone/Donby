#include "dk_ffi_shim_internal.h"

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/log.h>
#include <libavutil/pixdesc.h>

// Lock C header layout to KernelRust/src/abi.rs at compile time.
_Static_assert(sizeof(DKPlayerState) == 4, "DKPlayerState size drift");
_Static_assert(sizeof(DKRuntimeStats) == 160, "DKRuntimeStats size drift");
_Static_assert(sizeof(DKTrackInfo) == 204, "DKTrackInfo size drift");
_Static_assert(sizeof(DKChapterInfo) == 152, "DKChapterInfo size drift");
_Static_assert(sizeof(DKSubtitleInterval) == 16, "DKSubtitleInterval size drift");
_Static_assert(sizeof(DKSubtitleStyleConfig) == 64, "DKSubtitleStyleConfig size drift");
_Static_assert(sizeof(DKGpuColorUniforms) == 3088, "DKGpuColorUniforms size drift");

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
// 4. Shared Codec Lifecycle & Packet/Frame Dispatch
// -----------------------------------------------------------------------------

void dk_shim_close_codec(void** codec_ctx) {
    if (codec_ctx && *codec_ctx) {
        AVCodecContext* c = (AVCodecContext*)(*codec_ctx);
        avcodec_free_context(&c);
        *codec_ctx = NULL;
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
