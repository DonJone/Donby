#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DKPlayer DKPlayer;

typedef enum {
    DK_STATE_IDLE = 0,
    DK_STATE_OPENING,
    DK_STATE_BUFFERING,
    DK_STATE_PLAYING,
    DK_STATE_PAUSED,
    DK_STATE_ENDED,
    DK_STATE_ERROR
} DKPlayerState;

typedef struct {
    int32_t width;
    int32_t height;
    int32_t bit_depth;
    double  fps;
    double  video_bitrate_mbps;
    bool    is_hdr;
    bool    is_dolby_vision;
    bool    is_hw_accelerated;
    char    video_codec[32];
    char    audio_codec[32];
    char    color_space[32];
    int64_t cached_bytes;
    int64_t total_bytes_read;
    double  download_speed_mbs;
} DKRuntimeStats;

typedef struct {
    int32_t stream_index;
    int32_t channels;
    bool    is_selected;
    bool    is_default;
    bool    is_forced;
    char    codec[32];
    char    language[32];
    char    title[128];
} DKTrackInfo;

typedef struct {
    int32_t index;
    double  start_sec;
    double  end_sec;
    char    title[128];
} DKChapterInfo;

typedef struct {
    double  start_sec;
    double  end_sec;
} DKSubtitleInterval;

typedef struct {
    float   scale;
    float   border_width;
    float   vertical_pos_percent;
    double  primary_delay_sec;
    double  secondary_delay_sec;
    int32_t text_transform;       // 0 = off, 1 = Hant-Hans (Simplified), 2 = Hans-Hant (Traditional)
    bool    override_ass_style;
    bool    forced_only;
    bool    unify_pingfang_font;
    bool    enhance_secondary_yellow;
    float   secondary_scale;      // relative scale of secondary subtitle vs primary (default 0.80)
    float   dual_gap_px;          // vertical spacing in px between primary and secondary layers (default 10.0)
    bool    primary_on_top;       // true = primary above secondary (classic CN-top / EN-bottom)
    int32_t dual_layout_mode;     // 0 = bottom stacked, 1 = split (primary bottom, secondary top)
    int32_t dual_anchor_mode;     // 0 = auto (prefer English/Latin), 1 = primary anchor, 2 = secondary anchor
} DKSubtitleStyleConfig;

typedef int     (*DKCustomIOReadCallback)(void* opaque, uint8_t* buf, int buf_size);
typedef int64_t (*DKCustomIOSeekCallback)(void* opaque, int64_t offset, int whence);
typedef void    (*DKCustomIOAbortCallback)(void* opaque);
typedef void    (*DKCustomIOCloseCallback)(void* opaque);

// Shared 4-byte-aligned GPU color/HDR/DolbyVision descriptor synchronized per video frame
typedef struct {
    // Group 0 (16B)
    int32_t transfer_fn;       // 0 = SDR (sRGB/BT.709), 1 = PQ (SMPTE ST 2084), 2 = HLG (ARIB STD-B67)
    int32_t primaries;         // 0 = BT.709, 1 = BT.2020, 2 = Display P3
    int32_t is_full_range;     // 0 = Limited/Video range, 1 = Full range
    int32_t bit_depth;         // 8, 10, 12, 16

    // Group 1 (16B)
    int32_t use_dovi_chain;    // 1 = Dolby Vision RPU matrix chain, 0 = standard YCbCr matrix
    int32_t has_dovi_reshape;  // 1 = evaluate piecewise polynomial reshaping per component
    float   source_peak_nits;  // Mastering / MaxCLL / DoVi L1 peak nits (default 1000 for HDR, 203 for SDR)
    float   edr_headroom;      // Populated by Metal view (1.0 = SDR display, >1.0 = Apple XDR/EDR headroom)

    // Group 2 (16B): [offset_y, offset_cb, offset_cr, sample_aspect_ratio]
    float   ycc_offset[4];

    // Groups 3..5 (48B): 3x3 row-major YCbCr/IPT -> non-linear RGB/LMS matrix
    float   yuv_matrix_r0[4];
    float   yuv_matrix_r1[4];
    float   yuv_matrix_r2[4];

    // Groups 6..8 (48B): 3x3 row-major post-EOTF linear matrix (Identity for standard, HPE_inv*lms for DoVi)
    float   lin_matrix_r0[4];
    float   lin_matrix_r1[4];
    float   lin_matrix_r2[4];

    // Group 9 (16B): DoVi reshaping piece counts per channel [0..8]
    int32_t reshape_pieces[4];

    // Groups 10..18 (144B): 3 channels x 12 floats (pivots[0..8] normalized to [0,1])
    float   reshape_pivots[36];

    // Groups 19..42 (384B): 3 channels x 8 pieces x 4 floats [c0, c1, c2, 0]
    float   reshape_coeffs[96];

    // Groups 43..48 (96B): 3 channels x 8 pieces method/order packed as [mapping_idc, mmr_order, 0, 0] -> 24 ints (6x int4)
    int32_t reshape_mmr_meta[24];

    // Groups 49..192 (2304B): 3 channels x 8 pieces x 24 floats [const, ord1(7), ord2(7), ord3(7), pad(2)]
    float   reshape_mmr_coeffs[576];
} DKGpuColorUniforms;

