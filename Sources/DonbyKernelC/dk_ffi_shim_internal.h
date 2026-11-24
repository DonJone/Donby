#pragma once

#include "donby_kernel.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

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

typedef void (*DKShimAqCallbackFn)(void* rust_ctx, void* aq, void* buf, float* dst_floats, uint32_t cap_floats);

typedef void (*DKShimSubTextCb)(
    void* ctx, const uint8_t* text, size_t len, bool is_ass_rect,
    bool evt_forced, int64_t start_ms, int64_t dur_ms
);
typedef void (*DKShimSubBitmapBeginCb)(
    void* ctx, double cue_start, double cue_end,
    int32_t canvas_w, int32_t canvas_h, uint32_t num_rects
);
typedef void (*DKShimSubBitmapRectCb)(
    void* ctx, int32_t x, int32_t y, int32_t w, int32_t h, int32_t linesize,
    const uint8_t* indices, const uint32_t* palette256, bool rect_forced
);
typedef void (*DKShimSubBitmapEndCb)(void* ctx);

extern void dk_rust_forward_ffmpeg_log(int level, const char* message);

// Core logging, errors, packet/frame, format/AVIO, and shared codec helpers (dk_ffi_shim.c)
void dk_shim_install_ffmpeg_log_bridge(void);
int dk_shim_averror_eof(void);
int dk_shim_averror_exit(void);
int dk_shim_averror_eio(void);
int dk_shim_averror_enosys(void);
bool dk_shim_is_eof(int err);
bool dk_shim_is_eagain(int err);
void dk_shim_strerror(int err, char* buf, size_t cap);

void* dk_shim_pkt_alloc(void);
void dk_shim_pkt_free(void** pkt);
void* dk_shim_pkt_clone(const void* pkt);
void dk_shim_pkt_unref(void* pkt);
void* dk_shim_pkt_move_alloc(void* src_pkt);
int32_t dk_shim_pkt_stream_index(const void* pkt);
int32_t dk_shim_pkt_size(const void* pkt);

void* dk_shim_frame_alloc(void);
void dk_shim_frame_free(void** frame);
void dk_shim_frame_unref(void* frame);

int dk_shim_open_format(
    const char* url, const char* headers_crlf, bool is_local_file,
    bool has_start_seek, bool is_mpeg_ts, bool use_custom_io, bool has_seek_cb,
    void* opaque, int (*interrupt_cb)(void*),
    int (*read_cb)(void*, uint8_t*, int), int64_t (*seek_cb)(void*, int64_t, int),
    void** out_fmt, void** out_avio
);
void dk_shim_close_format(void** fmt_ptr, void** custom_avio_ptr);
void dk_shim_format_summary(
    const void* fmt_raw, uint32_t* out_nb_streams, uint32_t* out_nb_chapters,
    double* out_duration_sec, int64_t* out_bit_rate
);
bool dk_shim_get_stream_meta(const void* fmt_raw, uint32_t idx, DKShimStreamMeta* out);
bool dk_shim_get_chapter_info(const void* fmt_raw, uint32_t idx, DKChapterInfo* out);
void dk_shim_clear_avio_error(void* fmt_raw);
int64_t dk_shim_avio_bytes_read(const void* fmt_raw);
void dk_shim_avio_retry_reseek(void* fmt_raw);
int dk_shim_seek_format(void* fmt_raw, double target_sec, bool allow_fallback);
int dk_shim_read_frame(
    void* fmt_raw, void* pkt_raw, int32_t* out_stream_idx, int32_t* out_size,
    bool* out_corrupt, double* out_pkt_sec, bool* out_has_pts, const uint8_t** out_data
);
bool dk_shim_is_hevc_stream(const void* fmt_raw, int32_t stream_idx);

void dk_shim_close_codec(void** codec_ctx);
int dk_shim_send_packet(void* codec_ctx, const void* pkt);
int dk_shim_receive_frame(void* codec_ctx, void* frame);
void dk_shim_flush_codec(void* codec_ctx);

// VideoToolbox, IOSurface pool, HDR/DoVi color uniforms, and thumbnails (dk_ffi_video.c)
void* dk_shim_alloc_hw_fmt_ctx(
    void* rust_opaque, bool (*is_vt_failed)(void*), void (*on_sw_format_selected)(void*)
);
void dk_shim_free_hw_fmt_ctx(void** ptr);
int dk_shim_open_video_decoder(
    const void* fmt_raw, int32_t stream_idx, bool hw_decode, int32_t sw_threads,
    void* hw_fmt_ctx_opaque, void** out_codec_ctx, void** out_hw_ctx,
    bool* out_is_hw, char out_dec_name[32]
);
void dk_shim_unref_hw_ctx(void** hw_ctx);
CVPixelBufferRef dk_shim_process_video_frame(
    const void* frame_raw, const void* fmt_raw, int32_t video_stream_idx,
    uint8_t stream_dovi_profile, double fallback_fps, double prev_pts,
    double drop_until_pts, bool* out_dropped, double* out_pts,
    void** inout_sws, void** inout_pool, int32_t* inout_pool_w,
    int32_t* inout_pool_h, uint32_t* inout_pool_fmt,
    DKGpuColorUniforms* out_color, bool* out_is_hw, bool* out_is_hdr,
    bool* out_is_dovi, char out_cs_label[32]
);
void dk_shim_release_sw_video_res(void** sws, void** pool);
void dk_shim_retain_pixbuf(CVPixelBufferRef pb);
void dk_shim_release_pixbuf(CVPixelBufferRef pb);
CGImageRef dk_shim_extract_thumbnail(const char* path, double target_sec);

