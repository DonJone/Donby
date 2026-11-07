#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <CoreVideo/CoreVideo.h>

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
} DKRuntimeStats;

typedef struct {
    int32_t stream_index;
    int32_t channels;
    bool    is_selected;
    bool    is_default;
    char    codec[32];
    char    language[32];
    char    title[128];
} DKTrackInfo;

typedef struct {
    int32_t x;
    int32_t y;
    int32_t w;
    int32_t h;
    int32_t stride;
    const uint8_t* rgba_data;
} DKSubtitleBitmap;

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

DKPlayer* dk_player_create(void);
void      dk_player_destroy(DKPlayer* player);

int       dk_player_open(DKPlayer* player, const char* url, const char* headers_crlf, double start_sec, bool hw_decode);
void      dk_player_close(DKPlayer* player);
void      dk_player_play(DKPlayer* player);
void      dk_player_pause(DKPlayer* player);
void      dk_player_seek(DKPlayer* player, double target_sec, bool accurate);
void      dk_player_set_rate(DKPlayer* player, float rate);
void      dk_player_set_volume(DKPlayer* player, float volume, bool muted);

int       dk_player_get_track_count(DKPlayer* player, int track_type);
bool      dk_player_get_track_info(DKPlayer* player, int track_type, int ordinal, DKTrackInfo* out_info);
void      dk_player_select_track(DKPlayer* player, int track_type, int stream_index);
void      dk_player_load_external_subtitle(DKPlayer* player, const char* content_utf8, bool is_ass);

CVPixelBufferRef dk_player_acquire_frame_for_host_time(DKPlayer* player, double* out_pts);
CVPixelBufferRef dk_player_acquire_frame(DKPlayer* player, double* out_pts, DKGpuColorUniforms* out_color);
bool      dk_player_get_subtitle_overlay(DKPlayer* player, double pts, DKSubtitleBitmap* out_bitmap);
bool      dk_player_get_subtitle_rgba(DKPlayer* player, double pts, int32_t canvas_w, int32_t canvas_h, const uint8_t** out_rgba, int32_t* out_w, int32_t* out_h, uint64_t* out_serial);

DKPlayerState dk_player_get_state(DKPlayer* player);
double        dk_player_get_position(DKPlayer* player);
double        dk_player_get_duration(DKPlayer* player);
double        dk_player_get_buffered_duration(DKPlayer* player);
void          dk_player_get_stats(DKPlayer* player, DKRuntimeStats* out_stats);

#ifdef __cplusplus
}
#endif