typedef void (*DKLogCallback)(int level, const char* message);
void dk_set_log_callback(DKLogCallback callback);

typedef void (*DKSubtitleRgbaCallback)(const uint8_t* rgba, int32_t width, int32_t height, uint64_t serial, void* context);

DKPlayer* dk_player_create(void);
void      dk_player_destroy(DKPlayer* player);

int       dk_player_open_with_tracks(
    DKPlayer* player,
    const char* url,
    const char* headers_crlf,
    double start_sec,
    bool hw_decode,
    int32_t preferred_audio_idx,
    int32_t preferred_sub_idx
);
void      dk_player_set_custom_io(
    DKPlayer* player,
    void* opaque,
    DKCustomIOReadCallback read_cb,
    DKCustomIOSeekCallback seek_cb,
    DKCustomIOAbortCallback abort_cb,
    DKCustomIOCloseCallback close_cb
);
void      dk_player_request_abort(DKPlayer* player);
void      dk_player_close(DKPlayer* player);
void      dk_player_play(DKPlayer* player);
void      dk_player_pause(DKPlayer* player);
void      dk_player_seek(DKPlayer* player, double target_sec, bool accurate);
bool      dk_player_should_yield_read(DKPlayer* player);
void      dk_player_set_rate(DKPlayer* player, float rate);
void      dk_player_set_volume(DKPlayer* player, float volume, bool muted);
void      dk_player_set_buffer_limit_mb(DKPlayer* player, int32_t limit_mb);

int       dk_player_get_track_count(DKPlayer* player, int track_type);
bool      dk_player_get_track_info(DKPlayer* player, int track_type, int ordinal, DKTrackInfo* out_info);
void      dk_player_select_track(DKPlayer* player, int track_type, int stream_index);
void      dk_player_load_external_subtitle(DKPlayer* player, const char* content_utf8, bool is_ass);
void      dk_player_set_subtitle_style(DKPlayer* player, const DKSubtitleStyleConfig* config);
void      dk_player_set_subtitle_viewport(
    DKPlayer* player,
    int32_t viewport_w,
    int32_t viewport_h,
    int32_t video_w,
    int32_t video_h,
    int32_t margin_top,
    int32_t margin_bottom,
    int32_t margin_left,
    int32_t margin_right
);
void      dk_player_select_secondary_subtitle_track(DKPlayer* player, int stream_index);
void      dk_player_load_secondary_external_subtitle(DKPlayer* player, const char* content_utf8, bool is_ass);
bool      dk_player_get_subtitle_vertical_bounds(DKPlayer* player, int32_t* out_y0, int32_t* out_y1, int32_t* out_canvas_h);
int32_t   dk_player_copy_recent_audio_16k(DKPlayer* player, float* out_pcm, int32_t max_samples, double* out_start_pts);
int32_t   dk_player_get_subtitle_intervals(DKPlayer* player, bool is_secondary, DKSubtitleInterval* out_intervals, int32_t max_count);
void      dk_player_set_secondary_subtitle_time_scale(DKPlayer* player, double scale);
double    dk_player_get_secondary_subtitle_time_scale(DKPlayer* player);

int       dk_player_get_chapter_count(DKPlayer* player);
bool      dk_player_get_chapter_info(DKPlayer* player, int ordinal, DKChapterInfo* out_info);

CVPixelBufferRef dk_player_acquire_frame(DKPlayer* player, double* out_pts, DKGpuColorUniforms* out_color);
void      dk_player_notify_metal_first_frame(DKPlayer* player);
void      dk_player_sync_subtitle_rgba(DKPlayer* player, double pts, int32_t canvas_w, int32_t canvas_h, uint64_t last_serial, DKSubtitleRgbaCallback callback, void* context);

DKPlayerState dk_player_get_state(DKPlayer* player);
double        dk_player_get_position(DKPlayer* player);
double        dk_player_get_duration(DKPlayer* player);
double        dk_player_get_buffered_duration(DKPlayer* player);
void          dk_player_get_stats(DKPlayer* player, DKRuntimeStats* out_stats);

CGImageRef    dk_extract_video_thumbnail(const char* file_path_or_url, double target_sec);

// Zero-dependency Rust Media Data Plane (2A: GlobalSlabPool, sparse DKChunkStore, AVIO bridge & download assembler)
typedef struct DKChunkStore DKChunkStore;
typedef struct DKStreamBridge DKStreamBridge;
typedef struct DKDownloadAssembler DKDownloadAssembler;

void          dk_net_set_memory_budget_bytes(int64_t max_bytes);
void          dk_net_update_playback_companion_state(
    int32_t active_count_delta,
    int32_t lead_cached_chunks,
    bool in_open_probe,
    bool recent_seek,
    bool recent_rescue,
    int64_t wire_speed_bps,
    int64_t stream_bitrate_bps
);
int64_t       dk_net_get_download_companion_rate_limit_bps(void);