// Audio decoder, SwrContext resampler, VAD tap, and AudioQueue (dk_ffi_audio.c)
int dk_shim_open_audio_decoder(
    const void* fmt_raw, int32_t stream_idx, void** out_codec_ctx, void** out_swr,
    int32_t* out_swr_fmt, int32_t* out_swr_rate, int32_t* out_swr_ch, char out_dec_name[32]
);
void dk_shim_close_swr(void** swr);
int32_t dk_shim_audio_frame_prepare(
    const void* frame_raw, const void* codec_ctx_raw, const void* fmt_raw,
    int32_t audio_stream_idx, void** inout_swr, int32_t* inout_fmt,
    int32_t* inout_rate, int32_t* inout_ch, double drop_until_pts,
    bool* out_dropped, double* out_pts, bool* out_has_pts
);
int32_t dk_shim_audio_frame_convert(
    const void* frame_raw, void* swr_raw, float* out_stereo_48k,
    int32_t max_out_samples, float* out_vad_mono_48k
);
bool dk_shim_aq_create(
    DKShimAqCallbackFn cb, void* rust_ctx, float rate, float effective_vol,
    void** out_aq, void** out_trampoline, void* out_bufs[4]
);
void dk_shim_aq_fill_and_enqueue(
    void* aq_raw, void* buf_raw,
    void (*fill_fn)(void* ctx, float* dst, uint32_t cap_floats), void* ctx
);
void dk_shim_aq_commit_and_enqueue(void* aq_raw, void* buf_raw);
int32_t dk_shim_aq_prime_and_start(void* aq_raw);
int32_t dk_shim_aq_start_only(void* aq_raw);
void dk_shim_aq_pause(void* aq_raw);
void dk_shim_aq_stop_reset(void* aq_raw);
void dk_shim_aq_reset_only(void* aq_raw);
void dk_shim_aq_stop_dispose(void** aq_ptr, void** trampoline_ptr);
void dk_shim_aq_set_rate(void* aq_raw, float rate);
void dk_shim_aq_set_volume(void* aq_raw, float vol);
bool dk_shim_aq_get_sample_time(void* aq_raw, int64_t* out_sample_time);

// Subtitle decoder, CFStringTransform, and libass struct accessors (dk_ffi_subtitle.c)
size_t dk_shim_cf_transform_utf8(
    const uint8_t* src_bytes, size_t src_len, int32_t mode, uint8_t* dst_buf, size_t dst_cap
);
int dk_shim_open_sub_decoder(
    const void* fmt_raw, int32_t stream_idx, void** out_codec_ctx,
    const uint8_t** out_hdr, int32_t* out_hdr_len, char out_dec_name[32]
);
void dk_shim_decode_subtitle_pkt(
    const void* fmt_raw, int32_t stream_idx, void* sub_codec_ctx_raw, const void* pkt_raw,
    int32_t fallback_storage_w, int32_t fallback_storage_h, void* cb_ctx,
    DKShimSubTextCb on_text, DKShimSubBitmapBeginCb on_bmp_begin,
    DKShimSubBitmapRectCb on_bmp_rect, DKShimSubBitmapEndCb on_bmp_end
);
void dk_shim_ass_track_meta(
    const void* track_raw, int32_t* out_n_styles, int32_t* out_n_events,
    int32_t* out_play_res_y, bool* out_has_event_format
);
bool dk_shim_ass_style_read(
    const void* track_raw, int32_t idx, const char** out_name, const char** out_font_name,
    double* out_font_size, double* out_outline, int32_t* out_margin_v,
    uint32_t* out_primary_colour, double* out_scale_x, double* out_scale_y,
    int32_t* out_alignment, int32_t* out_border_style
);
void dk_shim_ass_style_write(
    void* track_raw, int32_t idx, const char* desired_font, uint32_t primary_colour,
    double font_size, double outline, int32_t margin_v, double scale_x, double scale_y,
    int32_t alignment, int32_t border_style, bool update_box_metrics
);
bool dk_shim_ass_event_read(
    const void* track_raw, int32_t idx, int64_t* out_start_ms, int64_t* out_dur_ms,
    int32_t* out_style_idx, int32_t* out_margin_v, const char** out_text
);
void dk_shim_ass_event_zero_margin_v(void* track_raw, int32_t idx);
const void* dk_shim_ass_image_read(
    const void* img_raw, int32_t* out_w, int32_t* out_h, int32_t* out_stride,
    const uint8_t** out_bitmap, uint32_t* out_color, int32_t* out_dst_x, int32_t* out_dst_y
);
