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
    int32_t x;
    int32_t y;
    int32_t w;
    int32_t h;
    int32_t stride;
    const uint8_t* rgba_data;
} DKSubtitleBitmap;

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
void      dk_player_select_track(DKPlayer* player, int track_type, int stream_index);

CVPixelBufferRef dk_player_acquire_frame_for_host_time(DKPlayer* player, double* out_pts);
bool      dk_player_get_subtitle_overlay(DKPlayer* player, double pts, DKSubtitleBitmap* out_bitmap);

DKPlayerState dk_player_get_state(DKPlayer* player);
double        dk_player_get_position(DKPlayer* player);
double        dk_player_get_duration(DKPlayer* player);
double        dk_player_get_buffered_duration(DKPlayer* player);
void          dk_player_get_stats(DKPlayer* player, DKRuntimeStats* out_stats);

#ifdef __cplusplus
}
#endif
