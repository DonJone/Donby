#include "dk_ffi_shim_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

#include <ass/ass.h>

#include <CoreFoundation/CoreFoundation.h>

// -----------------------------------------------------------------------------
// Subtitle Decoder, CFStringTransform & libass Struct Accessors
// -----------------------------------------------------------------------------

static void dk_shim_ass_msg_cb(int level, const char* fmt, va_list va, void* data) {
    (void)level;
    (void)fmt;
    (void)va;
    (void)data;
}

void dk_shim_ass_set_quiet_logger(void* ass_lib_raw) {
    if (ass_lib_raw) {
        ass_set_message_cb((ASS_Library*)ass_lib_raw, dk_shim_ass_msg_cb, NULL);
    }
}

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