DKChunkStore* dk_net_store_open(
    const char* asset_dir_utf8,
    int64_t total_size,
    int32_t chunk_size,
    bool persist_disk,
    bool pinned,
    const int32_t* legacy_seed,
    int32_t legacy_seed_count
);
void          dk_net_store_update_config(DKChunkStore* store, int64_t max_memory_bytes, bool persist_disk);
void          dk_net_store_set_pinned(DKChunkStore* store, bool pinned);
void          dk_net_store_set_total_size(DKChunkStore* store, int64_t total_size);
void          dk_net_store_retain_reader(DKChunkStore* store);
int32_t       dk_net_store_release_reader(DKChunkStore* store);
int32_t       dk_net_store_active_readers(DKChunkStore* store);
bool          dk_net_store_has_chunk(DKChunkStore* store, int32_t chunk_index);
void          dk_net_store_write_slice(DKChunkStore* store, int32_t chunk_index, const uint8_t* data, int32_t len, bool cache_in_l1);
int32_t       dk_net_store_read_bytes(DKChunkStore* store, int32_t chunk_index, int32_t offset_in_chunk, uint8_t* dst, int32_t count);
void          dk_net_store_get_progress(DKChunkStore* store, int64_t* out_cached_bytes, int64_t* out_total_bytes, bool* out_fully_cached);
int32_t       dk_net_store_copy_completed_indices(DKChunkStore* store, int32_t* out_indices, int32_t max_count);
void          dk_net_store_evict_behind_cursor(DKChunkStore* store, int32_t cursor_chunk, int32_t keep_back);
void          dk_net_store_evict_distant_chunks(DKChunkStore* store, int32_t center_chunk, int32_t keep_back, int32_t keep_ahead);
void          dk_net_store_trim_idle_keeping_pinned(DKChunkStore* store);
void          dk_net_store_invalidate_probe_chunks(DKChunkStore* store);
void          dk_net_store_flush(DKChunkStore* store);
void          dk_net_store_close_handles(DKChunkStore* store);
void          dk_net_store_invalidate_for_removal(DKChunkStore* store);
void          dk_net_store_release(DKChunkStore* store);

DKStreamBridge* dk_net_bridge_create(
    DKChunkStore* store,
    void* opaque,
    DKCustomIOReadCallback miss_read_cb,
    DKCustomIOSeekCallback seek_cb,
    DKCustomIOAbortCallback abort_cb,
    DKCustomIOCloseCallback close_cb
);
int64_t       dk_net_bridge_get_cursor(DKStreamBridge* bridge);
void          dk_net_bridge_set_cursor(DKStreamBridge* bridge, int64_t offset);
void          dk_net_bridge_set_in_open_probe(DKStreamBridge* bridge, bool in_probe);
void          dk_net_bridge_register_attempt(DKStreamBridge* bridge, uint64_t attempt_id, int32_t start_chunk, int32_t end_chunk_exclusive, int32_t initial_byte_skip, bool is_rescue);
void          dk_net_bridge_update_attempt_end(DKStreamBridge* bridge, uint64_t attempt_id, int32_t end_chunk_exclusive);
void          dk_net_bridge_remove_attempt(DKStreamBridge* bridge, uint64_t attempt_id);
int32_t       dk_net_bridge_attempt_buffered_bytes(DKStreamBridge* bridge, uint64_t attempt_id);
int32_t       dk_net_bridge_try_read_partial_or_direct(DKStreamBridge* bridge, int64_t current_offset, int32_t target_chunk, int32_t offset_in_chunk, uint8_t* dst, int32_t count);
bool          dk_net_bridge_flush_final_attempt(DKStreamBridge* bridge, uint64_t attempt_id, bool succeeded, int32_t* out_completed_chunk);
int32_t       dk_net_bridge_ingest_partial(DKStreamBridge* bridge, uint64_t attempt_id, const uint8_t* bytes, int32_t len, int32_t* out_completed_chunks, int32_t max_completed);
void          dk_net_bridge_ingest_direct(DKStreamBridge* bridge, int64_t start_offset, const uint8_t* bytes, int32_t len);
void          dk_net_bridge_clear_direct_slices(DKStreamBridge* bridge);
void          dk_net_bridge_release(DKStreamBridge* bridge);
void          dk_player_attach_stream_bridge(DKPlayer* player, DKStreamBridge* bridge);

DKDownloadAssembler* dk_net_assembler_create(DKChunkStore* store, int32_t start_chunk, int32_t end_chunk);
void          dk_net_assembler_update_end(DKDownloadAssembler* asm_ptr, int32_t end_chunk);
void          dk_net_assembler_ingest(DKDownloadAssembler* asm_ptr, const uint8_t* bytes, int32_t len, bool keep_in_l1, int32_t* out_committed_chunks, int64_t* out_committed_bytes, bool* out_hit_end);
void          dk_net_assembler_finish(DKDownloadAssembler* asm_ptr, bool keep_in_l1, int32_t* out_committed_chunks, int64_t* out_committed_bytes);
void          dk_net_assembler_destroy(DKDownloadAssembler* asm_ptr);

#ifdef __cplusplus
}
#endif
