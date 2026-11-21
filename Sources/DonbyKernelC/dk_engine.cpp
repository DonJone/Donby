#include "donby_kernel.h"
#include <donby_rs.h>

#include <atomic>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <queue>
#include <deque>
#include <vector>
#include <string>
#include <cstring>
#include <cmath>
#include <chrono>
#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/time.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/pixdesc.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mastering_display_metadata.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <ass/ass.h>
}

#include <AudioToolbox/AudioToolbox.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <CoreFoundation/CoreFoundation.h>

static std::atomic<DKLogCallback> g_log_callback{nullptr};

void dk_set_log_callback(DKLogCallback callback) {
    g_log_callback.store(callback, std::memory_order_release);
}

static void dk_log(int level, const char* fmt, ...) {
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    DKLogCallback cb = g_log_callback.load(std::memory_order_acquire);
    if (cb) {
        cb(level, buf);
    }
}

static void dk_ffmpeg_log_callback(void* ptr, int level, const char* fmt, va_list vl) {
    if (level > AV_LOG_INFO) return;
    DKLogCallback cb = g_log_callback.load(std::memory_order_acquire);
    if (!cb) return;
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, vl);
    size_t len = strlen(buf);
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) {
        buf[len - 1] = '\0';
        len--;
    }
    if (len > 0) {
        int dk_lvl = (level <= AV_LOG_ERROR) ? 2 : (level <= AV_LOG_WARNING ? 1 : 0);
        cb(dk_lvl, buf);
    }
}

struct VideoFrameEntry {
    CVPixelBufferRef pixel_buffer{nullptr};
    double pts{0.0};
    DKGpuColorUniforms color{};
};

struct AudioChunk {
    std::vector<float> pcm; // Canonical interleaved stereo Float32 (L, R, L, R...)
    double pts{0.0};
    size_t read_offset{0};
};

struct PgsBitmapRect {
    int x{0};
    int y{0};
    int w{0};
    int h{0};
    std::vector<uint8_t> rgba; // Premultiplied RGBA8 (w * h * 4)
};

struct PgsCue {
    uint64_t id{0};
    double start_sec{0.0};
    double end_sec{0.0};
    int canvas_w{1920};
    int canvas_h{1080};
    std::vector<PgsBitmapRect> rects;
};

struct StoredAssEvent {
    long long start_ms{0};
    long long dur_ms{0};
    std::string raw_line;
    bool is_full_dialogue{false};
    bool is_forced{false};
};

static_assert(sizeof(DKGpuColorUniforms) == 3088, "DKGpuColorUniforms must match Metal constant layout (3088 bytes)");

struct DKPlayer {
    static constexpr int kNumAudioBuffers = 4;
    static constexpr UInt32 kAudioBufferSize = 8192; // 1024 frames = ~21.3ms per buffer

    std::atomic<DKPlayerState> state{DK_STATE_IDLE};
    std::string current_url;
    std::string current_headers;
    double duration_sec{0.0};
    std::atomic<double> current_pos_sec{0.0};
    std::atomic<float> playback_rate{1.0f};
    std::atomic<float> volume{1.0f};
    std::atomic<bool> is_muted{false};
    bool hw_decode_enabled{true};

    // FFmpeg context & Custom AVIO
    AVFormatContext* format_ctx{nullptr};
    AVIOContext* custom_avio_ctx{nullptr};
    void* custom_io_opaque{nullptr};
    DKCustomIOReadCallback custom_io_read{nullptr};
    DKCustomIOSeekCallback custom_io_seek{nullptr};
    DKCustomIOAbortCallback custom_io_abort{nullptr};
    DKCustomIOCloseCallback custom_io_close{nullptr};

    int video_stream_idx{-1};
    std::atomic<int> audio_stream_idx{-1};
    std::atomic<int> sub_stream_idx{-1};
    std::atomic<int> secondary_sub_stream_idx{-1};

    AVCodecContext* video_codec_ctx{nullptr};
    AVCodecContext* audio_codec_ctx{nullptr};
    AVCodecContext* sub_codec_ctx{nullptr};
    AVCodecContext* secondary_sub_codec_ctx{nullptr};
    AVBufferRef* hw_device_ctx{nullptr};
    SwrContext* swr_ctx{nullptr};
    SwsContext* sws_ctx{nullptr};
    std::mutex video_codec_mtx;
    std::mutex audio_codec_mtx;

    // Track active SwrContext input parameters for dynamic reconfiguration (TrueHD / DTS-HD / EAC3)
    enum AVSampleFormat swr_in_fmt{AV_SAMPLE_FMT_NONE};
    int swr_in_rate{0};
    int swr_in_channels{0};

    // Software decode IOSurface CVPixelBufferPool
    CVPixelBufferPoolRef sw_pool{nullptr};
    int sw_pool_w{0};
    int sw_pool_h{0};
    OSType sw_pool_ostype{0};
    std::atomic<bool> vt_failed{false};
    std::atomic<bool> dovi_detected{false};
    uint8_t stream_dovi_profile{0};

    // Demux / Seek / Interrupt
    std::atomic<bool> is_closing{false};
    std::atomic<int> in_flight_readers{0};
    std::atomic<bool> abort_requested{false};
    std::atomic<bool> external_abort_requested{false};
    std::atomic<bool> seek_requested{false};
    std::atomic<uint64_t> latest_seek_seq{0};
    std::atomic<uint64_t> executing_seek_seq{0};
    std::atomic<bool> seek_executing{false};
    std::atomic<double> seek_target_sec{0.0};
    std::atomic<bool> seek_accurate{false};
    std::atomic<double> video_seek_drop_until_pts{-1.0};
    std::atomic<double> audio_seek_drop_until_pts{-1.0};
    std::atomic<bool> seek_preview_pending{false};
    std::atomic<bool> force_present_next_frame{false};
    std::atomic<bool> demux_eof{false};
    std::mutex demux_mtx;
    std::condition_variable demux_cv;

    // Packet Queues
    std::mutex video_pkt_mtx;
    std::queue<AVPacket*> video_pkt_queue;
    std::condition_variable video_decode_cv;

    std::mutex audio_pkt_mtx;
    std::queue<AVPacket*> audio_pkt_queue;
    std::condition_variable audio_decode_cv;
    std::atomic<int64_t> queued_pkt_bytes{0};
    std::atomic<int64_t> max_buffer_bytes{256LL * 1024LL * 1024LL};
    std::atomic<double> last_demuxed_pts{0.0};

    // Decoded Video Frame Queue
    std::mutex video_queue_mtx;
    std::queue<VideoFrameEntry> video_queue;
    std::condition_variable video_frame_cv;
    CVPixelBufferRef last_frame{nullptr};
    double last_pts{0.0};
    DKGpuColorUniforms last_color{};
    double last_decoded_video_pts{-1.0};
    std::atomic<bool> video_eof{false};
    std::atomic<bool> audio_eof{false};

    // Decoded Audio & AudioToolbox Output
    AudioQueueRef audio_queue{nullptr};
    AudioQueueBufferRef audio_buffers[kNumAudioBuffers]{nullptr};
    std::mutex audio_queue_mtx;
    std::deque<AudioChunk> audio_chunks;
    std::atomic<int64_t> buffered_audio_samples{0};
    std::atomic<bool> audio_queue_started{false};
    std::atomic<bool> audio_queue_starting{false};
    std::atomic<uint32_t> audio_rebuffer_count{0};
    std::atomic<uint32_t> audio_start_fail_count{0};
    std::atomic<int64_t> last_audio_start_attempt_ns{0};
    std::atomic<int64_t> audio_steady_start_ns{0};
    std::atomic<bool> audio_hal_disabled{false};

    // Bounded recent subtitle packet ring buffer for instant zero-seek track switching
    std::mutex sub_hist_mtx;
    std::deque<AVPacket*> sub_pkt_history;
    size_t sub_hist_bytes{0};
    std::atomic<bool> sub_hist_trimmed{false};

    // Master Clock Synchronization
    std::atomic<double> audio_clock_base_pts{-1.0};
    std::atomic<int64_t> audio_clock_base_sample_time{0};
    std::atomic<int64_t> audio_underrun_samples{0};
    std::atomic<int64_t> audio_consecutive_underrun_samples{0};
    std::atomic<bool> audio_clock_calibrated{false};
    std::atomic<double> fallback_audio_clock{0.0};
    std::atomic<int64_t> fallback_clock_ns{0};

    std::atomic<double> ext_clock_base_pts{0.0};
    std::atomic<int64_t> ext_clock_start_ns{0};

    // Subtitle (libass)
    ASS_Library* ass_lib{nullptr};
    ASS_Renderer* ass_renderer{nullptr};
    ASS_Renderer* secondary_ass_renderer{nullptr};
    ASS_Track* ass_track{nullptr};
    ASS_Track* secondary_ass_track{nullptr};
    std::mutex ass_mtx;
    int ass_canvas_w{0};
    int ass_canvas_h{0};
    int sub_storage_w{1920};
    int sub_storage_h{1080};
    bool has_bitmap_subs{false};
    std::deque<PgsCue> pgs_cues;
    uint64_t pgs_generation{0};
    uint64_t rendered_pgs_gen{0};
    std::vector<uint8_t> sub_rgba_buf;
    uint64_t sub_serial{0};
    uint64_t sub_read_order{0};
    bool sub_last_non_empty{false};
    bool sub_style_dirty{false};
    int sub_dirty_y0{0};
    int sub_dirty_y1{0};
    DKSubtitleStyleConfig sub_style{1.0f, 2.8f, 92.0f, 0.0, 0.0, 0, false, false, true, true};
    struct OriginalAssStyle {
        std::string font_name;
        double font_size{56.0};
        double outline{2.8};
        int margin_v{46};
        uint32_t primary_colour{0xF5F5F500u};
        double scale_x{1.0};
        double scale_y{1.0};
        int alignment{2};
        int border_style{1};
    };
    const ASS_Track* primary_orig_track_ptr{nullptr};
    std::vector<OriginalAssStyle> primary_orig_styles;
    const ASS_Track* secondary_orig_track_ptr{nullptr};
    std::vector<OriginalAssStyle> secondary_orig_styles;
    std::string primary_codec_private;
    std::string secondary_codec_private;
    std::vector<StoredAssEvent> primary_ass_events;
    std::vector<StoredAssEvent> secondary_ass_events;
    std::string primary_ext_raw;
    bool primary_ext_is_ass{false};
    std::string secondary_ext_raw;
    bool secondary_ext_is_ass{false};

    // Worker Threads
    std::thread demux_thread;
    std::thread video_decode_thread;
    std::thread audio_decode_thread;

    // Runtime Stats
    std::mutex stats_mtx;
    DKRuntimeStats stats{};
    std::atomic<double> atomic_video_bitrate_mbps{0.0};

    // Download / Throughput Tracking
    std::mutex speed_mtx;
    std::atomic<int64_t> total_bytes_read{0};
    std::atomic<double> instant_download_speed_mbs{0.0};
    int64_t last_speed_bytes{0};
    std::chrono::steady_clock::time_point last_speed_time{std::chrono::steady_clock::now()};
};

static inline int64_t dk_steady_now_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()
    ).count();
}

static inline double dk_elapsed_since_ns(int64_t start_ns) {
    if (start_ns <= 0) return 0.0;
    int64_t diff = dk_steady_now_ns() - start_ns;
    return diff > 0 ? (static_cast<double>(diff) * 1e-9) : 0.0;
}

static std::mutex& dk_registry_mutex() {
    static std::mutex* mtx = new std::mutex();
    return *mtx;
}

static std::vector<DKPlayer*>& dk_live_players() {
    static std::vector<DKPlayer*>* vec = new std::vector<DKPlayer*>();
    return *vec;
}

struct DKReaderGuard {
    DKPlayer* player{nullptr};
    explicit DKReaderGuard(DKPlayer* p) {
        if (!p) return;
        std::lock_guard<std::mutex> lk(dk_registry_mutex());
        auto& vec = dk_live_players();
        if (std::find(vec.begin(), vec.end(), p) != vec.end() &&
            !p->is_closing.load(std::memory_order_acquire) &&
            !p->abort_requested.load(std::memory_order_acquire)) {
            p->in_flight_readers.fetch_add(1, std::memory_order_acq_rel);
            player = p;
        }
    }
    ~DKReaderGuard() {
        if (player) {
            player->in_flight_readers.fetch_sub(1, std::memory_order_acq_rel);
        }
    }
    explicit operator bool() const { return player != nullptr; }
};

// Interrupt callback to unblock network I/O immediately on close/abort
static int dk_interrupt_callback(void* opaque) {
    DKPlayer* player = static_cast<DKPlayer*>(opaque);
    if (!player) return 0;
    return (player->abort_requested.load() || player->is_closing.load()) ? 1 : 0;
}

static enum AVPixelFormat dk_get_hw_format(AVCodecContext* ctx, const enum AVPixelFormat* pix_fmts) {
    DKPlayer* player = ctx ? static_cast<DKPlayer*>(ctx->opaque) : nullptr;
    if (!player || !player->vt_failed.load(std::memory_order_relaxed)) {
        for (const enum AVPixelFormat* p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
            if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
                return *p;
            }
        }
    }
    for (const enum AVPixelFormat* p = pix_fmts; *p != -1; p++) {
        if (*p != AV_PIX_FMT_VIDEOTOOLBOX) {
            if (player) {
                std::lock_guard<std::mutex> lk(player->stats_mtx);
                player->stats.is_hw_accelerated = false;
            }
            return *p;
        }
    }
    return AV_PIX_FMT_NONE;
}

// Helper: PQ (SMPTE ST 2084) normalized [0..1] -> nits [0..10000]
static float dk_pq_norm_to_nits(double e) {
    if (e <= 0.0) return 0.0f;
    constexpr double m1 = 2610.0 / 16384.0;
    constexpr double m2 = (2523.0 / 4096.0) * 128.0;
    constexpr double c1 = 3424.0 / 4096.0;
    constexpr double c2 = (2413.0 / 4096.0) * 32.0;
    constexpr double c3 = (2392.0 / 4096.0) * 32.0;
    double ep = std::pow(e, 1.0 / m2);
    double num = std::max(ep - c1, 0.0);
    double den = std::max(c2 - c3 * ep, 1e-9);
    return static_cast<float>(10000.0 * std::pow(num / den, 1.0 / m1));
}

static void dk_set_default_sdr_uniforms(DKGpuColorUniforms& u) {
    std::memset(&u, 0, sizeof(u));
    u.transfer_fn = 0;
    u.primaries = 0;
    u.is_full_range = 0;
    u.bit_depth = 8;
    u.use_dovi_chain = 0;
    u.has_dovi_reshape = 0;
    u.source_peak_nits = 203.0f;
    u.edr_headroom = 1.0f;

    const float sy = 255.0f / 219.0f;
    const float sc = 255.0f / 224.0f;
    u.ycc_offset[0] = 16.0f / 255.0f;
    u.ycc_offset[1] = 128.0f / 255.0f;
    u.ycc_offset[2] = 128.0f / 255.0f;
    u.ycc_offset[3] = 1.0f;

    u.yuv_matrix_r0[0] = sy; u.yuv_matrix_r0[1] = 0.0f;              u.yuv_matrix_r0[2] = 1.5748f * sc;
    u.yuv_matrix_r1[0] = sy; u.yuv_matrix_r1[1] = -0.18732427f * sc; u.yuv_matrix_r1[2] = -0.46812427f * sc;
    u.yuv_matrix_r2[0] = sy; u.yuv_matrix_r2[1] = 1.8556f * sc;      u.yuv_matrix_r2[2] = 0.0f;

    u.lin_matrix_r0[0] = 1.0f;
    u.lin_matrix_r1[1] = 1.0f;
    u.lin_matrix_r2[2] = 1.0f;
}

static DKGpuColorUniforms dk_build_color_uniforms(DKPlayer* player, const AVFrame* frame, CVPixelBufferRef pixbuf) {
    DKGpuColorUniforms u{};
    dk_set_default_sdr_uniforms(u);
    if (!player || !frame) return u;

    AVStream* st = (player->format_ctx && player->video_stream_idx >= 0 &&
                    static_cast<unsigned>(player->video_stream_idx) < player->format_ctx->nb_streams)
                   ? player->format_ctx->streams[player->video_stream_idx]
                   : nullptr;

    OSType pf = pixbuf ? CVPixelBufferGetPixelFormatType(pixbuf) : 0;
    bool is_10bit_pixbuf = (pf == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                            pf == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
                            pf == 0x78343230 || pf == 0x78663230 || pf == 0x70303130);
    u.bit_depth = is_10bit_pixbuf ? 10 : 8;

    AVRational sar = frame->sample_aspect_ratio;
    if ((sar.num <= 0 || sar.den <= 0) && st) {
        sar = st->sample_aspect_ratio;
        if (sar.num <= 0 || sar.den <= 0) sar = st->codecpar->sample_aspect_ratio;
    }
    float sar_f = (sar.num > 0 && sar.den > 0) ? static_cast<float>(av_q2d(sar)) : 1.0f;
    if (!std::isfinite(sar_f) || sar_f <= 0.05f || sar_f > 10.0f) sar_f = 1.0f;

    AVColorTransferCharacteristic trc = frame->color_trc;
    if (trc == AVCOL_TRC_UNSPECIFIED && st) trc = st->codecpar->color_trc;

    AVColorPrimaries pri = frame->color_primaries;
    if (pri == AVCOL_PRI_UNSPECIFIED && st) pri = st->codecpar->color_primaries;

    AVColorSpace csp = frame->colorspace;
    if (csp == AVCOL_SPC_UNSPECIFIED && st) csp = st->codecpar->color_space;

    AVColorRange rng = frame->color_range;
    if (rng == AVCOL_RANGE_UNSPECIFIED && st) rng = st->codecpar->color_range;

    if (pixbuf && trc == AVCOL_TRC_UNSPECIFIED) {
        CFTypeRef tf = CVBufferCopyAttachment(pixbuf, kCVImageBufferTransferFunctionKey, nullptr);
        if (tf) {
            if (CFGetTypeID(tf) == CFStringGetTypeID()) {
                CFStringRef s = static_cast<CFStringRef>(tf);
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
    u.is_full_range = full_range ? 1 : 0;

    if (trc == AVCOL_TRC_SMPTE2084) {
        u.transfer_fn = 1;
        u.source_peak_nits = 1000.0f;
        if (!player->stats.is_hdr) {
            std::lock_guard<std::mutex> lk(player->stats_mtx);
            player->stats.is_hdr = true;
            if (!player->stats.is_dolby_vision) {
                std::snprintf(player->stats.color_space, sizeof(player->stats.color_space), "BT.2020 PQ (HDR10)");
            }
        }
    } else if (trc == AVCOL_TRC_ARIB_STD_B67) {
        u.transfer_fn = 2;
        u.source_peak_nits = 1000.0f;
        if (!player->stats.is_hdr) {
            std::lock_guard<std::mutex> lk(player->stats_mtx);
            player->stats.is_hdr = true;
            if (!player->stats.is_dolby_vision) {
                std::snprintf(player->stats.color_space, sizeof(player->stats.color_space), "BT.2020 HLG");
            }
        }
    } else {
        u.transfer_fn = 0;
        u.source_peak_nits = 203.0f;
    }

    if (pri == AVCOL_PRI_BT2020) {
        u.primaries = 1;
    } else if (pri == AVCOL_PRI_SMPTE432 || pri == AVCOL_PRI_SMPTE431) {
        u.primaries = 2;
    } else {
        u.primaries = (u.transfer_fn != 0) ? 1 : 0;
    }

    float off_y = 0.0f, off_c = 0.5f, sy = 1.0f, sc = 1.0f;
    if (u.bit_depth >= 10) {
        if (full_range) {
            off_y = 0.0f;
            off_c = 512.0f / 1024.0f;
            sy = 1024.0f / 1023.0f;
            sc = 1024.0f / 1023.0f;
        } else {
            off_y = 64.0f / 1024.0f;
            off_c = 512.0f / 1024.0f;
            sy = 1024.0f / 876.0f;
            sc = 1024.0f / 896.0f;
        }
    } else {
        if (full_range) {
            off_y = 0.0f;
            off_c = 128.0f / 255.0f;
            sy = 1.0f;
            sc = 1.0f;
        } else {
            off_y = 16.0f / 255.0f;
            off_c = 128.0f / 255.0f;
            sy = 255.0f / 219.0f;
            sc = 255.0f / 224.0f;
        }
    }
    u.ycc_offset[0] = off_y;
    u.ycc_offset[1] = off_c;
    u.ycc_offset[2] = off_c;
    u.ycc_offset[3] = sar_f;

    bool use_2020_mtx = (csp == AVCOL_SPC_BT2020_NCL || csp == AVCOL_SPC_BT2020_CL ||
                         (csp == AVCOL_SPC_UNSPECIFIED && u.primaries == 1));
    bool use_601_mtx = (csp == AVCOL_SPC_BT470BG || csp == AVCOL_SPC_SMPTE170M ||
                        (csp == AVCOL_SPC_UNSPECIFIED && u.primaries == 0 && frame->height > 0 && frame->height <= 576));

    if (use_2020_mtx) {
        u.yuv_matrix_r0[0] = sy; u.yuv_matrix_r0[1] = 0.0f;              u.yuv_matrix_r0[2] = 1.4746f * sc;
        u.yuv_matrix_r1[0] = sy; u.yuv_matrix_r1[1] = -0.16455313f * sc; u.yuv_matrix_r1[2] = -0.57135313f * sc;
        u.yuv_matrix_r2[0] = sy; u.yuv_matrix_r2[1] = 1.8814f * sc;      u.yuv_matrix_r2[2] = 0.0f;
    } else if (use_601_mtx) {
        u.yuv_matrix_r0[0] = sy; u.yuv_matrix_r0[1] = 0.0f;              u.yuv_matrix_r0[2] = 1.402f * sc;
        u.yuv_matrix_r1[0] = sy; u.yuv_matrix_r1[1] = -0.34413629f * sc; u.yuv_matrix_r1[2] = -0.71413629f * sc;
        u.yuv_matrix_r2[0] = sy; u.yuv_matrix_r2[1] = 1.772f * sc;       u.yuv_matrix_r2[2] = 0.0f;
    } else {
        u.yuv_matrix_r0[0] = sy; u.yuv_matrix_r0[1] = 0.0f;              u.yuv_matrix_r0[2] = 1.5748f * sc;
        u.yuv_matrix_r1[0] = sy; u.yuv_matrix_r1[1] = -0.18732427f * sc; u.yuv_matrix_r1[2] = -0.46812427f * sc;
        u.yuv_matrix_r2[0] = sy; u.yuv_matrix_r2[1] = 1.8556f * sc;      u.yuv_matrix_r2[2] = 0.0f;
    }

    if (const AVFrameSideData* mdm_sd = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA)) {
        const auto* mdm = reinterpret_cast<const AVMasteringDisplayMetadata*>(mdm_sd->data);
        if (mdm && mdm->has_luminance) {
            double max_l = av_q2d(mdm->max_luminance);
            if (max_l >= 100.0 && max_l <= 10000.0) {
                u.source_peak_nits = static_cast<float>(max_l);
            }
        }
    }
    if (const AVFrameSideData* cll_sd = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL)) {
        const auto* cll = reinterpret_cast<const AVContentLightMetadata*>(cll_sd->data);
        if (cll && cll->MaxCLL >= 150 && cll->MaxCLL <= 10000) {
            u.source_peak_nits = static_cast<float>(cll->MaxCLL);
        }
    }

    const AVFrameSideData* dovi_sd = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
    if (dovi_sd && dovi_sd->data) {
        const auto* dovi = reinterpret_cast<const AVDOVIMetadata*>(dovi_sd->data);
        const AVDOVIRpuDataHeader* hdr = av_dovi_get_header(dovi);
        const AVDOVIDataMapping* mapping = av_dovi_get_mapping(dovi);
        const AVDOVIColorMetadata* color = av_dovi_get_color(dovi);

        {
            std::lock_guard<std::mutex> lk(player->stats_mtx);
            player->stats.is_dolby_vision = true;
            player->stats.is_hdr = true;
            if (player->stream_dovi_profile == 5) {
                std::snprintf(player->stats.color_space, sizeof(player->stats.color_space), "Dolby Vision P5");
            } else {
                std::snprintf(player->stats.color_space, sizeof(player->stats.color_space), "Dolby Vision P8");
            }
        }

        if (color) {
            double m00 = av_q2d(color->ycc_to_rgb_matrix[0]);
            if (std::fabs(m00) > 0.01 && (player->stream_dovi_profile == 5 || u.transfer_fn == 1)) {
                u.use_dovi_chain = 1;
                u.transfer_fn = 1;
                u.primaries = 1;

                u.ycc_offset[0] = static_cast<float>(av_q2d(color->ycc_to_rgb_offset[0]));
                u.ycc_offset[1] = static_cast<float>(av_q2d(color->ycc_to_rgb_offset[1]));
                u.ycc_offset[2] = static_cast<float>(av_q2d(color->ycc_to_rgb_offset[2]));
                u.ycc_offset[3] = sar_f;

                u.yuv_matrix_r0[0] = static_cast<float>(av_q2d(color->ycc_to_rgb_matrix[0]));
                u.yuv_matrix_r0[1] = static_cast<float>(av_q2d(color->ycc_to_rgb_matrix[1]));
                u.yuv_matrix_r0[2] = static_cast<float>(av_q2d(color->ycc_to_rgb_matrix[2]));
                u.yuv_matrix_r1[0] = static_cast<float>(av_q2d(color->ycc_to_rgb_matrix[3]));
                u.yuv_matrix_r1[1] = static_cast<float>(av_q2d(color->ycc_to_rgb_matrix[4]));
                u.yuv_matrix_r1[2] = static_cast<float>(av_q2d(color->ycc_to_rgb_matrix[5]));
                u.yuv_matrix_r2[0] = static_cast<float>(av_q2d(color->ycc_to_rgb_matrix[6]));
                u.yuv_matrix_r2[1] = static_cast<float>(av_q2d(color->ycc_to_rgb_matrix[7]));
                u.yuv_matrix_r2[2] = static_cast<float>(av_q2d(color->ycc_to_rgb_matrix[8]));

                constexpr double hpe_lms2rgb[3][3] = {
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
                double combined[3][3]{};
                for (int r = 0; r < 3; r++) {
                    for (int c = 0; c < 3; c++) {
                        combined[r][c] = hpe_lms2rgb[r][0] * r2l[0][c] +
                                         hpe_lms2rgb[r][1] * r2l[1][c] +
                                         hpe_lms2rgb[r][2] * r2l[2][c];
                    }
                }
                for (int c = 0; c < 3; c++) {
                    u.lin_matrix_r0[c] = static_cast<float>(combined[0][c]);
                    u.lin_matrix_r1[c] = static_cast<float>(combined[1][c]);
                    u.lin_matrix_r2[c] = static_cast<float>(combined[2][c]);
                }
            }

            if (color->source_max_pq > 0) {
                float src_nits = dk_pq_norm_to_nits(static_cast<double>(color->source_max_pq) / 4095.0);
                if (src_nits >= 150.0f && src_nits <= 10000.0f) {
                    if (u.source_peak_nits >= 999.0f || src_nits < u.source_peak_nits) {
                        u.source_peak_nits = src_nits;
                    }
                }
            }
        }

        if (const AVDOVIDmData* l6 = av_dovi_find_level(dovi, 6)) {
            if (l6->l6.max_cll >= 150 && l6->l6.max_cll <= 10000) {
                u.source_peak_nits = static_cast<float>(l6->l6.max_cll);
            } else if (l6->l6.max_luminance >= 150 && l6->l6.max_luminance <= 10000 && u.source_peak_nits >= 999.0f) {
                u.source_peak_nits = static_cast<float>(l6->l6.max_luminance);
            }
        }

        if (hdr && mapping && hdr->coef_log2_denom > 0 && hdr->coef_log2_denom <= 31) {
            const double denom = static_cast<double>(1ULL << hdr->coef_log2_denom);
            const int bl_bits = (hdr->bl_bit_depth >= 8 && hdr->bl_bit_depth <= 16) ? hdr->bl_bit_depth : 10;
            const double pivot_norm = static_cast<double>(1 << bl_bits);
            bool any_non_identity = false;

            for (int ch = 0; ch < 3; ch++) {
                const AVDOVIReshapingCurve& curve = mapping->curves[ch];
                int npiv = std::clamp<int>(curve.num_pivots, 0, 9);
                int npieces = std::max(0, npiv - 1);
                u.reshape_pieces[ch] = npieces;
                for (int p = 0; p < npiv; p++) {
                    float pv = static_cast<float>(curve.pivots[p] / pivot_norm);
                    if (p == npiv - 1 && pv > 0.998f) pv = 1.0f;
                    u.reshape_pivots[ch * 12 + p] = pv;
                }
                for (int pc = 0; pc < npieces && pc < 8; pc++) {
                    float c0 = 0.0f, c1 = 1.0f, c2 = 0.0f;
                    int piece_idx = ch * 8 + pc;
                    if (curve.mapping_idc[pc] == AV_DOVI_MAPPING_POLYNOMIAL) {
                        u.reshape_mmr_meta[piece_idx] = 0;
                        c0 = static_cast<float>(static_cast<double>(curve.poly_coef[pc][0]) / denom);
                        c1 = (curve.poly_order[pc] >= 1) ? static_cast<float>(static_cast<double>(curve.poly_coef[pc][1]) / denom) : 0.0f;
                        c2 = (curve.poly_order[pc] >= 2) ? static_cast<float>(static_cast<double>(curve.poly_coef[pc][2]) / denom) : 0.0f;
                        if (std::fabs(c0) > 1e-4f || std::fabs(c1 - 1.0f) > 1e-4f || std::fabs(c2) > 1e-4f) {
                            any_non_identity = true;
                        }
                    } else if (curve.mapping_idc[pc] == AV_DOVI_MAPPING_MMR) {
                        int order = std::clamp<int>(curve.mmr_order[pc], 1, 3);
                        u.reshape_mmr_meta[piece_idx] = order;
                        int mbase = piece_idx * 24;
                        u.reshape_mmr_coeffs[mbase + 0] = static_cast<float>(static_cast<double>(curve.mmr_constant[pc]) / denom);
                        for (int ord = 0; ord < order; ord++) {
                            for (int t = 0; t < 7; t++) {
                                u.reshape_mmr_coeffs[mbase + 1 + ord * 7 + t] =
                                    static_cast<float>(static_cast<double>(curve.mmr_coef[pc][ord][t]) / denom);
                            }
                        }
                        any_non_identity = true;
                    }
                    int base = piece_idx * 4;
                    u.reshape_coeffs[base + 0] = c0;
                    u.reshape_coeffs[base + 1] = c1;
                    u.reshape_coeffs[base + 2] = c2;
                    u.reshape_coeffs[base + 3] = 0.0f;
                }
            }
            u.has_dovi_reshape = any_non_identity ? 1 : 0;
        }
    } else if (player->stream_dovi_profile == 5 && u.use_dovi_chain == 0) {
        u.use_dovi_chain = 1;
        u.transfer_fn = 1;
        u.primaries = 1;
        u.ycc_offset[0] = 0.0f; u.ycc_offset[1] = 0.5f; u.ycc_offset[2] = 0.5f; u.ycc_offset[3] = sar_f;
        u.yuv_matrix_r0[0] = 1.0f; u.yuv_matrix_r0[1] =  0.0975689f; u.yuv_matrix_r0[2] =  0.2052264f;
        u.yuv_matrix_r1[0] = 1.0f; u.yuv_matrix_r1[1] = -0.1138765f; u.yuv_matrix_r1[2] =  0.1332172f;
        u.yuv_matrix_r2[0] = 1.0f; u.yuv_matrix_r2[1] =  0.0326151f; u.yuv_matrix_r2[2] = -0.6768872f;
        u.lin_matrix_r0[0] =  3.0644188f; u.lin_matrix_r0[1] = -2.1659768f; u.lin_matrix_r0[2] =  0.1015582f;
        u.lin_matrix_r1[0] = -0.6561211f; u.lin_matrix_r1[1] =  1.7855412f; u.lin_matrix_r1[2] = -0.1294375f;
        u.lin_matrix_r2[0] =  0.0173632f; u.lin_matrix_r2[1] = -0.0472515f; u.lin_matrix_r2[2] =  1.0300425f;
    }

    return u;
}

static bool dk_ensure_sw_pixel_buffer_pool(DKPlayer* player, int width, int height, OSType pix_fmt) {
    if (player->sw_pool && player->sw_pool_w == width && player->sw_pool_h == height && player->sw_pool_ostype == pix_fmt) {
        return true;
    }
    if (player->sw_pool) {
        CVPixelBufferPoolRelease(player->sw_pool);
        player->sw_pool = nullptr;
    }

    CFMutableDictionaryRef io_attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
    CFMutableDictionaryRef pb_attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
    CFNumberRef w_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &width);
    CFNumberRef h_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &height);
    int32_t fmt_i32 = static_cast<int32_t>(pix_fmt);
    CFNumberRef fmt_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &fmt_i32);

    CFDictionarySetValue(pb_attrs, kCVPixelBufferWidthKey, w_num);
    CFDictionarySetValue(pb_attrs, kCVPixelBufferHeightKey, h_num);
    CFDictionarySetValue(pb_attrs, kCVPixelBufferPixelFormatTypeKey, fmt_num);
    CFDictionarySetValue(pb_attrs, kCVPixelBufferIOSurfacePropertiesKey, io_attrs);
    CFDictionarySetValue(pb_attrs, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);

    CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr, pb_attrs, &player->sw_pool);

    CFRelease(fmt_num);
    CFRelease(h_num);
    CFRelease(w_num);
    CFRelease(pb_attrs);
    CFRelease(io_attrs);

    if (status != kCVReturnSuccess || !player->sw_pool) {
        player->sw_pool = nullptr;
        return false;
    }
    player->sw_pool_w = width;
    player->sw_pool_h = height;
    player->sw_pool_ostype = pix_fmt;
    return true;
}

// Convert software AVFrame to IOSurface-backed Metal-compatible NV12 (8-bit) or P010 (10-bit+) CVPixelBuffer
static CVPixelBufferRef dk_convert_software_frame_to_cvpixelbuffer(DKPlayer* player, AVFrame* frame) {
    int width = frame->width;
    int height = frame->height;
    if (width <= 0 || height <= 0) return nullptr;

    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(static_cast<AVPixelFormat>(frame->format));
    bool is_high_depth = (desc && desc->comp[0].depth > 8);
    AVPixelFormat dst_av_fmt = is_high_depth ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
    OSType dst_cv_fmt = is_high_depth
        ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

    player->sws_ctx = sws_getCachedContext(
        player->sws_ctx,
        width, height, static_cast<AVPixelFormat>(frame->format),
        width, height, dst_av_fmt,
        SWS_BILINEAR, nullptr, nullptr, nullptr
    );
    if (!player->sws_ctx) return nullptr;
    if (!dk_ensure_sw_pixel_buffer_pool(player, width, height, dst_cv_fmt)) return nullptr;

    CVPixelBufferRef pixbuf = nullptr;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, player->sw_pool, &pixbuf);
    if (status != kCVReturnSuccess || !pixbuf) {
        return nullptr;
    }

    CVPixelBufferLockBaseAddress(pixbuf, 0);

    uint8_t* dst_data[4] = { nullptr };
    int dst_linesize[4] = { 0 };

    dst_data[0] = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixbuf, 0));
    dst_linesize[0] = static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 0));

    dst_data[1] = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixbuf, 1));
    dst_linesize[1] = static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 1));

    sws_scale(
        player->sws_ctx,
        frame->data,
        frame->linesize,
        0,
        height,
        dst_data,
        dst_linesize
    );

    CVPixelBufferUnlockBaseAddress(pixbuf, 0);
    return pixbuf;
}

// Helper to fill an AudioQueueBuffer from queued PCM samples
static void dk_fill_audio_buffer(DKPlayer* player, AudioQueueBufferRef inBuffer) {
    float* dst = reinterpret_cast<float*>(inBuffer->mAudioData);
    size_t needed_floats = inBuffer->mAudioDataBytesCapacity / sizeof(float);
    size_t filled_floats = 0;

    std::lock_guard<std::mutex> lock(player->audio_queue_mtx);
    while (filled_floats < needed_floats && !player->audio_chunks.empty()) {
        auto& front = player->audio_chunks.front();
        size_t available = front.pcm.size() - front.read_offset;
        size_t to_copy = std::min(needed_floats - filled_floats, available);

        std::memcpy(dst + filled_floats, front.pcm.data() + front.read_offset, to_copy * sizeof(float));
        filled_floats += to_copy;
        front.read_offset += to_copy;

        if (front.read_offset >= front.pcm.size()) {
            player->buffered_audio_samples.fetch_sub(front.pcm.size() / 2);
            player->audio_chunks.pop_front();
        }
    }

    if (filled_floats < needed_floats) {
        std::memset(dst + filled_floats, 0, (needed_floats - filled_floats) * sizeof(float));
        if (player->audio_clock_calibrated.load(std::memory_order_relaxed) &&
            !player->audio_eof.load(std::memory_order_relaxed)) {
            int64_t silence_samples = static_cast<int64_t>((needed_floats - filled_floats) / 2);
            player->audio_underrun_samples.fetch_add(silence_samples, std::memory_order_relaxed);
            player->audio_consecutive_underrun_samples.fetch_add(silence_samples, std::memory_order_relaxed);
        }
    } else {
        player->audio_consecutive_underrun_samples.store(0, std::memory_order_relaxed);
    }

    inBuffer->mAudioDataByteSize = inBuffer->mAudioDataBytesCapacity;
}

// macOS AudioQueue callback - invoked when an AudioQueue buffer finishes playing
static void dk_audio_queue_callback(void* custom_data, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    DKPlayer* player = static_cast<DKPlayer*>(custom_data);
    if (!player || player->abort_requested.load() || player->is_closing.load()) return;

    dk_fill_audio_buffer(player, inBuffer);
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nullptr);
    player->audio_decode_cv.notify_one();
}

// Master audio presentation clock based on AudioQueueGetCurrentTime hardware sample counter
static double dk_get_audio_clock(DKPlayer* player) {
    if (!player || player->abort_requested.load() || player->is_closing.load() || !player->audio_queue) {
        return player ? player->current_pos_sec.load() : 0.0;
    }

    if (!player->audio_queue_started.load()) {
        return player->audio_clock_base_pts.load() >= 0.0 ? player->audio_clock_base_pts.load() : player->current_pos_sec.load();
    }

    AudioTimeStamp ts{};
    OSStatus err = AudioQueueGetCurrentTime(player->audio_queue, nullptr, &ts, nullptr);
    if (err == noErr && (ts.mFlags & kAudioTimeStampSampleTimeValid)) {
        if (!player->audio_clock_calibrated.load()) {
            player->audio_clock_base_sample_time.store(static_cast<int64_t>(ts.mSampleTime));
            player->audio_underrun_samples.store(0);
            player->audio_clock_calibrated.store(true);
            dk_log(0, "DKEngine: Master audio clock calibrated at hardware sample %lld (base PTS: %.3fs)",
                   static_cast<long long>(ts.mSampleTime), player->audio_clock_base_pts.load());
        }
        int64_t sample_diff = static_cast<int64_t>(ts.mSampleTime) - player->audio_clock_base_sample_time.load();
        sample_diff -= player->audio_underrun_samples.load(std::memory_order_relaxed);
        if (sample_diff < 0) sample_diff = 0;
        double clock = player->audio_clock_base_pts.load() + (static_cast<double>(sample_diff) / 48000.0);
        player->fallback_audio_clock.store(clock);
        player->fallback_clock_ns.store(dk_steady_now_ns(), std::memory_order_relaxed);
        return clock;
    }

    if (player->state.load() == DK_STATE_PLAYING && player->audio_clock_calibrated.load()) {
        double elapsed = dk_elapsed_since_ns(player->fallback_clock_ns.load(std::memory_order_relaxed)) * player->playback_rate.load();
        return player->fallback_audio_clock.load() + elapsed;
    }
    double base_pts = player->audio_clock_base_pts.load();
    return (base_pts >= 0.0) ? base_pts : player->fallback_audio_clock.load();
}

// Master A/V synchronization clock
static double dk_get_master_clock(DKPlayer* player) {
    if (!player || player->abort_requested.load() || player->is_closing.load()) return 0.0;
    if (player->seek_requested.load(std::memory_order_acquire) || player->seek_executing.load(std::memory_order_acquire)) {
        return player->seek_target_sec.load(std::memory_order_relaxed);
    }
    if (player->audio_stream_idx >= 0 && player->audio_queue != nullptr && !player->audio_hal_disabled.load(std::memory_order_acquire)) {
        return dk_get_audio_clock(player);
    }
    // Fallback: System monotonic clock when no audio track exists
    if (player->state.load() == DK_STATE_PLAYING) {
        double elapsed = dk_elapsed_since_ns(player->ext_clock_start_ns.load(std::memory_order_relaxed)) * player->playback_rate.load();
        return player->ext_clock_base_pts.load() + elapsed;
    }
    return player->ext_clock_base_pts.load();
}

// Resampler configuration (48000 Hz stereo Float32 with cinema 5.1/7.1 center dialogue clarity)
static bool dk_setup_swr_from_params(DKPlayer* player, const AVChannelLayout* src_ch_layout, enum AVSampleFormat src_fmt, int src_rate) {
    if (!player || !player->audio_codec_ctx) return false;
    if (player->swr_ctx) {
        swr_free(&player->swr_ctx);
    }

    AVChannelLayout out_layout;
    av_channel_layout_default(&out_layout, 2);

    AVChannelLayout in_layout{};
    if (src_ch_layout && src_ch_layout->nb_channels > 0) {
        av_channel_layout_copy(&in_layout, src_ch_layout);
    } else if (player->audio_codec_ctx->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&in_layout, &player->audio_codec_ctx->ch_layout);
    } else {
        av_channel_layout_default(&in_layout, 2);
    }

    int in_sample_rate = src_rate > 0 ? src_rate : (player->audio_codec_ctx->sample_rate > 0 ? player->audio_codec_ctx->sample_rate : 48000);
    enum AVSampleFormat in_fmt = src_fmt != AV_SAMPLE_FMT_NONE ? src_fmt : (player->audio_codec_ctx->sample_fmt != AV_SAMPLE_FMT_NONE ? player->audio_codec_ctx->sample_fmt : AV_SAMPLE_FMT_FLTP);
    int in_channels = in_layout.nb_channels;

    int ret = swr_alloc_set_opts2(
        &player->swr_ctx,
        &out_layout,
        AV_SAMPLE_FMT_FLT,
        48000,
        &in_layout,
        in_fmt,
        in_sample_rate,
        0, nullptr
    );

    av_channel_layout_uninit(&out_layout);
    av_channel_layout_uninit(&in_layout);

    if (ret < 0 || !player->swr_ctx) {
        return false;
    }

    if (in_channels > 2) {
        av_opt_set_double(player->swr_ctx, "clev", 0.78, 0);
        av_opt_set_double(player->swr_ctx, "slev", 0.707, 0);
        av_opt_set_double(player->swr_ctx, "lfe_mix_level", 0.20, 0);
    }

    if (swr_init(player->swr_ctx) < 0) {
        swr_free(&player->swr_ctx);
        return false;
    }
    player->swr_in_fmt = in_fmt;
    player->swr_in_rate = in_sample_rate;
    player->swr_in_channels = in_channels;
    return true;
}

static bool dk_setup_swr(DKPlayer* player) {
    if (!player || !player->audio_codec_ctx) return false;
    return dk_setup_swr_from_params(
        player,
        &player->audio_codec_ctx->ch_layout,
        player->audio_codec_ctx->sample_fmt,
        player->audio_codec_ctx->sample_rate
    );
}

// AudioQueue initialization
static bool dk_init_audio_queue(DKPlayer* player) {
    if (!player) return false;

    AudioStreamBasicDescription asbd{};
    asbd.mSampleRate = 48000.0;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = 8;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = 8;
    asbd.mChannelsPerFrame = 2;
    asbd.mBitsPerChannel = 32;

    OSStatus status = AudioQueueNewOutput(
        &asbd,
        dk_audio_queue_callback,
        player,
        nullptr,
        nullptr,
        0,
        &player->audio_queue
    );
    if (status != noErr) {
        return false;
    }

    UInt32 timePitch = 1;
    AudioQueueSetProperty(player->audio_queue, kAudioQueueProperty_EnableTimePitch, &timePitch, sizeof(timePitch));
    AudioQueueSetParameter(player->audio_queue, kAudioQueueParam_PlayRate, player->playback_rate.load());

    const char* muted_env = std::getenv("DONBY_TEST_MUTED");
    const bool env_muted = (muted_env && (muted_env[0] == '1' || muted_env[0] == 't' || muted_env[0] == 'T'));
    float vol = (player->is_muted.load() || env_muted) ? 0.0f : player->volume.load();
    AudioQueueSetParameter(player->audio_queue, kAudioQueueParam_Volume, vol);

    for (int i = 0; i < DKPlayer::kNumAudioBuffers; i++) {
        AudioQueueAllocateBuffer(player->audio_queue, DKPlayer::kAudioBufferSize, &player->audio_buffers[i]);
    }

    return true;
}

static inline bool dk_is_seeking(const DKPlayer* player) {
    return player && (player->seek_requested.load(std::memory_order_acquire) ||
                      player->seek_executing.load(std::memory_order_acquire));
}

// Start audio queue when sufficient initial audio samples are decoded
static void dk_start_audio_queue_with_buffered_data(DKPlayer* player) {
    if (!player || player->abort_requested.load() || player->is_closing.load() ||
        !player->audio_queue || player->audio_hal_disabled.load(std::memory_order_acquire) ||
        player->audio_queue_started.load()) return;
    if (dk_is_seeking(player)) return;

    bool expected_starting = false;
    if (!player->audio_queue_starting.compare_exchange_strong(expected_starting, true, std::memory_order_acq_rel)) {
        return;
    }
    struct AudioStartingGuard {
        std::atomic<bool>& flag;
        explicit AudioStartingGuard(std::atomic<bool>& f) : flag(f) {}
        ~AudioStartingGuard() { flag.store(false, std::memory_order_release); }
    } starting_guard(player->audio_queue_starting);

    int64_t now_ns = dk_steady_now_ns();
    int64_t prev_attempt_ns = player->last_audio_start_attempt_ns.load(std::memory_order_relaxed);
    if (player->audio_start_fail_count.load(std::memory_order_relaxed) > 0 && prev_attempt_ns > 0 &&
        (now_ns - prev_attempt_ns) < 80'000'000LL) {
        return;
    }
    player->last_audio_start_attempt_ns.store(now_ns, std::memory_order_relaxed);

    double first_v_pts = -1.0;
    {
        std::lock_guard<std::mutex> vlk(player->video_queue_mtx);
        if (!player->video_queue.empty()) {
            first_v_pts = player->video_queue.front().pts;
        }
    }

    double base_pts = -1.0;
    {
        std::lock_guard<std::mutex> lock(player->audio_queue_mtx);
        if (player->audio_queue_started.load() || player->audio_chunks.empty()) return;
        // Align leading audio to first decodable video keyframe (e.g. HEVC open-GOP skipped frames)
        // so video never freezes waiting for audio to catch up on startup or seek.
        if (first_v_pts >= 0.0 && player->audio_chunks.front().pts < first_v_pts - 0.04) {
            int64_t cur_samples = player->buffered_audio_samples.load(std::memory_order_relaxed);
            while (player->audio_chunks.size() > 1 && cur_samples > 12000) {
                const auto& front = player->audio_chunks.front();
                const int64_t chunk_samples = static_cast<int64_t>((front.pcm.size() - front.read_offset) / 2);
                const double chunk_end = front.pts + static_cast<double>(chunk_samples) / 48000.0;
                if (chunk_end >= first_v_pts - 0.015 || (cur_samples - chunk_samples) < 8000) {
                    break;
                }
                player->buffered_audio_samples.fetch_sub(chunk_samples);
                cur_samples -= chunk_samples;
                player->audio_chunks.pop_front();
            }
        }
        base_pts = player->audio_chunks.front().pts;
        player->audio_clock_base_pts.store(base_pts);
        player->fallback_audio_clock.store(base_pts);
        player->fallback_clock_ns.store(dk_steady_now_ns(), std::memory_order_relaxed);
        player->audio_clock_calibrated.store(false);
        player->audio_clock_base_sample_time.store(0);
        player->audio_underrun_samples.store(0);
        player->audio_consecutive_underrun_samples.store(0);
    }

    if (base_pts >= 0.0) {
        std::lock_guard<std::mutex> vlk(player->video_queue_mtx);
        while (player->video_queue.size() > 1 && player->video_queue.front().pts < base_pts - 0.03) {
            CVPixelBufferRelease(player->video_queue.front().pixel_buffer);
            player->video_queue.pop();
            player->video_frame_cv.notify_one();
        }
    }

    for (int i = 0; i < DKPlayer::kNumAudioBuffers; i++) {
        if (player->audio_buffers[i]) {
            dk_fill_audio_buffer(player, player->audio_buffers[i]);
            AudioQueueEnqueueBuffer(player->audio_queue, player->audio_buffers[i], 0, nullptr);
        }
    }

    if (player->state.load() == DK_STATE_PLAYING && !dk_is_seeking(player)) {
        AudioQueuePrime(player->audio_queue, 0, nullptr);
        OSStatus startStatus = AudioQueueStart(player->audio_queue, nullptr);
        if (startStatus == noErr) {
            if (dk_is_seeking(player) ||
                player->abort_requested.load() ||
                player->is_closing.load() ||
                player->state.load() != DK_STATE_PLAYING) {
                AudioQueueStop(player->audio_queue, true);
                AudioQueueReset(player->audio_queue);
                return;
            }
            player->audio_start_fail_count.store(0, std::memory_order_relaxed);
            player->audio_steady_start_ns.store(dk_steady_now_ns(), std::memory_order_relaxed);
            player->fallback_clock_ns.store(dk_steady_now_ns(), std::memory_order_relaxed);
            // Publish audio_queue_started ONLY after CoreAudio HAL prime + start actually return,
            // so first video frame presents in exact lockstep with zero 50-100ms HAL-prime freeze!
            player->audio_queue_started.store(true, std::memory_order_release);
            dk_log(0, "DKEngine: AudioQueue started smoothly (base PTS: %.3fs, rebuf=%u)",
                   player->audio_clock_base_pts.load(), player->audio_rebuffer_count.load(std::memory_order_relaxed));
        } else {
            player->audio_queue_started.store(false, std::memory_order_release);
            uint32_t fails = player->audio_start_fail_count.fetch_add(1, std::memory_order_relaxed) + 1;
            if (fails == 1 || fails == 6) {
                dk_log(2, "DKEngine Error: AudioQueueStart returned OSStatus %d (attempt %u)", static_cast<int>(startStatus), fails);
            }
            if (fails >= 6) {
                // CoreAudio HAL rejected AudioQueue repeatedly; switch seamlessly to monotonic clock so video never deadlocks
                player->audio_hal_disabled.store(true, std::memory_order_release);
                double fb_pts = std::max(0.0, player->current_pos_sec.load(std::memory_order_relaxed));
                player->ext_clock_base_pts.store(fb_pts, std::memory_order_relaxed);
                player->ext_clock_start_ns.store(dk_steady_now_ns(), std::memory_order_relaxed);
                dk_log(1, "DKEngine: Falling back to system presentation clock after repeated AudioQueueStart errors");
            }
        }
    } else {
        AudioQueueReset(player->audio_queue);
        player->audio_queue_started.store(false, std::memory_order_release);
    }
}

static int64_t dk_required_audio_preroll_samples(const DKPlayer* player) {
    uint32_t rebuf = player ? player->audio_rebuffer_count.load(std::memory_order_relaxed) : 0;
    if (rebuf == 0) return 24000;   // 0.50s crisp post-seek preroll fits inside a single 2 MiB playhead sprint
    if (rebuf == 1) return 84000;   // 1.75s buffer cushion after first underrun
    return 120000;                  // 2.50s anti-choppy cushion on repeated slow-CDN starvation
}

static void dk_try_start_audio_queue_if_ready(DKPlayer* player) {
    if (!player || player->abort_requested.load() || player->is_closing.load() ||
        !player->audio_queue || player->audio_hal_disabled.load(std::memory_order_acquire) ||
        player->audio_queue_started.load(std::memory_order_acquire) ||
        dk_is_seeking(player)) {
        return;
    }
    const int64_t buffered_samples = player->buffered_audio_samples.load(std::memory_order_relaxed);
    const bool eof_reached = player->audio_eof.load(std::memory_order_relaxed) ||
                             player->demux_eof.load(std::memory_order_relaxed);
    const uint32_t rebuf = player->audio_rebuffer_count.load(std::memory_order_relaxed);
    const int64_t req_samples = dk_required_audio_preroll_samples(player);
    if (buffered_samples < req_samples && !eof_reached) return;

    const int64_t solo_samples = (rebuf == 0) ? 36000 : (rebuf == 1 ? 96000 : 144000);
    bool video_ready = (player->video_stream_idx < 0) ||
                       player->video_eof.load(std::memory_order_relaxed) ||
                       eof_reached ||
                       (buffered_samples >= solo_samples);
    if (!video_ready) {
        std::lock_guard<std::mutex> vql(player->video_queue_mtx);
        const size_t min_frames = (rebuf >= 2) ? 8 : (rebuf == 1 ? 6 : (player->force_present_next_frame.load(std::memory_order_relaxed) ? 4 : 3));
        video_ready = (player->video_queue.size() >= min_frames) ||
                      player->video_eof.load(std::memory_order_relaxed) ||
                      player->demux_eof.load(std::memory_order_relaxed);
    }
    if (video_ready) {
        dk_start_audio_queue_with_buffered_data(player);
    }
}

// Worker: Audio decoding and resampling
static void dk_audio_decode_worker(DKPlayer* player) {
    AVPacket* pkt = nullptr;
    AVFrame* frame = av_frame_alloc();

    while (!player->abort_requested.load()) {
        if (dk_is_seeking(player)) {
            std::unique_lock<std::mutex> lk(player->audio_pkt_mtx);
            player->audio_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || !dk_is_seeking(player);
            });
            continue;
        }

        if (player->state.load() == DK_STATE_PAUSED) {
            std::unique_lock<std::mutex> lk(player->audio_pkt_mtx);
            player->audio_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() ||
                       (!dk_is_seeking(player) && player->state.load() != DK_STATE_PAUSED);
            });
            continue;
        }

        if (player->audio_hal_disabled.load(std::memory_order_acquire)) {
            std::lock_guard<std::mutex> lock(player->audio_queue_mtx);
            player->audio_chunks.clear();
            player->buffered_audio_samples.store(0);
        }

        // Flow control: keep up to 3.3s of audio buffered in RAM (160,000 samples) so rebuffer escalation up to 2.0s never deadlocks
        if (player->buffered_audio_samples.load() > 160000) {
            if (!player->audio_queue_started.load(std::memory_order_acquire)) {
                dk_try_start_audio_queue_if_ready(player);
            }
            std::unique_lock<std::mutex> lk(player->audio_queue_mtx);
            player->audio_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || player->buffered_audio_samples.load() <= 120000 || dk_is_seeking(player) || !player->audio_queue_started.load();
            });
            if (player->abort_requested.load() || dk_is_seeking(player)) continue;
        }

        bool is_flush_pkt = false;
        {
            std::unique_lock<std::mutex> lk(player->audio_pkt_mtx);
            player->audio_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || !player->audio_pkt_queue.empty() || dk_is_seeking(player);
            });
            if (player->abort_requested.load()) break;
            if (dk_is_seeking(player)) continue;
            if (player->audio_pkt_queue.empty()) {
                lk.unlock();
                if (!player->audio_queue_started.load(std::memory_order_acquire) &&
                    player->buffered_audio_samples.load(std::memory_order_relaxed) > 0) {
                    dk_try_start_audio_queue_if_ready(player);
                }
                continue;
            }

            pkt = player->audio_pkt_queue.front();
            player->audio_pkt_queue.pop();
            is_flush_pkt = (pkt == nullptr);
            if (pkt) {
                player->queued_pkt_bytes.fetch_sub(pkt->size, std::memory_order_relaxed);
            }
        }
        player->demux_cv.notify_one();

        std::unique_lock<std::mutex> codec_lk(player->audio_codec_mtx);
        if (!player->audio_codec_ctx) {
            if (pkt) av_packet_free(&pkt);
            continue;
        }

        bool pkt_consumed = is_flush_pkt;
        if (is_flush_pkt) {
            avcodec_send_packet(player->audio_codec_ctx, nullptr);
        }

        while (!player->abort_requested.load() && !dk_is_seeking(player)) {
            if (!pkt_consumed && pkt) {
                int sret = avcodec_send_packet(player->audio_codec_ctx, pkt);
                if (sret != AVERROR(EAGAIN)) {
                    av_packet_free(&pkt);
                    pkt_consumed = true;
                    if (sret < 0) break;
                }
            }

            int ret = avcodec_receive_frame(player->audio_codec_ctx, frame);
            if (ret == AVERROR(EAGAIN)) {
                if (!pkt_consumed && pkt) continue;
                break;
            }
            if (ret == AVERROR_EOF) {
                player->audio_eof.store(true);
                if (!player->abort_requested.load() && !player->is_closing.load() &&
                    !player->audio_queue_started.load() && player->buffered_audio_samples.load() > 0) {
                    dk_start_audio_queue_with_buffered_data(player);
                }
                break;
            }
            if (ret < 0) break;

            int f_rate = frame->sample_rate > 0 ? frame->sample_rate : 48000;
            enum AVSampleFormat f_fmt = static_cast<AVSampleFormat>(frame->format);
            int f_ch = frame->ch_layout.nb_channels > 0 ? frame->ch_layout.nb_channels : 2;

            if (!player->swr_ctx || f_fmt != player->swr_in_fmt || f_rate != player->swr_in_rate || f_ch != player->swr_in_channels) {
                dk_setup_swr_from_params(player, &frame->ch_layout, f_fmt, f_rate);
            }

            if (!player->swr_ctx) {
                av_frame_unref(frame);
                continue;
            }

            double pts = 0.0;
            if (frame->best_effort_timestamp != AV_NOPTS_VALUE && player->audio_stream_idx >= 0 && player->format_ctx) {
                pts = frame->best_effort_timestamp * av_q2d(player->format_ctx->streams[player->audio_stream_idx]->time_base);
            } else if (frame->pts != AV_NOPTS_VALUE && player->audio_stream_idx >= 0 && player->format_ctx) {
                pts = frame->pts * av_q2d(player->format_ctx->streams[player->audio_stream_idx]->time_base);
            }

            double drop_target = player->audio_seek_drop_until_pts.load(std::memory_order_relaxed);
            if (drop_target > 0.0) {
                if (pts + (static_cast<double>(frame->nb_samples) / f_rate) < drop_target - 0.03) {
                    av_frame_unref(frame);
                    continue;
                }
                player->audio_seek_drop_until_pts.store(-1.0, std::memory_order_relaxed);
            }

            int in_rate = frame->sample_rate > 0 ? frame->sample_rate : 48000;
            int max_out_samples = static_cast<int>(av_rescale_rnd(
                swr_get_delay(player->swr_ctx, in_rate) + frame->nb_samples,
                48000,
                in_rate,
                AV_ROUND_UP
            ));
            if (max_out_samples <= 0) max_out_samples = frame->nb_samples * 2;

            std::vector<float> pcm(max_out_samples * 2);
            uint8_t* out_ptrs[1] = { reinterpret_cast<uint8_t*>(pcm.data()) };

            int converted = swr_convert(
                player->swr_ctx,
                out_ptrs,
                max_out_samples,
                (const uint8_t**)frame->data,
                frame->nb_samples
            );

            if (converted > 0) {
                pcm.resize(converted * 2);
                {
                    std::lock_guard<std::mutex> lock(player->audio_queue_mtx);
                    player->audio_chunks.push_back({ std::move(pcm), pts, 0 });
                    player->buffered_audio_samples.fetch_add(converted);
                }

                dk_try_start_audio_queue_if_ready(player);
            }

            av_frame_unref(frame);
        }
        if (pkt) {
            av_packet_free(&pkt);
        }
    }

    if (pkt) av_packet_free(&pkt);
    av_frame_free(&frame);
}

static bool dk_fallback_video_to_software(DKPlayer* player) {
    if (!player || !player->format_ctx || player->video_stream_idx < 0) return false;
    player->vt_failed.store(true);
    AVStream* st = player->format_ctx->streams[player->video_stream_idx];
    const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return false;

    if (player->video_codec_ctx) {
        avcodec_free_context(&player->video_codec_ctx);
    }
    player->video_codec_ctx = avcodec_alloc_context3(dec);
    if (!player->video_codec_ctx) return false;
    avcodec_parameters_to_context(player->video_codec_ctx, st->codecpar);
    player->video_codec_ctx->opaque = player;
    unsigned hc = std::thread::hardware_concurrency();
    player->video_codec_ctx->thread_count = static_cast<int>(std::clamp<unsigned>(hc > 0 ? hc : 4, 2, 8));
    player->video_codec_ctx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;

    if (avcodec_open2(player->video_codec_ctx, dec, nullptr) < 0) {
        avcodec_free_context(&player->video_codec_ctx);
        return false;
    }
    {
        std::lock_guard<std::mutex> lk(player->stats_mtx);
        player->stats.is_hw_accelerated = false;
    }
    dk_log(1, "DKEngine: VideoToolbox unsupported for stream profile; switched seamlessly to %d-thread software decode",
           player->video_codec_ctx->thread_count);
    return true;
}

// Worker: Video decoding and frame conversion
static void dk_video_decode_worker(DKPlayer* player) {
    AVPacket* pkt = nullptr;
    AVFrame* frame = av_frame_alloc();
    bool got_any_frame = false;

    while (!player->abort_requested.load()) {
        if (dk_is_seeking(player)) {
            std::unique_lock<std::mutex> lk(player->video_pkt_mtx);
            player->video_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || !dk_is_seeking(player);
            });
            continue;
        }

        if (player->state.load() == DK_STATE_PAUSED &&
            !player->seek_preview_pending.load(std::memory_order_acquire)) {
            std::unique_lock<std::mutex> lk(player->video_pkt_mtx);
            player->video_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() ||
                       (!dk_is_seeking(player) &&
                        (player->state.load() != DK_STATE_PAUSED ||
                         player->seek_preview_pending.load(std::memory_order_acquire)));
            });
            continue;
        }

        // Flow control: keep video queue buffered with up to 12 frames.
        // Wait while queue is full without dropping unrendered frames!
        {
            std::unique_lock<std::mutex> q_lock(player->video_queue_mtx);
            while (player->video_queue.size() >= 12 && !player->abort_requested.load() && !dk_is_seeking(player)) {
                player->video_frame_cv.wait_for(q_lock, std::chrono::milliseconds(10));
            }
            if (player->abort_requested.load() || dk_is_seeking(player)) continue;
        }

        bool is_flush_pkt = false;
        {
            std::unique_lock<std::mutex> lk(player->video_pkt_mtx);
            player->video_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || !player->video_pkt_queue.empty() || dk_is_seeking(player);
            });
            if (player->abort_requested.load()) break;
            if (dk_is_seeking(player) || player->video_pkt_queue.empty()) continue;

            pkt = player->video_pkt_queue.front();
            player->video_pkt_queue.pop();
            is_flush_pkt = (pkt == nullptr);
            if (pkt) {
                player->queued_pkt_bytes.fetch_sub(pkt->size, std::memory_order_relaxed);
            }
        }
        player->demux_cv.notify_one();

        std::unique_lock<std::mutex> vcodec_lk(player->video_codec_mtx);
        if (!player->video_codec_ctx) {
            if (pkt) av_packet_free(&pkt);
            continue;
        }

        bool pkt_consumed = is_flush_pkt;
        if (is_flush_pkt) {
            avcodec_send_packet(player->video_codec_ctx, nullptr);
        }

        while (!player->abort_requested.load() && !dk_is_seeking(player)) {
            if (!pkt_consumed && pkt) {
                int sret = avcodec_send_packet(player->video_codec_ctx, pkt);
                if (sret != AVERROR(EAGAIN)) {
                    if (sret < 0 && !got_any_frame && !player->vt_failed.load() && player->hw_decode_enabled) {
                        if (dk_fallback_video_to_software(player)) {
                            sret = avcodec_send_packet(player->video_codec_ctx, pkt);
                        }
                    }
                    av_packet_free(&pkt);
                    pkt_consumed = true;
                    if (sret < 0) break;
                }
            }

            int ret = avcodec_receive_frame(player->video_codec_ctx, frame);
            if (ret == AVERROR(EAGAIN)) {
                if (!pkt_consumed && pkt) continue;
                break;
            }
            if (ret == AVERROR_EOF) {
                player->video_eof.store(true);
                player->seek_preview_pending.store(false, std::memory_order_release);
                break;
            }
            if (ret < 0) break;

            got_any_frame = true;
            double pts = -1.0;
            if (frame->best_effort_timestamp != AV_NOPTS_VALUE && player->video_stream_idx >= 0 && player->format_ctx) {
                pts = frame->best_effort_timestamp * av_q2d(player->format_ctx->streams[player->video_stream_idx]->time_base);
            } else if (frame->pts != AV_NOPTS_VALUE && player->video_stream_idx >= 0 && player->format_ctx) {
                pts = frame->pts * av_q2d(player->format_ctx->streams[player->video_stream_idx]->time_base);
            } else {
                double fps = player->stats.fps > 1.0 ? player->stats.fps : 24.0;
                pts = (player->last_decoded_video_pts >= 0.0) ? (player->last_decoded_video_pts + 1.0 / fps) : 0.0;
            }
            player->last_decoded_video_pts = pts;

            double drop_target = player->video_seek_drop_until_pts.load(std::memory_order_relaxed);
            if (drop_target > 0.0) {
                if (pts < drop_target - 0.04) {
                    av_frame_unref(frame);
                    continue;
                }
                player->video_seek_drop_until_pts.store(-1.0, std::memory_order_relaxed);
            }

            CVPixelBufferRef pixbuf = nullptr;
            const bool frame_is_hw = (frame->format == AV_PIX_FMT_VIDEOTOOLBOX);
            if (player->stats.is_hw_accelerated != frame_is_hw) {
                std::lock_guard<std::mutex> lk(player->stats_mtx);
                player->stats.is_hw_accelerated = frame_is_hw;
            }
            if (frame_is_hw) {
                pixbuf = reinterpret_cast<CVPixelBufferRef>(frame->data[3]);
                if (pixbuf) CVPixelBufferRetain(pixbuf);
            } else {
                pixbuf = dk_convert_software_frame_to_cvpixelbuffer(player, frame);
            }

            if (pixbuf) {
                DKGpuColorUniforms color = dk_build_color_uniforms(player, frame, pixbuf);

                {
                    std::lock_guard<std::mutex> lock(player->video_queue_mtx);
                    player->video_queue.push({ pixbuf, pts, color });
                }
                player->seek_preview_pending.store(false, std::memory_order_release);
                player->video_frame_cv.notify_one();
                dk_try_start_audio_queue_if_ready(player);
                if (player->state.load() == DK_STATE_PAUSED) {
                    av_frame_unref(frame);
                    break;
                }
            }

            av_frame_unref(frame);
        }
        if (pkt) {
            av_packet_free(&pkt);
        }
    }

    if (pkt) av_packet_free(&pkt);
    av_frame_free(&frame);
}

static std::string dk_cf_transform_segment(const std::string& seg, int32_t mode) {
    if (mode == 0 || seg.empty()) return seg;
    CFStringRef src = CFStringCreateWithBytes(
        kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(seg.data()),
        static_cast<CFIndex>(seg.size()),
        kCFStringEncodingUTF8,
        false
    );
    if (!src) return seg;
    CFMutableStringRef mut = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, src);
    CFRelease(src);
    if (!mut) return seg;
    CFStringRef transform_id = (mode == 1) ? CFSTR("Hant-Hans") : CFSTR("Hans-Hant");
    CFStringTransform(mut, nullptr, transform_id, false);
    CFIndex max_len = CFStringGetMaximumSizeForEncoding(CFStringGetLength(mut), kCFStringEncodingUTF8) + 1;
    std::string out(static_cast<size_t>(max_len), '\0');
    Boolean ok = CFStringGetCString(mut, out.data(), max_len, kCFStringEncodingUTF8);
    CFRelease(mut);
    if (!ok) return seg;
    out.resize(std::strlen(out.c_str()));
    return out;
}

static bool dk_is_pale_yellow_rgb(uint8_t r, uint8_t g, uint8_t b) {
    // Matches washed-out cream/pale yellow (e.g. #FFE8A8, #F5E6B3, #FFEEBB) while leaving pure white or cool hues untouched.
    return (r >= 180 && g >= 155 && b >= 65 && b <= static_cast<int>(r) - 18 && std::abs(static_cast<int>(r) - static_cast<int>(g)) <= 65);
}

static bool dk_style_looks_like_foreign_secondary(const char* name) {
    if (!name || !*name) return false;
    std::string lower;
    lower.reserve(std::strlen(name));
    for (const unsigned char* p = reinterpret_cast<const unsigned char*>(name); *p; ++p) {
        lower.push_back(static_cast<char>(std::tolower(*p)));
    }
    return lower.find("eng") != std::string::npos ||
           lower.find("english") != std::string::npos ||
           lower.find("sub") != std::string::npos ||
           lower.find("sec") != std::string::npos ||
           lower.find("foreign") != std::string::npos ||
           lower.find("en_") != std::string::npos ||
           lower.find("_en") != std::string::npos ||
           lower == "en" ||
           lower.find("英") != std::string::npos ||
           lower.find("外") != std::string::npos ||
           lower.find("日") != std::string::npos ||
           lower.find("韩") != std::string::npos;
}

static bool dk_has_cjk_utf8(const std::string& s) {
    for (size_t i = 0; i + 2 < s.size(); ++i) {
        uint8_t c0 = static_cast<uint8_t>(s[i]);
        if (c0 >= 0xE4 && c0 <= 0xE9) return true;
    }
    return false;
}

static bool dk_is_mostly_latin_line(const std::string& s) {
    int latin = 0;
    bool in_tag = false;
    for (size_t i = 0; i < s.size(); ++i) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        if (c == '{') { in_tag = true; continue; }
        if (c == '}') { in_tag = false; continue; }
        if (in_tag) continue;
        if (c >= 0xE4 && c <= 0xE9) return false;
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) latin++;
    }
    return latin >= 2;
}

static std::string dk_filter_ass_tag_block(const std::string& block, bool strip_font, bool enhance_yellow) {
    if ((!strip_font && !enhance_yellow) || block.size() < 2 || block.front() != '{' || block.back() != '}') {
        return block;
    }
    std::string inner = block.substr(1, block.size() - 2);
    std::string out;
    out.reserve(inner.size() + 8);
    size_t i = 0;
    while (i < inner.size()) {
        if (inner[i] != '\\') {
            out.push_back(inner[i++]);
            continue;
        }
        size_t next_bs = inner.find('\\', i + 1);
        std::string tok = (next_bs == std::string::npos) ? inner.substr(i) : inner.substr(i, next_bs - i);
        i = (next_bs == std::string::npos) ? inner.size() : next_bs;

        if (strip_font && tok.size() >= 3 && tok[1] == 'f' && tok[2] == 'n') {
            continue; // Strip inline \fn<FontName> so PingFang SC applies uniformly while keeping layout tags intact
        }
        if (enhance_yellow && ((tok.size() >= 4 && tok[1] == 'c' && tok[2] == '&') ||
                               (tok.size() >= 5 && tok[1] == '1' && tok[2] == 'c' && tok[3] == '&'))) {
            size_t h_pos = tok.find('H');
            if (h_pos == std::string::npos) h_pos = tok.find('h');
            if (h_pos != std::string::npos) {
                std::string hex;
                for (size_t k = h_pos + 1; k < tok.size(); ++k) {
                    if (std::isxdigit(static_cast<unsigned char>(tok[k]))) hex.push_back(tok[k]);
                    else break;
                }
                if (hex.size() >= 6) {
                    // ASS color tag is &H[AA]BBGGRR&
                    unsigned long val = std::strtoul(hex.c_str(), nullptr, 16);
                    uint8_t r = static_cast<uint8_t>(val & 0xFF);
                    uint8_t g = static_cast<uint8_t>((val >> 8) & 0xFF);
                    uint8_t b = static_cast<uint8_t>((val >> 16) & 0xFF);
                    if (dk_is_pale_yellow_rgb(r, g, b)) {
                        out += "\\1c&H003FD2FF&";
                        continue;
                    }
                }
            }
        }
        out += tok;
    }
    if (out.empty()) return "";
    return "{" + out + "}";
}

// Transform ASS dialogue payload while preserving ASS tags {...} and escape codes (\N, \n, \h)
static std::string dk_transform_ass_payload(const std::string& payload, int32_t mode, bool strip_font = false, bool enhance_yellow = false) {
    if ((mode == 0 && !strip_font && !enhance_yellow) || payload.empty()) return payload;
    std::string out;
    out.reserve(payload.size() + 24);
    size_t i = 0;
    while (i < payload.size()) {
        if (payload[i] == '{') {
            size_t close = payload.find('}', i + 1);
            if (close != std::string::npos) {
                std::string block = payload.substr(i, close - i + 1);
                out += dk_filter_ass_tag_block(block, strip_font, enhance_yellow);
                i = close + 1;
                continue;
            }
        }
        if (payload[i] == '\\' && i + 1 < payload.size() &&
            (payload[i + 1] == 'N' || payload[i + 1] == 'n' || payload[i + 1] == 'h')) {
            out.append(payload, i, 2);
            i += 2;
            continue;
        }
        size_t start = i;
        while (i < payload.size() && payload[i] != '{' &&
               !(payload[i] == '\\' && i + 1 < payload.size() &&
                 (payload[i + 1] == 'N' || payload[i + 1] == 'n' || payload[i + 1] == 'h'))) {
            i++;
        }
        if (mode != 0) {
            out += dk_cf_transform_segment(payload.substr(start, i - start), mode);
        } else {
            out.append(payload, start, i - start);
        }
    }
    return out;
}

// Transform an ASS Dialogue line or ReadOrder chunk line (preserving leading CSV fields before Text)
static std::string dk_transform_ass_line(const std::string& line, int32_t mode, bool is_full_dialogue, bool strip_font = false, bool enhance_yellow = false) {
    if ((mode == 0 && !strip_font && !enhance_yellow) || line.empty()) return line;
    int target_commas = is_full_dialogue ? 9 : 8;
    int seen_commas = 0;
    size_t split_pos = std::string::npos;
    for (size_t i = 0; i < line.size(); i++) {
        if (line[i] == ',') {
            seen_commas++;
            if (seen_commas == target_commas) {
                split_pos = i + 1;
                break;
            }
        }
    }
    if (split_pos == std::string::npos || split_pos >= line.size()) {
        return dk_transform_ass_payload(line, mode, strip_font, enhance_yellow);
    }
    return line.substr(0, split_pos) + dk_transform_ass_payload(line.substr(split_pos), mode, strip_font, enhance_yellow);
}

static std::string dk_transform_ass_document(const std::string& doc, int32_t mode, bool strip_font = false, bool enhance_yellow = false) {
    if ((mode == 0 && !strip_font && !enhance_yellow) || doc.empty()) return doc;
    std::string out;
    out.reserve(doc.size() + 32);
    size_t pos = 0;
    while (pos < doc.size()) {
        size_t nl = doc.find('\n', pos);
        std::string line = (nl == std::string::npos) ? doc.substr(pos) : doc.substr(pos, nl - pos + 1);
        pos = (nl == std::string::npos) ? doc.size() : (nl + 1);
        if (line.rfind("Dialogue:", 0) == 0) {
            out += dk_transform_ass_line(line, mode, true, strip_font, enhance_yellow);
        } else {
            out += line;
        }
    }
    return out;
}

static void dk_apply_style_to_ass_track_locked(DKPlayer* player, ASS_Track* track, bool is_secondary) {
    if (!player || !track) return;
    const ASS_Track*& orig_ptr = is_secondary ? player->secondary_orig_track_ptr : player->primary_orig_track_ptr;
    auto& orig_styles = is_secondary ? player->secondary_orig_styles : player->primary_orig_styles;
    if (orig_ptr != track || static_cast<int>(orig_styles.size()) != track->n_styles) {
        orig_ptr = track;
        orig_styles.clear();
        orig_styles.reserve(static_cast<size_t>(std::max(0, track->n_styles)));
        for (int i = 0; i < track->n_styles; i++) {
            const ASS_Style& st = track->styles[i];
            DKPlayer::OriginalAssStyle snap;
            snap.font_name = st.FontName ? std::string(st.FontName) : std::string("PingFang SC");
            snap.font_size = st.FontSize;
            snap.outline = st.Outline;
            snap.margin_v = st.MarginV;
            snap.primary_colour = st.PrimaryColour;
            snap.scale_x = st.ScaleX;
            snap.scale_y = st.ScaleY;
            snap.alignment = st.Alignment;
            snap.border_style = st.BorderStyle;
            orig_styles.push_back(std::move(snap));
        }
    }

    float user_scale = std::clamp(player->sub_style.scale > 0.1f ? player->sub_style.scale : 1.0f, 0.5f, 2.5f);
    float role_scale = is_secondary ? (user_scale * 0.80f) : user_scale;
    float border = std::clamp(player->sub_style.border_width >= 0.0f ? player->sub_style.border_width : 2.8f, 0.0f, 8.0f);
    float pos_pct = std::clamp(player->sub_style.vertical_pos_percent > 10.0f ? player->sub_style.vertical_pos_percent : 92.0f, 50.0f, 100.0f);
    int play_res_y = (track->PlayResY > 0) ? track->PlayResY : 1080;
    double res_ratio = static_cast<double>(play_res_y) / 1080.0;

    int target_margin_v = std::clamp(
        static_cast<int>(std::lround((100.0f - pos_pct) * 0.01f * static_cast<float>(play_res_y))),
        4,
        play_res_y / 2
    );
    int default_baseline_margin = static_cast<int>(std::lround(0.08 * static_cast<double>(play_res_y))); // 92% baseline
    int delta_margin_v = target_margin_v - default_baseline_margin;
    if (is_secondary) {
        target_margin_v = std::min(play_res_y / 2, target_margin_v + static_cast<int>(std::lround(58.0 * res_ratio)));
    }

    constexpr uint32_t kClassicGoldYellowRGBA = 0xFFD23F00u; // Rich cinema gold-yellow (#FFD23F, alpha=0 opaque)
    const bool unify_pf = player->sub_style.unify_pingfang_font;
    const bool enhance_yellow = player->sub_style.enhance_secondary_yellow;
    const bool override_all = player->sub_style.override_ass_style;

    for (int i = 0; i < track->n_styles; i++) {
        ASS_Style& st = track->styles[i];
        const auto& orig = orig_styles[static_cast<size_t>(i)];
        bool is_default = (st.Name && std::strcmp(st.Name, "Default") == 0) || (track->n_styles == 1);
        int orig_align_v = orig.alignment & 0x0C; // libass Alignment: 0=bottom(SUB), 4=top(TOP), 8=mid(MID); fallback check 1..3
        bool is_bottom_style = (orig.alignment >= 1 && orig.alignment <= 3) || (orig_align_v == 0);

        // 1. Unified PingFang SC font (default ON)
        const char* desired_font = (unify_pf || override_all) ? "PingFang SC" : orig.font_name.c_str();
        if (!st.FontName || std::strcmp(st.FontName, desired_font) != 0) {
            if (st.FontName) free(st.FontName);
            st.FontName = strdup(desired_font);
        }

        // 2. Classic rich gold-yellow enhancement for secondary/foreign styles
        uint8_t r = static_cast<uint8_t>((orig.primary_colour >> 24) & 0xFF);
        uint8_t g = static_cast<uint8_t>((orig.primary_colour >> 16) & 0xFF);
        uint8_t b = static_cast<uint8_t>((orig.primary_colour >> 8) & 0xFF);
        bool should_gold = enhance_yellow && (is_secondary || dk_style_looks_like_foreign_secondary(st.Name) || dk_is_pale_yellow_rgb(r, g, b));
        st.PrimaryColour = should_gold ? kClassicGoldYellowRGBA : orig.primary_colour;

        // 3. Real-time scale & vertical position for ALL bottom dialogue styles (preserves top signs/annotations)
        if (override_all || is_default) {
            double base_fs = (56.0 * res_ratio);
            st.FontSize = base_fs * static_cast<double>(role_scale);
            st.Outline = static_cast<double>(border) * (is_secondary ? 0.88 : 1.0) * res_ratio;
            st.MarginV = target_margin_v;
            if (override_all) {
                st.ScaleX = 1.0;
                st.ScaleY = 1.0;
                st.Alignment = 2; // Bottom-center
                st.BorderStyle = 1;
            } else {
                st.ScaleX = orig.scale_x;
                st.ScaleY = orig.scale_y;
                st.Alignment = orig.alignment;
                st.BorderStyle = orig.border_style;
            }
        } else if (is_bottom_style) {
            // Preserve relative bilingual hierarchy (e.g. larger CN + smaller EN) while scaling and shifting smoothly together
            double base_fs = (orig.font_size > 4.0) ? orig.font_size : (48.0 * res_ratio);
            st.FontSize = base_fs * static_cast<double>(role_scale);
            st.Outline = std::max(orig.outline, static_cast<double>(border) * 0.85 * res_ratio);
            st.MarginV = std::clamp(orig.margin_v + delta_margin_v, 4, play_res_y / 2);
            st.ScaleX = orig.scale_x;
            st.ScaleY = orig.scale_y;
            st.Alignment = orig.alignment;
            st.BorderStyle = orig.border_style;
        }
    }
}

static void dk_ensure_ass_track_header_for(DKPlayer* player, ASS_Track* track, bool is_secondary) {
    if (!player || !player->ass_lib || !track) return;
    if (is_secondary && !player->secondary_ass_renderer) {
        player->secondary_ass_renderer = ass_renderer_init(player->ass_lib);
        if (player->secondary_ass_renderer) {
            ass_set_fonts(player->secondary_ass_renderer, nullptr, "PingFang SC", 1, nullptr, 1);
            if (player->ass_canvas_w > 0 && player->ass_canvas_h > 0) {
                ass_set_frame_size(player->secondary_ass_renderer, player->ass_canvas_w, player->ass_canvas_h);
                ass_set_storage_size(player->secondary_ass_renderer, player->ass_canvas_w, player->ass_canvas_h);
            }
        }
    }
    if (track->event_format != nullptr) {
        dk_apply_style_to_ass_track_locked(player, track, is_secondary);
        return;
    }
    if (track->n_styles > 1) {
        const char* events_hdr =
            "[Events]\r\n"
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n";
        ass_process_codec_private(track, const_cast<char*>(events_hdr), static_cast<int>(std::strlen(events_hdr)));
        dk_apply_style_to_ass_track_locked(player, track, is_secondary);
        return;
    }
    const char* default_hdr =
        "[Script Info]\r\n"
        "ScriptType: v4.00+\r\n"
        "PlayResX: 1920\r\n"
        "PlayResY: 1080\r\n"
        "ScaledBorderAndShadow: yes\r\n"
        "\r\n"
        "[V4+ Styles]\r\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\r\n"
        "Style: Default,PingFang SC,56,&H00F5F5F5,&H0000FFFF,&H24000000,&H80000000,-1,0,0,0,100,100,0,0,1,2.8,1.2,2,40,40,46,1\r\n"
        "\r\n"
        "[Events]\r\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n";
    ass_process_codec_private(track, const_cast<char*>(default_hdr), static_cast<int>(std::strlen(default_hdr)));
    dk_apply_style_to_ass_track_locked(player, track, is_secondary);
}

static void dk_ensure_default_ass_track_header(DKPlayer* player) {
    if (!player) return;
    dk_ensure_ass_track_header_for(player, player->ass_track, false);
}

static void dk_open_subtitle_decoder_for_slot_locked(DKPlayer* player, int stream_idx, bool is_secondary) {
    AVCodecContext*& codec_ctx = is_secondary ? player->secondary_sub_codec_ctx : player->sub_codec_ctx;
    ASS_Track*& track = is_secondary ? player->secondary_ass_track : player->ass_track;
    std::string& codec_priv = is_secondary ? player->secondary_codec_private : player->primary_codec_private;
    std::vector<StoredAssEvent>& events = is_secondary ? player->secondary_ass_events : player->primary_ass_events;
    std::string& ext_raw = is_secondary ? player->secondary_ext_raw : player->primary_ext_raw;

    if (codec_ctx) {
        avcodec_free_context(&codec_ctx);
    }
    if (track) {
        ass_free_track(track);
        track = nullptr;
    }
    codec_priv.clear();
    events.clear();
    if (stream_idx >= 0) {
        ext_raw.clear();
    }
    if (!is_secondary) {
        player->pgs_cues.clear();
        player->pgs_generation++;
        player->rendered_pgs_gen = 0;
        player->has_bitmap_subs = false;
    }
    player->sub_rgba_buf.clear();
    player->sub_last_non_empty = false;
    player->sub_dirty_y0 = 0;
    player->sub_dirty_y1 = 0;
    player->sub_serial++;

    if (!player->format_ctx || stream_idx < 0 || static_cast<unsigned>(stream_idx) >= player->format_ctx->nb_streams) {
        return;
    }
    AVStream* st = player->format_ctx->streams[stream_idx];
    if (st->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) return;

    if (player->ass_lib) {
        track = ass_new_track(player->ass_lib);
    }
    if (!is_secondary) {
        if (st->codecpar->width > 0 && st->codecpar->height > 0) {
            player->sub_storage_w = st->codecpar->width;
            player->sub_storage_h = st->codecpar->height;
        } else if (player->stats.width > 0 && player->stats.height > 0) {
            player->sub_storage_w = player->stats.width;
            player->sub_storage_h = player->stats.height;
        }
    }

    const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) {
        if (track && st->codecpar->extradata && st->codecpar->extradata_size > 0) {
            codec_priv.assign(reinterpret_cast<const char*>(st->codecpar->extradata), st->codecpar->extradata_size);
            ass_process_codec_private(track, codec_priv.data(), static_cast<int>(codec_priv.size()));
        }
        dk_ensure_ass_track_header_for(player, track, is_secondary);
        return;
    }

    codec_ctx = avcodec_alloc_context3(dec);
    if (!codec_ctx) return;
    avcodec_parameters_to_context(codec_ctx, st->codecpar);
    codec_ctx->pkt_timebase = st->time_base;
    if (avcodec_open2(codec_ctx, dec, nullptr) < 0) {
        avcodec_free_context(&codec_ctx);
        return;
    }

    if (track) {
        if (st->codecpar->codec_id == AV_CODEC_ID_ASS || st->codecpar->codec_id == AV_CODEC_ID_SSA) {
            if (st->codecpar->extradata && st->codecpar->extradata_size > 0) {
                codec_priv.assign(reinterpret_cast<const char*>(st->codecpar->extradata), st->codecpar->extradata_size);
                ass_process_codec_private(track, codec_priv.data(), static_cast<int>(codec_priv.size()));
            } else if (codec_ctx->subtitle_header && codec_ctx->subtitle_header_size > 0) {
                codec_priv.assign(reinterpret_cast<const char*>(codec_ctx->subtitle_header), codec_ctx->subtitle_header_size);
                ass_process_codec_private(track, codec_priv.data(), static_cast<int>(codec_priv.size()));
            }
            dk_ensure_ass_track_header_for(player, track, is_secondary);
        } else {
            dk_ensure_ass_track_header_for(player, track, is_secondary);
        }
    }
    dk_log(0, "DKEngine: Opened %s embedded subtitle stream #%d (%s)",
           is_secondary ? "secondary" : "primary",
           stream_idx, dec->name ? dec->name : "subtitle");
}

static void dk_open_subtitle_decoder_locked(DKPlayer* player, int stream_idx) {
    dk_open_subtitle_decoder_for_slot_locked(player, stream_idx, false);
}

static void dk_decode_subtitle_packet_for_slot_locked(DKPlayer* player, AVPacket* pkt, int stream_idx, bool is_secondary) {
    if (!player || !pkt || !player->format_ctx) return;
    if (stream_idx < 0 || static_cast<unsigned>(stream_idx) >= player->format_ctx->nb_streams) return;
    AVStream* st = player->format_ctx->streams[stream_idx];
    AVCodecContext* codec_ctx = is_secondary ? player->secondary_sub_codec_ctx : player->sub_codec_ctx;
    ASS_Track* track = is_secondary ? player->secondary_ass_track : player->ass_track;
    std::vector<StoredAssEvent>& events = is_secondary ? player->secondary_ass_events : player->primary_ass_events;

    const bool stream_is_forced = (st->disposition & AV_DISPOSITION_FORCED) != 0;

    int64_t raw_ts = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
    long long pkt_pts_ms = (raw_ts != AV_NOPTS_VALUE)
        ? av_rescale_q(raw_ts, st->time_base, AVRational{1, 1000})
        : 0;
    long long pkt_dur_ms = (pkt->duration > 0)
        ? av_rescale_q(pkt->duration, st->time_base, AVRational{1, 1000})
        : 3500;

    auto feed_and_store_ass_event = [&](const std::string& raw_str, bool is_dialogue, bool evt_forced, long long s_ms, long long d_ms) {
        if (!track) return;
        if (events.size() < 4096) {
            events.push_back({s_ms, d_ms, raw_str, is_dialogue, evt_forced});
        }
        if (player->sub_style.forced_only && !evt_forced) {
            return;
        }
        std::string transformed = dk_transform_ass_line(
            raw_str,
            player->sub_style.text_transform,
            is_dialogue,
            player->sub_style.unify_pingfang_font,
            player->sub_style.enhance_secondary_yellow
        );
        if (is_dialogue) {
            ass_process_data(track, transformed.data(), static_cast<int>(transformed.size()));
        } else {
            ass_process_chunk(track, transformed.data(), static_cast<int>(transformed.size()), s_ms, d_ms);
        }
    };

    if ((st->codecpar->codec_id == AV_CODEC_ID_ASS || st->codecpar->codec_id == AV_CODEC_ID_SSA) && track && pkt->data && pkt->size > 0) {
        dk_ensure_ass_track_header_for(player, track, is_secondary);
        std::string raw_ass(reinterpret_cast<const char*>(pkt->data), static_cast<size_t>(pkt->size));
        bool is_diag = (raw_ass.size() >= 9 && std::strncmp(raw_ass.c_str(), "Dialogue:", 9) == 0);
        feed_and_store_ass_event(raw_ass, is_diag, stream_is_forced, pkt_pts_ms, pkt_dur_ms);
        return;
    }

    if (!codec_ctx) return;
    AVSubtitle sub{};
    int got_sub = 0;
    int ret = avcodec_decode_subtitle2(codec_ctx, &sub, &got_sub, pkt);
    if (ret < 0 || !got_sub) {
        avsubtitle_free(&sub);
        return;
    }

    long long base_ms = (sub.pts != AV_NOPTS_VALUE) ? (sub.pts / 1000) : pkt_pts_ms;
    long long start_ms = base_ms + sub.start_display_time;
    long long dur_ms = (sub.end_display_time > sub.start_display_time && sub.end_display_time < 3600000)
        ? (sub.end_display_time - sub.start_display_time)
        : pkt_dur_ms;

    if (sub.format == 0 && !is_secondary) {
        player->has_bitmap_subs = true;
        double cue_start = static_cast<double>(start_ms) / 1000.0;
        double cue_end = (sub.end_display_time > sub.start_display_time && sub.end_display_time < 3600000)
            ? (static_cast<double>(base_ms + sub.end_display_time) / 1000.0)
            : (cue_start + 12.0);

        if (!player->pgs_cues.empty() && player->pgs_cues.back().end_sec > cue_start) {
            player->pgs_cues.back().end_sec = cue_start;
        }

        if (sub.num_rects > 0) {
            PgsCue cue;
            cue.id = ++player->pgs_generation;
            cue.start_sec = cue_start;
            cue.end_sec = cue_end;
            cue.canvas_w = (codec_ctx->width > 0) ? codec_ctx->width : player->sub_storage_w;
            cue.canvas_h = (codec_ctx->height > 0) ? codec_ctx->height : player->sub_storage_h;

            float cue_peak_luma = 0.0f;
            for (unsigned r = 0; r < sub.num_rects; r++) {
                const AVSubtitleRect* rect = sub.rects[r];
                if (!rect || rect->type != SUBTITLE_BITMAP || rect->w <= 0 || rect->h <= 0 || !rect->data[0] || !rect->data[1]) continue;
                if (player->sub_style.forced_only && !stream_is_forced && !(rect->flags & AV_SUBTITLE_FLAG_FORCED)) continue;
                const uint32_t* pal = reinterpret_cast<const uint32_t*>(rect->data[1]);
                bool seen_idx[256] = {false};
                for (int row = 0; row < rect->h; row++) {
                    const uint8_t* idx_row = rect->data[0] + row * rect->linesize[0];
                    for (int col = 0; col < rect->w; col++) {
                        seen_idx[idx_row[col]] = true;
                    }
                }
                for (int idx = 0; idx < 256; idx++) {
                    if (!seen_idx[idx]) continue;
                    uint32_t argb = pal[idx];
                    uint8_t a = (argb >> 24) & 0xFF;
                    if (a < 96) continue;
                    float cr = static_cast<float>((argb >> 16) & 0xFF);
                    float cg = static_cast<float>((argb >> 8) & 0xFF);
                    float cb = static_cast<float>(argb & 0xFF);
                    float luma = 0.2126f * cr + 0.7152f * cg + 0.0722f * cb;
                    if (luma > cue_peak_luma) cue_peak_luma = luma;
                }
            }
            const float pgs_luma_gain = (cue_peak_luma >= 80.0f)
                ? std::clamp(245.0f / cue_peak_luma, 0.96f, 2.40f)
                : 1.0f;

            for (unsigned r = 0; r < sub.num_rects; r++) {
                const AVSubtitleRect* rect = sub.rects[r];
                if (!rect || rect->type != SUBTITLE_BITMAP || rect->w <= 0 || rect->h <= 0 || !rect->data[0] || !rect->data[1]) continue;
                if (player->sub_style.forced_only && !stream_is_forced && !(rect->flags & AV_SUBTITLE_FLAG_FORCED)) continue;
                PgsBitmapRect dst_r;
                dst_r.x = rect->x;
                dst_r.y = rect->y;
                dst_r.w = rect->w;
                dst_r.h = rect->h;
                dst_r.rgba.resize(static_cast<size_t>(rect->w) * static_cast<size_t>(rect->h) * 4);
                const uint32_t* pal = reinterpret_cast<const uint32_t*>(rect->data[1]);
                for (int row = 0; row < rect->h; row++) {
                    const uint8_t* idx_row = rect->data[0] + row * rect->linesize[0];
                    uint8_t* out_row = dst_r.rgba.data() + static_cast<size_t>(row) * rect->w * 4;
                    for (int col = 0; col < rect->w; col++) {
                        uint32_t argb = pal[idx_row[col]];
                        uint8_t a = (argb >> 24) & 0xFF;
                        int cr = std::min(255, static_cast<int>(std::lround(((argb >> 16) & 0xFF) * pgs_luma_gain)));
                        int cg = std::min(255, static_cast<int>(std::lround(((argb >> 8) & 0xFF) * pgs_luma_gain)));
                        int cb = std::min(255, static_cast<int>(std::lround((argb & 0xFF) * pgs_luma_gain)));
                        out_row[col * 4 + 0] = static_cast<uint8_t>((cr * a + 127) / 255);
                        out_row[col * 4 + 1] = static_cast<uint8_t>((cg * a + 127) / 255);
                        out_row[col * 4 + 2] = static_cast<uint8_t>((cb * a + 127) / 255);
                        out_row[col * 4 + 3] = a;
                    }
                }
                cue.rects.push_back(std::move(dst_r));
            }
            if (!cue.rects.empty()) {
                if (player->pgs_cues.size() >= 64) {
                    player->pgs_cues.pop_front();
                }
                player->pgs_cues.push_back(std::move(cue));
            }
        }
    } else if (track) {
        dk_ensure_ass_track_header_for(player, track, is_secondary);
        for (unsigned r = 0; r < sub.num_rects; r++) {
            const AVSubtitleRect* rect = sub.rects[r];
            if (!rect) continue;
            bool evt_forced = stream_is_forced || ((rect->flags & AV_SUBTITLE_FLAG_FORCED) != 0);
            if (rect->type == SUBTITLE_ASS && rect->ass) {
                std::string ass_line = rect->ass;
                bool is_diag = (ass_line.size() >= 9 && std::strncmp(ass_line.c_str(), "Dialogue:", 9) == 0);
                feed_and_store_ass_event(ass_line, is_diag, evt_forced, start_ms, dur_ms);
            } else if (rect->type == SUBTITLE_TEXT && rect->text) {
                std::string clean_txt = rect->text;
                std::string formatted;
                for (size_t k = 0; k < clean_txt.size(); k++) {
                    if (clean_txt[k] == '\r') continue;
                    if (clean_txt[k] == '\n') formatted += "\\N";
                    else formatted += clean_txt[k];
                }
                std::string chunk = std::to_string(++player->sub_read_order) + ",0,Default,,0,0,0,," + formatted;
                feed_and_store_ass_event(chunk, false, evt_forced, start_ms, dur_ms);
            }
        }
    }

    avsubtitle_free(&sub);
}

static void dk_clear_sub_pkt_history(DKPlayer* player) {
    if (!player) return;
    std::lock_guard<std::mutex> lk(player->sub_hist_mtx);
    while (!player->sub_pkt_history.empty()) {
        AVPacket* p = player->sub_pkt_history.front();
        player->sub_pkt_history.pop_front();
        if (p) av_packet_free(&p);
    }
    player->sub_hist_bytes = 0;
    player->sub_hist_trimmed.store(false, std::memory_order_relaxed);
}

static void dk_record_sub_pkt_history(DKPlayer* player, AVPacket* pkt) {
    if (!player || !pkt || pkt->size <= 0) return;
    AVPacket* clone = av_packet_clone(pkt);
    if (!clone) return;
    constexpr size_t kMaxSubHistBytes = 4 * 1024 * 1024;
    constexpr size_t kMaxSubHistPkts = 2500;
    std::lock_guard<std::mutex> lk(player->sub_hist_mtx);
    player->sub_hist_bytes += static_cast<size_t>(clone->size);
    player->sub_pkt_history.push_back(clone);
    while (player->sub_pkt_history.size() > kMaxSubHistPkts || player->sub_hist_bytes > kMaxSubHistBytes) {
        AVPacket* old = player->sub_pkt_history.front();
        player->sub_pkt_history.pop_front();
        if (old) {
            player->sub_hist_bytes -= std::min(player->sub_hist_bytes, static_cast<size_t>(std::max(0, old->size)));
            av_packet_free(&old);
        }
        player->sub_hist_trimmed.store(true, std::memory_order_relaxed);
    }
}

static void dk_replay_sub_pkt_history(DKPlayer* player, int target_stream_idx, bool is_secondary) {
    if (!player || target_stream_idx < 0) return;
    std::vector<AVPacket*> clones;
    {
        std::lock_guard<std::mutex> lk(player->sub_hist_mtx);
        clones.reserve(64);
        for (AVPacket* src : player->sub_pkt_history) {
            if (src && src->stream_index == target_stream_idx) {
                if (AVPacket* cp = av_packet_clone(src)) {
                    clones.push_back(cp);
                }
            }
        }
    }
    if (clones.empty()) return;
    {
        std::lock_guard<std::mutex> slk(player->ass_mtx);
        for (AVPacket* cp : clones) {
            dk_decode_subtitle_packet_for_slot_locked(player, cp, target_stream_idx, is_secondary);
        }
        player->sub_last_non_empty = false;
        player->rendered_pgs_gen = 0;
        player->sub_serial++;
    }
    for (AVPacket* cp : clones) {
        av_packet_free(&cp);
    }
}

static void dk_decode_subtitle_packet(DKPlayer* player, AVPacket* pkt) {
    if (!player || !pkt || !player->format_ctx) return;
    std::lock_guard<std::mutex> lk(player->ass_mtx);
    const int pri_idx = player->sub_stream_idx.load(std::memory_order_relaxed);
    const int sec_idx = player->secondary_sub_stream_idx.load(std::memory_order_relaxed);
    if (pri_idx >= 0 && pkt->stream_index == pri_idx) {
        dk_decode_subtitle_packet_for_slot_locked(player, pkt, pri_idx, false);
    }
    if (sec_idx >= 0 && pkt->stream_index == sec_idx && sec_idx != pri_idx) {
        dk_decode_subtitle_packet_for_slot_locked(player, pkt, sec_idx, true);
    }
}

static void dk_clear_avio_error_state(AVFormatContext* fmt_ctx) {
    if (fmt_ctx && fmt_ctx->pb) {
        fmt_ctx->pb->error = 0;
        fmt_ctx->pb->eof_reached = 0;
    }
}

static void dk_signal_seek_request(DKPlayer* player, double target_sec, bool accurate) {
    if (!player) return;
    player->seek_target_sec.store(target_sec, std::memory_order_release);
    player->seek_accurate.store(accurate, std::memory_order_release);
    player->latest_seek_seq.fetch_add(1, std::memory_order_acq_rel);
    player->seek_requested.store(true, std::memory_order_release);
    player->demux_cv.notify_all();
}

// Worker: Demuxing, thread-safe seeking, and cache writing
static void dk_demux_worker(DKPlayer* player) {
    AVPacket* pkt = av_packet_alloc();
    int consecutive_io_errors = 0;
    int dovi_probe_packets = 0;

    while (!player->abort_requested.load()) {
        // Thread-safe seek handling
        if (player->seek_requested.load(std::memory_order_acquire)) {
            std::lock_guard<std::mutex> lock(player->demux_mtx);
            uint64_t my_seek_seq = player->latest_seek_seq.load(std::memory_order_acquire);
            double target_sec = player->seek_target_sec.load(std::memory_order_acquire);
            bool accurate = player->seek_accurate.load(std::memory_order_acquire);

            player->executing_seek_seq.store(my_seek_seq, std::memory_order_release);
            player->seek_executing.store(true, std::memory_order_release);
            player->seek_requested.store(false, std::memory_order_release);

            struct SeekScopeGuard {
                std::atomic<bool>& flag;
                explicit SeekScopeGuard(std::atomic<bool>& f) : flag(f) {}
                ~SeekScopeGuard() { flag.store(false, std::memory_order_release); }
            } seek_guard(player->seek_executing);

            // Silence stale pre-seek audio immediately before blocking network seek so UI/audio never glitch
            while (player->audio_queue_starting.load(std::memory_order_acquire) && !player->abort_requested.load()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            if (player->audio_queue && player->audio_queue_started.exchange(false, std::memory_order_acq_rel)) {
                AudioQueueStop(player->audio_queue, true);
                AudioQueueReset(player->audio_queue);
            }

            dk_clear_avio_error_state(player->format_ctx);
            int64_t target_ts = static_cast<int64_t>(target_sec * AV_TIME_BASE);
            int seek_ret = avformat_seek_file(player->format_ctx, -1, INT64_MIN, target_ts, target_ts, AVSEEK_FLAG_BACKWARD);
            if (seek_ret < 0 &&
                !player->abort_requested.load() &&
                player->latest_seek_seq.load(std::memory_order_acquire) == my_seek_seq) {
                dk_clear_avio_error_state(player->format_ctx);
                seek_ret = av_seek_frame(player->format_ctx, -1, target_ts, AVSEEK_FLAG_BACKWARD);
            }
            dk_clear_avio_error_state(player->format_ctx);

            if (player->abort_requested.load()) break;
            // If another seek arrived while we were seeking, immediately re-seek to the latest target
            if (player->latest_seek_seq.load(std::memory_order_acquire) != my_seek_seq) {
                continue;
            }
            if (seek_ret < 0) {
                char errbuf[256];
                av_strerror(seek_ret, errbuf, sizeof(errbuf));
                dk_log(1, "DKEngine Warning: Seek to %.2fs returned %d (%s)", target_sec, seek_ret, errbuf);
            }

            player->demux_eof.store(false);
            player->video_eof.store(false);
            player->audio_eof.store(false);
            const double drop_until = accurate ? target_sec : -1.0;
            player->video_seek_drop_until_pts.store(drop_until, std::memory_order_relaxed);
            player->audio_seek_drop_until_pts.store(drop_until, std::memory_order_relaxed);
            consecutive_io_errors = 0;
            av_packet_unref(pkt);

            // Flush packet queues
            {
                std::lock_guard<std::mutex> v_lock(player->video_pkt_mtx);
                while (!player->video_pkt_queue.empty()) {
                    AVPacket* p = player->video_pkt_queue.front();
                    player->video_pkt_queue.pop();
                    if (p) av_packet_free(&p);
                }
            }
            {
                std::lock_guard<std::mutex> a_lock(player->audio_pkt_mtx);
                while (!player->audio_pkt_queue.empty()) {
                    AVPacket* p = player->audio_pkt_queue.front();
                    player->audio_pkt_queue.pop();
                    if (p) av_packet_free(&p);
                }
            }
            player->queued_pkt_bytes.store(0, std::memory_order_relaxed);
            player->last_demuxed_pts.store(target_sec, std::memory_order_relaxed);

            // Flush decoders
            {
                std::lock_guard<std::mutex> vlk(player->video_codec_mtx);
                if (player->video_codec_ctx) avcodec_flush_buffers(player->video_codec_ctx);
            }
            {
                std::lock_guard<std::mutex> alk(player->audio_codec_mtx);
                if (player->audio_codec_ctx) avcodec_flush_buffers(player->audio_codec_ctx);
            }
            {
                std::lock_guard<std::mutex> slk(player->ass_mtx);
                if (player->sub_stream_idx.load(std::memory_order_relaxed) >= 0) {
                    if (player->sub_codec_ctx) avcodec_flush_buffers(player->sub_codec_ctx);
                    if (player->ass_track) ass_flush_events(player->ass_track);
                    player->primary_ass_events.clear();
                    player->pgs_cues.clear();
                    player->pgs_generation++;
                }
                if (player->secondary_sub_stream_idx.load(std::memory_order_relaxed) >= 0) {
                    if (player->secondary_sub_codec_ctx) avcodec_flush_buffers(player->secondary_sub_codec_ctx);
                    if (player->secondary_ass_track) ass_flush_events(player->secondary_ass_track);
                    player->secondary_ass_events.clear();
                }
                if (!player->sub_rgba_buf.empty() && player->ass_canvas_w > 0 && player->ass_canvas_h > 0) {
                    int y0 = std::clamp(player->sub_dirty_y0, 0, player->ass_canvas_h);
                    int y1 = std::clamp(player->sub_dirty_y1, y0, player->ass_canvas_h);
                    if (y1 > y0) {
                        const size_t row_bytes = static_cast<size_t>(player->ass_canvas_w) * 4;
                        const size_t offset = static_cast<size_t>(y0) * row_bytes;
                        const size_t len = static_cast<size_t>(y1 - y0) * row_bytes;
                        if (offset + len <= player->sub_rgba_buf.size()) {
                            std::memset(player->sub_rgba_buf.data() + offset, 0, len);
                        }
                    }
                }
                player->rendered_pgs_gen = 0;
                player->sub_last_non_empty = false;
                player->sub_dirty_y0 = 0;
                player->sub_dirty_y1 = 0;
                player->sub_serial++;
            }
            dk_clear_sub_pkt_history(player);

            // Flush video decoded frames
            {
                std::lock_guard<std::mutex> vf_lock(player->video_queue_mtx);
                while (!player->video_queue.empty()) {
                    CVPixelBufferRelease(player->video_queue.front().pixel_buffer);
                    player->video_queue.pop();
                }
                player->last_decoded_video_pts = target_sec;
            }

            // Flush audio queue and AudioQueue hardware buffers
            {
                std::lock_guard<std::mutex> aq_lock(player->audio_queue_mtx);
                player->audio_chunks.clear();
                player->buffered_audio_samples.store(0);
                player->audio_clock_base_pts.store(target_sec);
                player->audio_clock_calibrated.store(false);
                player->audio_clock_base_sample_time.store(0);
                player->audio_underrun_samples.store(0);
                player->audio_consecutive_underrun_samples.store(0);
                player->fallback_audio_clock.store(target_sec);
                player->fallback_clock_ns.store(dk_steady_now_ns(), std::memory_order_relaxed);
            }
            player->audio_rebuffer_count.store(0, std::memory_order_relaxed);
            player->audio_start_fail_count.store(0, std::memory_order_relaxed);
            player->audio_hal_disabled.store(false, std::memory_order_relaxed);

            if (player->audio_queue && player->audio_queue_started.exchange(false, std::memory_order_acq_rel)) {
                AudioQueueStop(player->audio_queue, true);
                AudioQueueReset(player->audio_queue);
            }

            player->ext_clock_base_pts.store(target_sec);
            player->ext_clock_start_ns.store(dk_steady_now_ns(), std::memory_order_relaxed);
            player->current_pos_sec.store(target_sec);

            {
                std::lock_guard<std::mutex> sl(player->speed_mtx);
                player->last_speed_bytes = player->total_bytes_read.load(std::memory_order_relaxed);
                player->last_speed_time = std::chrono::steady_clock::now();
                player->instant_download_speed_mbs.store(0.0, std::memory_order_relaxed);
            }

            dk_log(0, "DKEngine: Seek completed to %.2fs (accurate=%d)", target_sec, accurate ? 1 : 0);
            const DKPlayerState cur_st = player->state.load();
            const bool was_paused = (cur_st == DK_STATE_PAUSED || cur_st == DK_STATE_ENDED);
            if (cur_st == DK_STATE_ENDED) {
                player->state.store(DK_STATE_PAUSED);
            }
            player->seek_preview_pending.store(was_paused, std::memory_order_release);
            player->force_present_next_frame.store(true, std::memory_order_release);
            player->seek_executing.store(false, std::memory_order_release);
            player->video_decode_cv.notify_all();
            player->audio_decode_cv.notify_all();
            player->video_frame_cv.notify_all();
            continue;
        }

        // Bounded buffering flow control
        size_t v_pkts = 0;
        size_t a_pkts = 0;
        {
            std::lock_guard<std::mutex> vl(player->video_pkt_mtx);
            v_pkts = player->video_pkt_queue.size();
        }
        {
            std::lock_guard<std::mutex> al(player->audio_pkt_mtx);
            a_pkts = player->audio_pkt_queue.size();
        }

        const double cur_pts = std::max(0.0, dk_get_master_clock(player));
        const double ahead_sec = std::max(0.0, player->last_demuxed_pts.load(std::memory_order_relaxed) - cur_pts);
        const int64_t total_pkt_bytes = player->queued_pkt_bytes.load(std::memory_order_relaxed);

        const bool time_enough = (player->video_stream_idx < 0) ? (a_pkts >= 1500) : (ahead_sec >= 90.0 && v_pkts >= 60);
        const bool pkts_enough = (v_pkts >= 2500);
        const int64_t buffer_limit_bytes = player->max_buffer_bytes.load(std::memory_order_relaxed);
        const bool mem_enough = (total_pkt_bytes >= buffer_limit_bytes);

        if (time_enough || pkts_enough || mem_enough) {
            std::unique_lock<std::mutex> lock(player->demux_mtx);
            player->demux_cv.wait_for(lock, std::chrono::milliseconds(15));
            continue;
        }

        int ret = av_read_frame(player->format_ctx, pkt);
        if (ret < 0) {
            if (player->abort_requested.load() || player->is_closing.load()) break;
            if (player->seek_requested.load(std::memory_order_acquire)) {
                dk_clear_avio_error_state(player->format_ctx);
                continue;
            }
            if (ret == AVERROR_EOF) {
                consecutive_io_errors = 0;
                if (!player->demux_eof.exchange(true)) {
                    {
                        std::lock_guard<std::mutex> lock(player->video_pkt_mtx);
                        player->video_pkt_queue.push(nullptr);
                    }
                    player->video_decode_cv.notify_one();
                    {
                        std::lock_guard<std::mutex> lock(player->audio_pkt_mtx);
                        player->audio_pkt_queue.push(nullptr);
                    }
                    player->audio_decode_cv.notify_one();
                }
                std::unique_lock<std::mutex> lock(player->demux_mtx);
                player->demux_cv.wait_for(lock, std::chrono::milliseconds(50), [player] {
                    return player->abort_requested.load() || player->seek_requested.load() || !player->demux_eof.load();
                });
                continue;
            }
            if (ret == AVERROR(EAGAIN)) {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
                continue;
            }
            consecutive_io_errors++;
            if (consecutive_io_errors == 1) {
                char errbuf[256];
                av_strerror(ret, errbuf, sizeof(errbuf));
                dk_log(1, "DKEngine Warning: av_read_frame failed (%d: %s), retrying", ret, errbuf);
            }
            if (consecutive_io_errors >= 10) {
                char errbuf[256];
                av_strerror(ret, errbuf, sizeof(errbuf));
                dk_log(2, "DKEngine Error: av_read_frame failed %d consecutive times (%d: %s), stopping playback", consecutive_io_errors, ret, errbuf);
                player->state.store(DK_STATE_ERROR);
                break;
            }
            if (player->format_ctx && player->format_ctx->pb) {
                int64_t retry_pos = avio_tell(player->format_ctx->pb);
                dk_clear_avio_error_state(player->format_ctx);
                if (retry_pos >= 0) {
                    avio_seek(player->format_ctx->pb, retry_pos, SEEK_SET);
                    dk_clear_avio_error_state(player->format_ctx);
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(120));
            continue;
        }
        consecutive_io_errors = 0;
        if (player->seek_requested.load(std::memory_order_acquire) ||
            (pkt->flags & AV_PKT_FLAG_CORRUPT) != 0) {
            av_packet_unref(pkt);
            dk_clear_avio_error_state(player->format_ctx);
            continue;
        }

        if (player->format_ctx && player->format_ctx->pb) {
            int64_t pb_bytes = player->format_ctx->pb->bytes_read;
            if (pb_bytes > 0 && pb_bytes > player->total_bytes_read.load(std::memory_order_relaxed)) {
                player->total_bytes_read.store(pb_bytes, std::memory_order_relaxed);
            } else if (!player->custom_io_read && pkt->size > 0 && pb_bytes <= 0) {
                player->total_bytes_read.fetch_add(pkt->size, std::memory_order_relaxed);
            }
        } else if (pkt->size > 0) {
            player->total_bytes_read.fetch_add(pkt->size, std::memory_order_relaxed);
        }

        if (pkt->stream_index == player->video_stream_idx ||
            pkt->stream_index == player->audio_stream_idx.load(std::memory_order_relaxed)) {
            int64_t raw_ts = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
            if (raw_ts != AV_NOPTS_VALUE && pkt->stream_index >= 0 &&
                static_cast<unsigned>(pkt->stream_index) < player->format_ctx->nb_streams) {
                double pkt_sec = raw_ts * av_q2d(player->format_ctx->streams[pkt->stream_index]->time_base);
                if (std::isfinite(pkt_sec) && pkt_sec > player->last_demuxed_pts.load(std::memory_order_relaxed)) {
                    player->last_demuxed_pts.store(pkt_sec, std::memory_order_relaxed);
                }
            }
        }

        if (pkt->stream_index == player->video_stream_idx) {
            if (!player->dovi_detected.load(std::memory_order_relaxed) &&
                dovi_probe_packets < 120 &&
                player->format_ctx &&
                player->format_ctx->streams[pkt->stream_index]->codecpar->codec_id == AV_CODEC_ID_HEVC) {
                dovi_probe_packets++;
                if (dk_rs_check_dovi_fel(pkt->data, pkt->size)) {
                    player->dovi_detected.store(true, std::memory_order_relaxed);
                    std::lock_guard<std::mutex> lock(player->stats_mtx);
                    player->stats.is_dolby_vision = true;
                }
            }
            AVPacket* v_copy = av_packet_alloc();
            av_packet_move_ref(v_copy, pkt);
            {
                std::lock_guard<std::mutex> lock(player->video_pkt_mtx);
                player->video_pkt_queue.push(v_copy);
                player->queued_pkt_bytes.fetch_add(v_copy->size, std::memory_order_relaxed);
            }
            player->video_decode_cv.notify_one();
        } else if (pkt->stream_index == player->audio_stream_idx.load(std::memory_order_relaxed)) {
            AVPacket* a_copy = av_packet_alloc();
            av_packet_move_ref(a_copy, pkt);
            {
                std::lock_guard<std::mutex> lock(player->audio_pkt_mtx);
                player->audio_pkt_queue.push(a_copy);
                player->queued_pkt_bytes.fetch_add(a_copy->size, std::memory_order_relaxed);
            }
            player->audio_decode_cv.notify_one();
        } else if (pkt->stream_index >= 0 &&
                   static_cast<unsigned>(pkt->stream_index) < player->format_ctx->nb_streams &&
                   player->format_ctx->streams[pkt->stream_index]->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            dk_record_sub_pkt_history(player, pkt);
            if (pkt->stream_index == player->sub_stream_idx.load(std::memory_order_relaxed) ||
                pkt->stream_index == player->secondary_sub_stream_idx.load(std::memory_order_relaxed)) {
                dk_decode_subtitle_packet(player, pkt);
            }
            av_packet_unref(pkt);
        } else {
            av_packet_unref(pkt);
        }
    }

    av_packet_free(&pkt);
}

DKPlayer* dk_player_create(void) {
    av_log_set_level(AV_LOG_INFO);
    av_log_set_callback(dk_ffmpeg_log_callback);
    DKPlayer* player = new DKPlayer();

    player->ass_lib = ass_library_init();
    if (player->ass_lib) {
        player->ass_renderer = ass_renderer_init(player->ass_lib);
        if (player->ass_renderer) {
            ass_set_fonts(player->ass_renderer, nullptr, "PingFang SC", 1, nullptr, 1);
        }
    }
    {
        std::lock_guard<std::mutex> lk(dk_registry_mutex());
        dk_live_players().push_back(player);
    }
    dk_log(0, "DKEngine: Created native player instance (libass initialized)");
    return player;
}

void dk_player_destroy(DKPlayer* player) {
    if (!player) return;
    {
        std::lock_guard<std::mutex> lk(dk_registry_mutex());
        auto& vec = dk_live_players();
        auto it = std::find(vec.begin(), vec.end(), player);
        if (it == vec.end()) {
            return;
        }
        player->abort_requested.store(true, std::memory_order_release);
        vec.erase(it);
    }
    if (player->custom_io_abort && player->custom_io_opaque) {
        player->custom_io_abort(player->custom_io_opaque);
    }
    while (player->in_flight_readers.load(std::memory_order_acquire) > 0) {
        std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
    dk_player_close(player);

    if (player->ass_track) {
        ass_free_track(player->ass_track);
        player->ass_track = nullptr;
    }
    if (player->secondary_ass_track) {
        ass_free_track(player->secondary_ass_track);
        player->secondary_ass_track = nullptr;
    }
    if (player->ass_renderer) {
        ass_renderer_done(player->ass_renderer);
        player->ass_renderer = nullptr;
    }
    if (player->secondary_ass_renderer) {
        ass_renderer_done(player->secondary_ass_renderer);
        player->secondary_ass_renderer = nullptr;
    }
    if (player->ass_lib) {
        ass_library_done(player->ass_lib);
        player->ass_lib = nullptr;
    }

    delete player;
}

static std::string dk_normalize_path_or_url(const char* in_url) {
    if (!in_url) return "";
    std::string s = in_url;
    if (s.rfind("file://", 0) == 0) {
        s = s.substr(7);
    }
    if (s.find('%') != std::string::npos) {
        std::string decoded;
        decoded.reserve(s.size());
        for (size_t i = 0; i < s.size(); ++i) {
            if (s[i] == '%' && i + 2 < s.size()) {
                char hex[3] = { s[i+1], s[i+2], '\0' };
                char* endptr = nullptr;
                long val = std::strtol(hex, &endptr, 16);
                if (endptr == hex + 2) {
                    decoded.push_back(static_cast<char>(val));
                    i += 2;
                    continue;
                }
            }
            decoded.push_back(s[i]);
        }
        s = decoded;
    }
    return s;
}

bool dk_player_should_yield_read(DKPlayer* player) {
    if (!player) return false;
    if (player->abort_requested.load(std::memory_order_acquire) ||
        player->is_closing.load(std::memory_order_acquire)) {
        return true;
    }
    if (!player->seek_requested.load(std::memory_order_acquire)) {
        return false;
    }
    return !player->seek_executing.load(std::memory_order_acquire) ||
           player->latest_seek_seq.load(std::memory_order_acquire) !=
               player->executing_seek_seq.load(std::memory_order_acquire);
}

static int dk_avio_read_thunk(void* opaque, uint8_t* buf, int buf_size) {
    DKPlayer* player = static_cast<DKPlayer*>(opaque);
    if (!player || !player->custom_io_read) return AVERROR_EOF;
    if (player->abort_requested.load(std::memory_order_acquire) ||
        player->is_closing.load(std::memory_order_acquire)) {
        return AVERROR_EXIT;
    }
    int n = player->custom_io_read(player->custom_io_opaque, buf, buf_size);
    if (n > 0) {
        player->total_bytes_read.fetch_add(n, std::memory_order_relaxed);
        return n;
    }
    if (n == 0) {
        return AVERROR_EOF;
    }
    return dk_player_should_yield_read(player)
        ? AVERROR_EXIT
        : AVERROR(EIO);
}

static int64_t dk_avio_seek_thunk(void* opaque, int64_t offset, int whence) {
    DKPlayer* player = static_cast<DKPlayer*>(opaque);
    if (!player || !player->custom_io_seek) return AVERROR(ENOSYS);
    return player->custom_io_seek(player->custom_io_opaque, offset, whence);
}

void dk_player_set_custom_io(
    DKPlayer* player,
    void* opaque,
    DKCustomIOReadCallback read_cb,
    DKCustomIOSeekCallback seek_cb,
    DKCustomIOAbortCallback abort_cb,
    DKCustomIOCloseCallback close_cb
) {
    if (!player) return;
    player->custom_io_opaque = opaque;
    player->custom_io_read = read_cb;
    player->custom_io_seek = seek_cb;
    player->custom_io_abort = abort_cb;
    player->custom_io_close = close_cb;
}

void dk_player_request_abort(DKPlayer* player) {
    if (!player) return;
    std::lock_guard<std::mutex> lk(dk_registry_mutex());
    auto& vec = dk_live_players();
    if (std::find(vec.begin(), vec.end(), player) == vec.end()) {
        return;
    }
    player->external_abort_requested.store(true, std::memory_order_seq_cst);
    player->abort_requested.store(true, std::memory_order_seq_cst);
    if (player->custom_io_abort && player->custom_io_opaque) {
        player->custom_io_abort(player->custom_io_opaque);
    }
    player->demux_cv.notify_all();
    player->video_decode_cv.notify_all();
    player->audio_decode_cv.notify_all();
    player->video_frame_cv.notify_all();
}

int dk_player_open(DKPlayer* player, const char* url, const char* headers_crlf, double start_sec, bool hw_decode) {
    return dk_player_open_with_tracks(player, url, headers_crlf, start_sec, hw_decode, -1, -1);
}

static int dk_score_auto_subtitle_stream(const AVStream* st) {
    if (!st || !st->codecpar || st->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) return -1;
    auto to_lower = [](const char* s) -> std::string {
        std::string out = s ? s : "";
        for (char& ch : out) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
        return out;
    };
    const AVDictionaryEntry* lang_tag = av_dict_get(st->metadata, "language", nullptr, 0);
    const AVDictionaryEntry* title_tag = av_dict_get(st->metadata, "title", nullptr, 0);
    std::string lang = to_lower(lang_tag ? lang_tag->value : nullptr);
    std::string title = to_lower(title_tag ? title_tag->value : nullptr);
    std::string combined = lang + " " + title;

    int score = 0;
    bool is_chs = (combined.find("chs") != std::string::npos || combined.find("zh-cn") != std::string::npos ||
                   combined.find("zh_cn") != std::string::npos || combined.find("hans") != std::string::npos ||
                   combined.find("简") != std::string::npos);
    bool is_cht = (combined.find("cht") != std::string::npos || combined.find("zh-tw") != std::string::npos ||
                   combined.find("zh-hk") != std::string::npos || combined.find("hant") != std::string::npos ||
                   combined.find("繁") != std::string::npos);
    bool is_zh = is_chs || is_cht ||
                 (lang.find("chi") != std::string::npos || lang.find("zho") != std::string::npos || lang.find("zh") != std::string::npos ||
                  combined.find("中") != std::string::npos);

    if (is_chs) score += 100;
    else if (is_zh && !is_cht) score += 80;
    else if (is_cht) score += 50;

    enum AVCodecID cid = st->codecpar->codec_id;
    if (cid == AV_CODEC_ID_ASS || cid == AV_CODEC_ID_SSA) score += 15;
    else if (cid == AV_CODEC_ID_SUBRIP || cid == AV_CODEC_ID_SRT || cid == AV_CODEC_ID_TEXT) score += 12;

    if (st->disposition & AV_DISPOSITION_DEFAULT) score += 6;
    if (st->disposition & AV_DISPOSITION_FORCED) score -= 25;
    return score;
}

int dk_player_open_with_tracks(
    DKPlayer* player,
    const char* url,
    const char* headers_crlf,
    double start_sec,
    bool hw_decode,
    int32_t preferred_audio_hint,
    int32_t preferred_sub_hint
) {
    if (!player || !url) return -1;
    if (player->external_abort_requested.load(std::memory_order_seq_cst)) {
        player->state.store(DK_STATE_ERROR);
        return -1;
    }
    // Preserve any pending custom IO registered prior to open
    void* saved_io_opaque = player->custom_io_opaque;
    DKCustomIOReadCallback saved_io_read = player->custom_io_read;
    DKCustomIOSeekCallback saved_io_seek = player->custom_io_seek;
    DKCustomIOAbortCallback saved_io_abort = player->custom_io_abort;
    DKCustomIOCloseCallback saved_io_close = player->custom_io_close;
    player->custom_io_opaque = nullptr;
    player->custom_io_read = nullptr;
    player->custom_io_seek = nullptr;
    player->custom_io_abort = nullptr;
    player->custom_io_close = nullptr;

    dk_player_close(player);

    player->custom_io_opaque = saved_io_opaque;
    player->custom_io_read = saved_io_read;
    player->custom_io_seek = saved_io_seek;
    player->custom_io_abort = saved_io_abort;
    player->custom_io_close = saved_io_close;

    if (player->external_abort_requested.load(std::memory_order_seq_cst)) {
        if (player->custom_io_close && player->custom_io_opaque) {
            player->custom_io_close(player->custom_io_opaque);
            player->custom_io_opaque = nullptr;
        }
        player->state.store(DK_STATE_ERROR);
        return -1;
    }

    std::string normalized_url = dk_normalize_path_or_url(url);
    const char* open_target = normalized_url.c_str();
    bool is_local_file = (!normalized_url.empty() && normalized_url[0] == '/');
    const bool use_custom_io = (player->custom_io_read != nullptr && player->custom_io_opaque != nullptr);

    auto redact_url_for_log = [](const std::string& raw) -> std::string {
        size_t q = raw.find('?');
        std::string base = (q != std::string::npos) ? (raw.substr(0, q) + "?<REDACTED>") : raw;
        size_t scheme = base.find("://");
        if (scheme != std::string::npos) {
            size_t host_start = scheme + 3;
            size_t slash = base.find('/', host_start);
            if (slash != std::string::npos) {
                return base.substr(0, host_start) + "<HOST>" + base.substr(slash);
            }
            return base.substr(0, host_start) + "<HOST>";
        }
        return base;
    };
    std::string safe_log_url = is_local_file ? normalized_url : redact_url_for_log(normalized_url);
    dk_log(0, "DKEngine: Opening URL: %s (local=%d, custom_io=%d, hw_decode=%d, start=%.2fs)",
           safe_log_url.c_str(), is_local_file ? 1 : 0, use_custom_io ? 1 : 0, hw_decode ? 1 : 0, start_sec);
    auto start_time = std::chrono::steady_clock::now();

    player->state.store(DK_STATE_OPENING);
    player->is_closing.store(false);
    player->current_url = open_target;
    player->hw_decode_enabled = hw_decode;
    player->vt_failed.store(false);
    player->dovi_detected.store(false);
    player->stream_dovi_profile = 0;
    player->demux_eof.store(false);
    player->video_eof.store(false);
    player->audio_eof.store(false);
    player->video_seek_drop_until_pts.store(-1.0);
    player->audio_seek_drop_until_pts.store(-1.0);
    player->queued_pkt_bytes.store(0);
    dk_clear_sub_pkt_history(player);
    player->audio_rebuffer_count.store(0);
    player->audio_start_fail_count.store(0);
    player->last_audio_start_attempt_ns.store(0);
    player->audio_steady_start_ns.store(0);
    player->audio_hal_disabled.store(false);
    player->last_demuxed_pts.store(std::max(0.0, start_sec));
    player->last_decoded_video_pts = -1.0;
    player->abort_requested.store(false, std::memory_order_seq_cst);
    if (player->external_abort_requested.load(std::memory_order_seq_cst)) {
        player->abort_requested.store(true, std::memory_order_seq_cst);
        if (player->custom_io_close && player->custom_io_opaque) {
            player->custom_io_close(player->custom_io_opaque);
            player->custom_io_opaque = nullptr;
        }
        player->state.store(DK_STATE_ERROR);
        return -1;
    }
    player->seek_requested.store(false);
    player->seek_preview_pending.store(false);
    player->force_present_next_frame.store(false);
    player->video_stream_idx = -1;
    player->audio_stream_idx.store(-1);
    player->sub_stream_idx.store(-1);
    player->secondary_sub_stream_idx.store(-1);
    {
        std::lock_guard<std::mutex> lk(player->stats_mtx);
        player->stats = DKRuntimeStats{};
    }

    AVDictionary* opts = nullptr;
    const bool has_start_seek = (start_sec > 0.5);
    const bool is_mpeg_ts = (normalized_url.find(".ts") != std::string::npos ||
                             normalized_url.find(".m2ts") != std::string::npos);
    const char* probe_bytes = is_mpeg_ts ? "4194304" : "1048576";
    const char* analyze_us = is_mpeg_ts ? "2000000" : (has_start_seek ? "500000" : "600000");

    if (is_local_file || use_custom_io) {
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
        if (headers_crlf && std::strlen(headers_crlf) > 0) {
            av_dict_set(&opts, "headers", headers_crlf, 0);
        }
    }

    player->format_ctx = avformat_alloc_context();
    if (!player->format_ctx) {
        av_dict_free(&opts);
        dk_log(2, "DKEngine Error: avformat_alloc_context failed");
        player->state.store(DK_STATE_ERROR);
        return -1;
    }

    // Register interrupt callback to guarantee clean abort during network stalls
    player->format_ctx->interrupt_callback.callback = dk_interrupt_callback;
    player->format_ctx->interrupt_callback.opaque = player;

    if (use_custom_io) {
        constexpr int kAvioBufSize = 256 * 1024;
        uint8_t* avio_buf = static_cast<uint8_t*>(av_malloc(kAvioBufSize));
        if (avio_buf) {
            player->custom_avio_ctx = avio_alloc_context(
                avio_buf,
                kAvioBufSize,
                0,
                player,
                dk_avio_read_thunk,
                nullptr,
                player->custom_io_seek ? dk_avio_seek_thunk : nullptr
            );
            if (player->custom_avio_ctx) {
                player->format_ctx->pb = player->custom_avio_ctx;
                player->format_ctx->flags |= AVFMT_FLAG_CUSTOM_IO;
            } else {
                av_free(avio_buf);
            }
        }
    }

    int open_ret = avformat_open_input(
        &player->format_ctx,
        (use_custom_io && player->custom_avio_ctx) ? nullptr : open_target,
        nullptr,
        &opts
    );
    av_dict_free(&opts);
    auto after_open_input = std::chrono::steady_clock::now();
    if (open_ret < 0 || player->abort_requested.load(std::memory_order_seq_cst) || player->external_abort_requested.load(std::memory_order_seq_cst)) {
        char errbuf[256];
        av_strerror(open_ret, errbuf, sizeof(errbuf));
        dk_log(2, "DKEngine Error: avformat_open_input failed (%d: %s)", open_ret, errbuf);
        if (open_ret >= 0 && player->format_ctx) {
            avformat_close_input(&player->format_ctx);
        } else if (player->format_ctx) {
            player->format_ctx->pb = nullptr;
            avformat_free_context(player->format_ctx);
            player->format_ctx = nullptr;
        }
        if (player->custom_avio_ctx) {
            av_freep(&player->custom_avio_ctx->buffer);
            avio_context_free(&player->custom_avio_ctx);
        }
        if (player->custom_io_close && player->custom_io_opaque) {
            player->custom_io_close(player->custom_io_opaque);
            player->custom_io_opaque = nullptr;
        }
        player->state.store(DK_STATE_ERROR);
        return -1;
    }

    // Bound FPS probing and avoid exhausting probesize/analyzeduration on attachments, data streams,
    // or bitmap PGS/DVD subtitles whose MKV headers report 0x0 size until the first dialogue packet.
    player->format_ctx->fps_probe_size = 4;
    player->format_ctx->max_probe_packets = 200;
    struct SavedSubProbeState {
        AVDiscard discard = AVDISCARD_DEFAULT;
        bool seeded_dims = false;
    };
    std::vector<SavedSubProbeState> saved_sub_states(player->format_ctx->nb_streams);
    for (unsigned int i = 0; i < player->format_ctx->nb_streams; i++) {
        AVStream* st = player->format_ctx->streams[i];
        if (!st || !st->codecpar) continue;
        if (st->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT ||
            st->codecpar->codec_type == AVMEDIA_TYPE_DATA) {
            st->discard = AVDISCARD_ALL;
        } else if (st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            saved_sub_states[i].discard = st->discard;
            st->discard = AVDISCARD_ALL;
            if ((st->codecpar->codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE ||
                 st->codecpar->codec_id == AV_CODEC_ID_DVD_SUBTITLE) &&
                (st->codecpar->width == 0 || st->codecpar->height == 0)) {
                st->codecpar->width = 1920;
                st->codecpar->height = 1080;
                saved_sub_states[i].seeded_dims = true;
            }
        }
    }

    if (avformat_find_stream_info(player->format_ctx, nullptr) < 0 ||
        player->abort_requested.load(std::memory_order_seq_cst) ||
        player->external_abort_requested.load(std::memory_order_seq_cst)) {
        dk_log(2, "DKEngine Error: avformat_find_stream_info failed");
        avformat_close_input(&player->format_ctx);
        if (player->custom_avio_ctx) {
            av_freep(&player->custom_avio_ctx->buffer);
            avio_context_free(&player->custom_avio_ctx);
        }
        if (player->custom_io_close && player->custom_io_opaque) {
            player->custom_io_close(player->custom_io_opaque);
            player->custom_io_opaque = nullptr;
        }
        player->state.store(DK_STATE_ERROR);
        return -1;
    }

    // Restore subtitle stream discard & original dimensions so PGS/DVD decoders read true canvas size from packets.
    for (unsigned int i = 0; i < player->format_ctx->nb_streams && i < saved_sub_states.size(); i++) {
        AVStream* st = player->format_ctx->streams[i];
        if (st && st->codecpar && st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            st->discard = saved_sub_states[i].discard;
            if (saved_sub_states[i].seeded_dims) {
                st->codecpar->width = 0;
                st->codecpar->height = 0;
            }
        }
    }

    auto after_find_stream = std::chrono::steady_clock::now();
    auto open_input_ms = std::chrono::duration<double, std::milli>(after_open_input - start_time).count();
    auto find_stream_ms = std::chrono::duration<double, std::milli>(after_find_stream - after_open_input).count();
    auto open_elapsed = std::chrono::duration<double, std::milli>(after_find_stream - start_time).count();
    dk_log(0, "DKEngine: Stream connected and parsed in %.1fms (open_input=%.1fms, find_stream=%.1fms, nb_streams=%u)",
           open_elapsed, open_input_ms, find_stream_ms, player->format_ctx->nb_streams);

    if (player->format_ctx->duration > 0) {
        player->duration_sec = static_cast<double>(player->format_ctx->duration) / AV_TIME_BASE;
    } else {
        player->duration_sec = 0.0;
    }

    int preferred_audio_idx = -1;
    if (preferred_audio_hint >= 0 &&
        static_cast<unsigned int>(preferred_audio_hint) < player->format_ctx->nb_streams &&
        player->format_ctx->streams[preferred_audio_hint]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
        preferred_audio_idx = preferred_audio_hint;
    }

    int preferred_sub_idx = -1;
    bool disable_auto_sub = (preferred_sub_hint == -2);
    if (preferred_sub_hint >= 0 &&
        static_cast<unsigned int>(preferred_sub_hint) < player->format_ctx->nb_streams &&
        player->format_ctx->streams[preferred_sub_hint]->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
        preferred_sub_idx = preferred_sub_hint;
    }

    int best_sub_score = -1000;
    for (unsigned int i = 0; i < player->format_ctx->nb_streams; i++) {
        AVStream* st = player->format_ctx->streams[i];
        if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && preferred_audio_hint < 0) {
            if (preferred_audio_idx < 0 || (st->disposition & AV_DISPOSITION_DEFAULT)) {
                if (preferred_audio_idx < 0 || !(player->format_ctx->streams[preferred_audio_idx]->disposition & AV_DISPOSITION_DEFAULT)) {
                    preferred_audio_idx = static_cast<int>(i);
                }
            }
        } else if (st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE && !disable_auto_sub && preferred_sub_hint < 0) {
            int sc = dk_score_auto_subtitle_stream(st);
            if (preferred_sub_idx < 0 || sc > best_sub_score) {
                preferred_sub_idx = static_cast<int>(i);
                best_sub_score = sc;
            }
        }
    }

    for (unsigned int i = 0; i < player->format_ctx->nb_streams; i++) {
        AVStream* st = player->format_ctx->streams[i];
        if (st->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && player->video_stream_idx < 0 && !(st->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            player->video_stream_idx = i;

            for (int sd_i = 0; sd_i < st->codecpar->nb_coded_side_data; sd_i++) {
                const AVPacketSideData& sd = st->codecpar->coded_side_data[sd_i];
                if (sd.type == AV_PKT_DATA_DOVI_CONF && sd.data && sd.size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
                    const auto* dovi_conf = reinterpret_cast<const AVDOVIDecoderConfigurationRecord*>(sd.data);
                    player->stream_dovi_profile = dovi_conf->dv_profile;
                    player->dovi_detected.store(true, std::memory_order_relaxed);
                    player->stats.is_dolby_vision = true;
                    player->stats.is_hdr = true;
                    dk_log(0, "DKEngine: Detected Dolby Vision Configuration Record (profile=%u, level=%u, compat=%u)",
                           dovi_conf->dv_profile, dovi_conf->dv_level, dovi_conf->dv_bl_signal_compatibility_id);
                }
            }

            const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
            if (dec) {
                player->video_codec_ctx = avcodec_alloc_context3(dec);
                avcodec_parameters_to_context(player->video_codec_ctx, st->codecpar);
                player->video_codec_ctx->opaque = player;
                player->video_codec_ctx->pkt_timebase = st->time_base;

                if (hw_decode) {
                    if (av_hwdevice_ctx_create(&player->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0) == 0) {
                        player->video_codec_ctx->hw_device_ctx = av_buffer_ref(player->hw_device_ctx);
                        player->video_codec_ctx->get_format = dk_get_hw_format;
                        player->video_codec_ctx->hwaccel_flags |= AV_HWACCEL_FLAG_IGNORE_LEVEL |
                                                                  AV_HWACCEL_FLAG_ALLOW_HIGH_DEPTH |
                                                                  AV_HWACCEL_FLAG_ALLOW_PROFILE_MISMATCH;
                        player->stats.is_hw_accelerated = true;
                    }
                }
                if (!player->stats.is_hw_accelerated) {
                    unsigned hc = std::thread::hardware_concurrency();
                    player->video_codec_ctx->thread_count = static_cast<int>(std::clamp<unsigned>(hc > 0 ? hc : 4, 2, 8));
                    player->video_codec_ctx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
                }
                if (avcodec_open2(player->video_codec_ctx, dec, nullptr) < 0) {
                    bool opened_sw = false;
                    if (player->stats.is_hw_accelerated) {
                        if (player->hw_device_ctx) {
                            av_buffer_unref(&player->hw_device_ctx);
                        }
                        player->stats.is_hw_accelerated = false;
                        opened_sw = dk_fallback_video_to_software(player);
                    }
                    if (!opened_sw) {
                        avcodec_free_context(&player->video_codec_ctx);
                        player->video_stream_idx = -1;
                        continue;
                    }
                }

                player->stats.width = st->codecpar->width;
                player->stats.height = st->codecpar->height;
                player->stats.fps = av_q2d(st->avg_frame_rate);
                if (player->stats.fps <= 0.0) {
                    player->stats.fps = av_q2d(st->r_frame_rate);
                }

                const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(static_cast<AVPixelFormat>(st->codecpar->format));
                player->stats.bit_depth = (desc && desc->comp[0].depth > 0) ? desc->comp[0].depth : 8;

                if (st->codecpar->bit_rate > 0) {
                    player->stats.video_bitrate_mbps = static_cast<double>(st->codecpar->bit_rate) / 1000000.0;
                } else if (player->format_ctx->bit_rate > 0) {
                    player->stats.video_bitrate_mbps = static_cast<double>(player->format_ctx->bit_rate) / 1000000.0;
                }
                player->atomic_video_bitrate_mbps.store(player->stats.video_bitrate_mbps, std::memory_order_relaxed);

                bool is_hdr = false;
                if (player->stats.is_dolby_vision) {
                    std::snprintf(player->stats.color_space, sizeof(player->stats.color_space), "Dolby Vision P%u", player->stream_dovi_profile);
                    is_hdr = true;
                } else if (st->codecpar->color_trc == AVCOL_TRC_SMPTE2084) {
                    std::snprintf(player->stats.color_space, sizeof(player->stats.color_space), "BT.2020 PQ (HDR10)");
                    is_hdr = true;
                } else if (st->codecpar->color_trc == AVCOL_TRC_ARIB_STD_B67) {
                    std::snprintf(player->stats.color_space, sizeof(player->stats.color_space), "BT.2020 HLG");
                    is_hdr = true;
                } else if (st->codecpar->color_primaries == AVCOL_PRI_BT2020) {
                    std::snprintf(player->stats.color_space, sizeof(player->stats.color_space), "BT.2020");
                } else if (st->codecpar->color_primaries == AVCOL_PRI_BT709) {
                    std::snprintf(player->stats.color_space, sizeof(player->stats.color_space), "BT.709 (SDR)");
                } else {
                    std::snprintf(player->stats.color_space, sizeof(player->stats.color_space), "Auto/SDR");
                }
                player->stats.is_hdr = is_hdr;

                std::snprintf(player->stats.video_codec, sizeof(player->stats.video_codec), "%s", dec->name);
                dk_log(0, "DKEngine: Video Stream #%u: %s %dx%d @ %.2ffps (accel=%s, depth=%dbit)",
                       i, dec->name, st->codecpar->width, st->codecpar->height, player->stats.fps,
                       player->stats.is_hw_accelerated ? "VideoToolbox" : "Software", player->stats.bit_depth);
            }
        } else if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && player->audio_stream_idx < 0 &&
                   (preferred_audio_idx < 0 || static_cast<int>(i) == preferred_audio_idx)) {
            player->audio_stream_idx = i;
            const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
            if (dec) {
                player->audio_codec_ctx = avcodec_alloc_context3(dec);
                avcodec_parameters_to_context(player->audio_codec_ctx, st->codecpar);
                player->audio_codec_ctx->pkt_timebase = st->time_base;
                if (avcodec_open2(player->audio_codec_ctx, dec, nullptr) == 0) {
                    dk_setup_swr(player);
                    std::snprintf(player->stats.audio_codec, sizeof(player->stats.audio_codec), "%s", dec->name);
                    dk_log(0, "DKEngine: Audio Stream #%u: %s (%d channels, %dHz)",
                           i, dec->name, st->codecpar->ch_layout.nb_channels, st->codecpar->sample_rate);
                } else {
                    avcodec_free_context(&player->audio_codec_ctx);
                    player->audio_stream_idx = -1;
                }
            }
        } else if (st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE && player->sub_stream_idx < 0 && !disable_auto_sub &&
                   (preferred_sub_idx < 0 || static_cast<int>(i) == preferred_sub_idx)) {
            player->sub_stream_idx = i;
        }
    }

    if (player->audio_codec_ctx && player->swr_ctx) {
        dk_init_audio_queue(player);
    }

    {
        std::lock_guard<std::mutex> slk(player->ass_mtx);
        if (player->sub_stream_idx >= 0) {
            dk_open_subtitle_decoder_locked(player, player->sub_stream_idx);
        } else if (player->ass_lib && !player->ass_track) {
            player->ass_track = ass_new_track(player->ass_lib);
            dk_ensure_default_ass_track_header(player);
        }
    }

    player->audio_clock_calibrated.store(false);
    player->audio_clock_base_sample_time.store(0);
    player->audio_underrun_samples.store(0);
    player->audio_consecutive_underrun_samples.store(0);
    if (start_sec > 0.5) {
        int64_t target_ts = static_cast<int64_t>(start_sec * AV_TIME_BASE);
        avformat_seek_file(player->format_ctx, -1, INT64_MIN, target_ts, target_ts, AVSEEK_FLAG_BACKWARD);
        // Resume at nearest keyframe for instant startup without decoding & dropping seconds of remote 4K video
        player->video_seek_drop_until_pts.store(-1.0);
        player->audio_seek_drop_until_pts.store(-1.0);
        player->force_present_next_frame.store(true, std::memory_order_release);
        player->current_pos_sec.store(start_sec);
        player->audio_clock_base_pts.store(start_sec);
        player->ext_clock_base_pts.store(start_sec);
        player->fallback_audio_clock.store(start_sec);
    } else {
        player->current_pos_sec.store(0.0);
        player->audio_clock_base_pts.store(0.0);
        player->ext_clock_base_pts.store(0.0);
        player->fallback_audio_clock.store(0.0);
    }

    int64_t now_ns = dk_steady_now_ns();
    player->ext_clock_start_ns.store(now_ns, std::memory_order_relaxed);
    player->fallback_clock_ns.store(now_ns, std::memory_order_relaxed);

    if (player->abort_requested.load(std::memory_order_seq_cst) ||
        player->external_abort_requested.load(std::memory_order_seq_cst)) {
        player->state.store(DK_STATE_ERROR);
        return -1;
    }

    player->demux_thread = std::thread(dk_demux_worker, player);
    if (player->video_codec_ctx) {
        player->video_decode_thread = std::thread(dk_video_decode_worker, player);
    }
    if (player->audio_codec_ctx) {
        player->audio_decode_thread = std::thread(dk_audio_decode_worker, player);
    }

    player->state.store(DK_STATE_PLAYING);
    return 0;
}

void dk_player_close(DKPlayer* player) {
    if (!player) return;
    bool expected = false;
    if (!player->is_closing.compare_exchange_strong(expected, true)) {
        return;
    }
    player->abort_requested.store(true);
    if (player->custom_io_abort && player->custom_io_opaque) {
        player->custom_io_abort(player->custom_io_opaque);
    }

    while (player->in_flight_readers.load(std::memory_order_acquire) > 0) {
        std::this_thread::sleep_for(std::chrono::microseconds(200));
    }

    player->demux_cv.notify_all();
    player->video_decode_cv.notify_all();
    player->audio_decode_cv.notify_all();
    player->video_frame_cv.notify_all();

    if (player->demux_thread.joinable()) player->demux_thread.join();
    if (player->video_decode_thread.joinable()) player->video_decode_thread.join();
    if (player->audio_decode_thread.joinable()) player->audio_decode_thread.join();

    if (player->audio_queue) {
        while (player->audio_queue_starting.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        AudioQueueStop(player->audio_queue, true);
        AudioQueueDispose(player->audio_queue, true);
        player->audio_queue = nullptr;
    }

    {
        std::lock_guard<std::mutex> lock(player->video_pkt_mtx);
        while (!player->video_pkt_queue.empty()) {
            AVPacket* p = player->video_pkt_queue.front();
            player->video_pkt_queue.pop();
            if (p) av_packet_free(&p);
        }
    }
    {
        std::lock_guard<std::mutex> lock(player->audio_pkt_mtx);
        while (!player->audio_pkt_queue.empty()) {
            AVPacket* p = player->audio_pkt_queue.front();
            player->audio_pkt_queue.pop();
            if (p) av_packet_free(&p);
        }
    }
    player->queued_pkt_bytes.store(0);
    dk_clear_sub_pkt_history(player);

    {
        std::lock_guard<std::mutex> lock(player->video_queue_mtx);
        while (!player->video_queue.empty()) {
            CVPixelBufferRelease(player->video_queue.front().pixel_buffer);
            player->video_queue.pop();
        }
        if (player->last_frame) {
            CVPixelBufferRelease(player->last_frame);
            player->last_frame = nullptr;
        }
    }

    {
        std::lock_guard<std::mutex> lock(player->audio_queue_mtx);
        player->audio_chunks.clear();
        player->buffered_audio_samples.store(0);
    }

    if (player->swr_ctx) {
        swr_free(&player->swr_ctx);
    }
    if (player->sws_ctx) {
        sws_freeContext(player->sws_ctx);
        player->sws_ctx = nullptr;
    }
    if (player->sw_pool) {
        CVPixelBufferPoolRelease(player->sw_pool);
        player->sw_pool = nullptr;
    }

    {
        std::lock_guard<std::mutex> slk(player->ass_mtx);
        if (player->sub_codec_ctx) {
            avcodec_free_context(&player->sub_codec_ctx);
        }
        if (player->secondary_sub_codec_ctx) {
            avcodec_free_context(&player->secondary_sub_codec_ctx);
        }
        if (player->secondary_ass_track) {
            ass_free_track(player->secondary_ass_track);
            player->secondary_ass_track = nullptr;
        }
        player->primary_ass_events.clear();
        player->secondary_ass_events.clear();
        player->primary_codec_private.clear();
        player->secondary_codec_private.clear();
        player->primary_ext_raw.clear();
        player->secondary_ext_raw.clear();
        player->pgs_cues.clear();
    }

    if (player->video_codec_ctx) { avcodec_free_context(&player->video_codec_ctx); }
    if (player->audio_codec_ctx) { avcodec_free_context(&player->audio_codec_ctx); }
    if (player->hw_device_ctx) { av_buffer_unref(&player->hw_device_ctx); }
    if (player->format_ctx) {
        if (player->custom_avio_ctx) {
            player->format_ctx->pb = nullptr;
        }
        avformat_close_input(&player->format_ctx);
    }
    if (player->custom_avio_ctx) {
        av_freep(&player->custom_avio_ctx->buffer);
        avio_context_free(&player->custom_avio_ctx);
    }
    if (player->custom_io_close && player->custom_io_opaque) {
        player->custom_io_close(player->custom_io_opaque);
    }
    player->custom_io_opaque = nullptr;
    player->custom_io_read = nullptr;
    player->custom_io_seek = nullptr;
    player->custom_io_abort = nullptr;
    player->custom_io_close = nullptr;

    player->video_stream_idx = -1;
    player->audio_stream_idx = -1;
    player->sub_stream_idx = -1;
    player->secondary_sub_stream_idx = -1;
    player->atomic_video_bitrate_mbps.store(0.0, std::memory_order_relaxed);
    player->audio_queue_started.store(false);
    player->state.store(DK_STATE_IDLE);
}

void dk_player_play(DKPlayer* player) {
    DKReaderGuard guard(player);
    if (!guard) return;
    DKPlayerState st = player->state.load();
    if (st == DK_STATE_PAUSED || st == DK_STATE_ENDED) {
        player->state.store(DK_STATE_PLAYING);
        if (player->audio_queue && player->audio_queue_started.load()) {
            AudioQueueStart(player->audio_queue, nullptr);
        }
        int64_t now_ns = dk_steady_now_ns();
        player->ext_clock_start_ns.store(now_ns, std::memory_order_relaxed);
        player->fallback_clock_ns.store(now_ns, std::memory_order_relaxed);
        player->video_decode_cv.notify_all();
        player->audio_decode_cv.notify_all();
    }
}

void dk_player_pause(DKPlayer* player) {
    DKReaderGuard guard(player);
    if (!guard) return;
    if (player && player->state.load() == DK_STATE_PLAYING) {
        player->state.store(DK_STATE_PAUSED);
        if (player->audio_queue && player->audio_queue_started.load()) {
            AudioQueuePause(player->audio_queue);
        }
        player->ext_clock_base_pts.store(dk_get_master_clock(player));
        player->fallback_audio_clock.store(player->ext_clock_base_pts.load());
    }
}

void dk_player_seek(DKPlayer* player, double target_sec, bool accurate) {
    DKReaderGuard guard(player);
    if (!guard) return;
    dk_signal_seek_request(player, target_sec, accurate);
}

void dk_player_set_rate(DKPlayer* player, float rate) {
    DKReaderGuard guard(player);
    if (!guard) return;
    double current_pos = dk_get_master_clock(player);
    player->playback_rate.store(rate);
    if (player->audio_queue) {
        AudioQueueSetParameter(player->audio_queue, kAudioQueueParam_PlayRate, rate);
    }
    player->ext_clock_base_pts.store(current_pos);
    int64_t now_ns = dk_steady_now_ns();
    player->ext_clock_start_ns.store(now_ns, std::memory_order_relaxed);
    player->fallback_audio_clock.store(current_pos);
    player->fallback_clock_ns.store(now_ns, std::memory_order_relaxed);
}

void dk_player_set_volume(DKPlayer* player, float volume, bool muted) {
    DKReaderGuard guard(player);
    if (!guard) return;
    player->volume.store(volume);
    player->is_muted.store(muted);
    if (player->audio_queue) {
        const char* muted_env = std::getenv("DONBY_TEST_MUTED");
        const bool env_muted = (muted_env && (muted_env[0] == '1' || muted_env[0] == 't' || muted_env[0] == 'T'));
        float effective_vol = (muted || env_muted) ? 0.0f : volume;
        AudioQueueSetParameter(player->audio_queue, kAudioQueueParam_Volume, effective_vol);
    }
}

void dk_player_set_buffer_limit_mb(DKPlayer* player, int32_t limit_mb) {
    DKReaderGuard guard(player);
    if (!guard) return;
    int32_t clamped = std::clamp<int32_t>(limit_mb, 32, 2048);
    player->max_buffer_bytes.store(static_cast<int64_t>(clamped) * 1024LL * 1024LL, std::memory_order_relaxed);
    player->demux_cv.notify_one();
}

int dk_player_get_track_count(DKPlayer* player, int track_type) {
    DKReaderGuard guard(player);
    if (!guard || !player->format_ctx) return 0;
    AVMediaType target_type = (track_type == 0) ? AVMEDIA_TYPE_VIDEO : (track_type == 1 ? AVMEDIA_TYPE_AUDIO : AVMEDIA_TYPE_SUBTITLE);
    int count = 0;
    for (unsigned int i = 0; i < player->format_ctx->nb_streams; i++) {
        if (player->format_ctx->streams[i]->codecpar->codec_type == target_type) count++;
    }
    return count;
}

bool dk_player_get_track_info(DKPlayer* player, int track_type, int ordinal, DKTrackInfo* out_info) {
    DKReaderGuard guard(player);
    if (!guard || !player->format_ctx || !out_info || ordinal < 0) return false;
    std::memset(out_info, 0, sizeof(DKTrackInfo));
    AVMediaType target_type = (track_type == 0) ? AVMEDIA_TYPE_VIDEO : (track_type == 1 ? AVMEDIA_TYPE_AUDIO : AVMEDIA_TYPE_SUBTITLE);
    int seen = 0;
    for (unsigned int i = 0; i < player->format_ctx->nb_streams; i++) {
        AVStream* st = player->format_ctx->streams[i];
        if (st->codecpar->codec_type != target_type) continue;
        if (seen == ordinal) {
            out_info->stream_index = static_cast<int32_t>(i);
            out_info->channels = st->codecpar->ch_layout.nb_channels;
            out_info->is_default = (st->disposition & AV_DISPOSITION_DEFAULT) != 0;
            out_info->is_forced = (st->disposition & AV_DISPOSITION_FORCED) != 0;
            if (track_type == 0) out_info->is_selected = (player->video_stream_idx == static_cast<int>(i));
            else if (track_type == 1) out_info->is_selected = (player->audio_stream_idx.load() == static_cast<int>(i));
            else out_info->is_selected = (player->sub_stream_idx.load() == static_cast<int>(i));

            const char* cname = avcodec_get_name(st->codecpar->codec_id);
            if (cname) std::snprintf(out_info->codec, sizeof(out_info->codec), "%s", cname);

            if (const AVDictionaryEntry* l = av_dict_get(st->metadata, "language", nullptr, 0); l && l->value) {
                std::snprintf(out_info->language, sizeof(out_info->language), "%s", l->value);
            }
            if (const AVDictionaryEntry* t = av_dict_get(st->metadata, "title", nullptr, 0); t && t->value) {
                std::snprintf(out_info->title, sizeof(out_info->title), "%s", t->value);
            }
            return true;
        }
        seen++;
    }
    return false;
}

int dk_player_get_chapter_count(DKPlayer* player) {
    DKReaderGuard guard(player);
    if (!guard || !player->format_ctx) return 0;
    return static_cast<int>(player->format_ctx->nb_chapters);
}

bool dk_player_get_chapter_info(DKPlayer* player, int ordinal, DKChapterInfo* out_info) {
    DKReaderGuard guard(player);
    if (!guard || !player->format_ctx || !out_info || ordinal < 0 ||
        static_cast<unsigned int>(ordinal) >= player->format_ctx->nb_chapters) {
        return false;
    }
    std::memset(out_info, 0, sizeof(DKChapterInfo));
    AVChapter* ch = player->format_ctx->chapters[ordinal];
    if (!ch) return false;
    out_info->index = ordinal;
    double tb = av_q2d(ch->time_base);
    out_info->start_sec = (ch->start != AV_NOPTS_VALUE) ? (ch->start * tb) : 0.0;
    out_info->end_sec = (ch->end != AV_NOPTS_VALUE) ? (ch->end * tb) : out_info->start_sec;
    if (const AVDictionaryEntry* t = av_dict_get(ch->metadata, "title", nullptr, 0); t && t->value) {
        std::snprintf(out_info->title, sizeof(out_info->title), "%s", t->value);
    }
    return true;
}

void dk_player_select_track(DKPlayer* player, int track_type, int stream_index) {
    DKReaderGuard guard(player);
    if (!guard || !player->format_ctx) return;
    if (track_type == 1) { // Audio
        if (stream_index < 0 || static_cast<unsigned int>(stream_index) >= player->format_ctx->nb_streams) return;
        if (player->format_ctx->streams[stream_index]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) return;
        if (player->audio_stream_idx.load() == stream_index) return;

        double cur_pts = std::max(0.0, dk_get_master_clock(player));
        std::lock_guard<std::mutex> codec_lk(player->audio_codec_mtx);

        while (player->audio_queue_starting.load(std::memory_order_acquire) && !player->abort_requested.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        if (player->audio_queue) {
            AudioQueueStop(player->audio_queue, true);
            AudioQueueReset(player->audio_queue);
            player->audio_queue_started.store(false);
        }

        {
            std::lock_guard<std::mutex> a_lock(player->audio_pkt_mtx);
            while (!player->audio_pkt_queue.empty()) {
                AVPacket* p = player->audio_pkt_queue.front();
                player->audio_pkt_queue.pop();
                if (p) {
                    player->queued_pkt_bytes.fetch_sub(p->size, std::memory_order_relaxed);
                    av_packet_free(&p);
                }
            }
        }
        {
            std::lock_guard<std::mutex> aq_lock(player->audio_queue_mtx);
            player->audio_chunks.clear();
            player->buffered_audio_samples.store(0);
            player->audio_clock_base_pts.store(cur_pts);
            player->audio_clock_calibrated.store(false);
            player->audio_clock_base_sample_time.store(0);
            player->audio_underrun_samples.store(0);
            player->fallback_audio_clock.store(cur_pts);
        }
        player->ext_clock_base_pts.store(cur_pts);
        player->current_pos_sec.store(cur_pts);

        if (player->audio_codec_ctx) {
            avcodec_free_context(&player->audio_codec_ctx);
        }
        if (player->swr_ctx) {
            swr_free(&player->swr_ctx);
        }

        AVStream* st = player->format_ctx->streams[stream_index];
        const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
        if (dec) {
            player->audio_codec_ctx = avcodec_alloc_context3(dec);
            avcodec_parameters_to_context(player->audio_codec_ctx, st->codecpar);
            player->audio_codec_ctx->pkt_timebase = st->time_base;
            if (avcodec_open2(player->audio_codec_ctx, dec, nullptr) == 0) {
                player->audio_stream_idx.store(stream_index);
                dk_setup_swr(player);
                if (!player->audio_queue) {
                    dk_init_audio_queue(player);
                }
                std::lock_guard<std::mutex> lock(player->stats_mtx);
                std::snprintf(player->stats.audio_codec, sizeof(player->stats.audio_codec), "%s", dec->name);
            } else {
                avcodec_free_context(&player->audio_codec_ctx);
                player->audio_stream_idx.store(-1);
            }
        }
        dk_signal_seek_request(player, cur_pts, true);
    } else if (track_type == 2) { // Primary Subtitle
        if (stream_index < 0) stream_index = -1;
        if (stream_index >= 0) {
            if (static_cast<unsigned int>(stream_index) >= player->format_ctx->nb_streams ||
                player->format_ctx->streams[stream_index]->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) {
                dk_log(1, "DKEngine: Ignored invalid subtitle stream index %d", stream_index);
                return;
            }
        }
        if (player->sub_stream_idx.load(std::memory_order_relaxed) == stream_index) return;

        double cur_pts = std::max(0.0, dk_get_master_clock(player));
        bool is_bitmap = false;
        {
            std::lock_guard<std::mutex> slk(player->ass_mtx);
            player->sub_stream_idx.store(stream_index);
            dk_open_subtitle_decoder_locked(player, stream_index);
            is_bitmap = player->has_bitmap_subs;
        }
        if (stream_index >= 0) {
            dk_replay_sub_pkt_history(player, stream_index, false);
            double demux_ahead = player->last_demuxed_pts.load(std::memory_order_relaxed) - cur_pts;
            // Only force an AV seek if historical subtitle packets were evicted AND demuxer is far ahead (or bitmap cue started earlier)
            if (player->sub_hist_trimmed.load(std::memory_order_relaxed) && (is_bitmap || demux_ahead > 2.0)) {
                dk_signal_seek_request(player, cur_pts, true);
            }
        } else {
            dk_log(0, "DKEngine: Subtitles disabled by user");
        }
    }
}

void dk_player_select_secondary_subtitle_track(DKPlayer* player, int stream_index) {
    DKReaderGuard guard(player);
    if (!guard || !player->format_ctx) return;
    if (stream_index < 0) stream_index = -1;
    if (stream_index >= 0) {
        if (static_cast<unsigned int>(stream_index) >= player->format_ctx->nb_streams ||
            player->format_ctx->streams[stream_index]->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) {
            dk_log(1, "DKEngine: Ignored invalid secondary subtitle stream index %d", stream_index);
            return;
        }
    }
    if (player->secondary_sub_stream_idx.load(std::memory_order_relaxed) == stream_index) return;

    double cur_pts = std::max(0.0, dk_get_master_clock(player));
    {
        std::lock_guard<std::mutex> slk(player->ass_mtx);
        player->secondary_sub_stream_idx.store(stream_index);
        dk_open_subtitle_decoder_for_slot_locked(player, stream_index, true);
    }
    if (stream_index >= 0) {
        dk_replay_sub_pkt_history(player, stream_index, true);
        double demux_ahead = player->last_demuxed_pts.load(std::memory_order_relaxed) - cur_pts;
        if (player->sub_hist_trimmed.load(std::memory_order_relaxed) && demux_ahead > 2.0) {
            dk_signal_seek_request(player, cur_pts, true);
        }
    }
}

static long long dk_parse_srt_time_ms(const std::string& t) {
    int hh = 0, mm = 0, ss = 0, ms = 0;
    char sep = ',';
    if (std::sscanf(t.c_str(), "%d:%d:%d%c%d", &hh, &mm, &ss, &sep, &ms) >= 5) {
        return (static_cast<long long>(hh) * 3600LL + static_cast<long long>(mm) * 60LL + ss) * 1000LL + ms;
    }
    if (std::sscanf(t.c_str(), "%d:%d%c%d", &mm, &ss, &sep, &ms) >= 4) {
        return (static_cast<long long>(mm) * 60LL + ss) * 1000LL + ms;
    }
    return -1;
}

static std::string dk_sanitize_srt_vtt_tags(const std::string& raw) {
    std::string out;
    out.reserve(raw.size() + 8);
    for (size_t i = 0; i < raw.size(); ) {
        if (raw[i] == '<') {
            size_t close = raw.find('>', i + 1);
            if (close != std::string::npos) {
                std::string tag = raw.substr(i + 1, close - i - 1);
                for (char& c : tag) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
                if (tag == "i") out += "{\\i1}";
                else if (tag == "/i") out += "{\\i0}";
                else if (tag == "b") out += "{\\b1}";
                else if (tag == "/b") out += "{\\b0}";
                else if (tag == "u") out += "{\\u1}";
                else if (tag == "/u") out += "{\\u0}";
                i = close + 1;
                continue;
            }
        }
        out += raw[i++];
    }
    return out;
}

static void dk_populate_external_subtitle_track_locked(
    DKPlayer* player,
    const std::string& raw_utf8,
    bool is_ass,
    bool is_secondary
) {
    ASS_Track*& track = is_secondary ? player->secondary_ass_track : player->ass_track;
    if (track) {
        ass_free_track(track);
        track = nullptr;
    }
    if (raw_utf8.empty() || !player->ass_lib) return;

    if (is_ass) {
        std::string transformed = dk_transform_ass_document(
            raw_utf8,
            player->sub_style.text_transform,
            player->sub_style.unify_pingfang_font,
            player->sub_style.enhance_secondary_yellow
        );
        track = ass_read_memory(player->ass_lib, transformed.data(), transformed.size(), nullptr);
        if (track) {
            dk_ensure_ass_track_header_for(player, track, is_secondary);
        }
        return;
    }

    track = ass_new_track(player->ass_lib);
    if (!track) return;
    dk_ensure_ass_track_header_for(player, track, is_secondary);

    std::string text = raw_utf8;
    if (text.size() >= 3 && static_cast<uint8_t>(text[0]) == 0xEF && static_cast<uint8_t>(text[1]) == 0xBB && static_cast<uint8_t>(text[2]) == 0xBF) {
        text.erase(0, 3);
    }

    size_t pos = 0;
    long long cue_start = -1, cue_end = -1;
    std::string cue_body;
    auto flush_cue = [&]() {
        if (cue_start >= 0 && cue_end > cue_start && !cue_body.empty()) {
            std::string body_sanitized = dk_sanitize_srt_vtt_tags(cue_body);
            // Bilingual SRT polish: when line 1 is CJK and line 2 is Latin/foreign, style line 2 in smaller classic gold-yellow
            if (!is_secondary && player->sub_style.enhance_secondary_yellow) {
                size_t br = body_sanitized.find("\\N");
                if (br != std::string::npos && br > 0 && br + 2 < body_sanitized.size()) {
                    std::string line1 = body_sanitized.substr(0, br);
                    std::string line2 = body_sanitized.substr(br + 2);
                    if (dk_has_cjk_utf8(line1) && dk_is_mostly_latin_line(line2) && line2.find("\\c&") == std::string::npos && line2.find("\\1c&") == std::string::npos) {
                        body_sanitized = line1 + "\\N{\\fscx84\\fscy84\\1c&H003FD2FF&}" + line2;
                    }
                }
            }
            std::string body_transformed = dk_transform_ass_payload(
                body_sanitized,
                player->sub_style.text_transform,
                player->sub_style.unify_pingfang_font,
                player->sub_style.enhance_secondary_yellow
            );
            std::string chunk = std::to_string(++player->sub_read_order) + ",0,Default,,0,0,0,," + body_transformed;
            ass_process_chunk(track, chunk.data(), static_cast<int>(chunk.size()), cue_start, cue_end - cue_start);
        }
        cue_start = cue_end = -1;
        cue_body.clear();
    };

    while (pos <= text.size()) {
        size_t nl = text.find('\n', pos);
        std::string line = (nl == std::string::npos) ? text.substr(pos) : text.substr(pos, nl - pos);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        pos = (nl == std::string::npos) ? (text.size() + 1) : (nl + 1);

        if (line.empty()) {
            flush_cue();
            continue;
        }
        if (cue_start < 0 && (line.rfind("WEBVTT", 0) == 0 || line.rfind("NOTE", 0) == 0 || line.rfind("STYLE", 0) == 0)) {
            continue;
        }
        size_t arrow = line.find("-->");
        if (arrow != std::string::npos) {
            flush_cue();
            std::string lhs = line.substr(0, arrow);
            std::string rhs = line.substr(arrow + 3);
            while (!lhs.empty() && lhs.front() == ' ') lhs.erase(lhs.begin());
            while (!rhs.empty() && rhs.front() == ' ') rhs.erase(rhs.begin());
            size_t rhs_space = rhs.find_first_of(" \t");
            if (rhs_space != std::string::npos) rhs = rhs.substr(0, rhs_space);
            cue_start = dk_parse_srt_time_ms(lhs);
            cue_end = dk_parse_srt_time_ms(rhs);
        } else if (cue_start >= 0) {
            if (!cue_body.empty()) cue_body += "\\N";
            cue_body += line;
        }
    }
    flush_cue();
}

static void dk_rebuild_embedded_ass_track_locked(DKPlayer* player, bool is_secondary) {
    ASS_Track*& track = is_secondary ? player->secondary_ass_track : player->ass_track;
    const std::string& codec_priv = is_secondary ? player->secondary_codec_private : player->primary_codec_private;
    const std::vector<StoredAssEvent>& events = is_secondary ? player->secondary_ass_events : player->primary_ass_events;
    if (track) {
        ass_free_track(track);
        track = nullptr;
    }
    if (!player->ass_lib) return;
    track = ass_new_track(player->ass_lib);
    if (!track) return;
    if (!codec_priv.empty()) {
        ass_process_codec_private(track, const_cast<char*>(codec_priv.data()), static_cast<int>(codec_priv.size()));
    }
    dk_ensure_ass_track_header_for(player, track, is_secondary);
    for (const auto& ev : events) {
        if (player->sub_style.forced_only && !ev.is_forced) continue;
        std::string transformed = dk_transform_ass_line(
            ev.raw_line,
            player->sub_style.text_transform,
            ev.is_full_dialogue,
            player->sub_style.unify_pingfang_font,
            player->sub_style.enhance_secondary_yellow
        );
        if (ev.is_full_dialogue) {
            ass_process_data(track, transformed.data(), static_cast<int>(transformed.size()));
        } else {
            ass_process_chunk(track, transformed.data(), static_cast<int>(transformed.size()), ev.start_ms, ev.dur_ms);
        }
    }
}

void dk_player_load_external_subtitle(DKPlayer* player, const char* content_utf8, bool is_ass) {
    DKReaderGuard guard(player);
    if (!guard || !content_utf8 || !player->ass_lib) return;

    std::lock_guard<std::mutex> slk(player->ass_mtx);
    player->sub_stream_idx.store(-1);
    if (player->sub_codec_ctx) {
        avcodec_free_context(&player->sub_codec_ctx);
    }
    player->primary_ass_events.clear();
    player->primary_codec_private.clear();
    player->pgs_cues.clear();
    player->sub_rgba_buf.clear();
    player->has_bitmap_subs = false;
    player->rendered_pgs_gen = 0;
    player->sub_last_non_empty = false;
    player->sub_dirty_y0 = 0;
    player->sub_dirty_y1 = 0;
    player->sub_serial++;
    player->primary_ext_raw = content_utf8;
    player->primary_ext_is_ass = is_ass;
    dk_populate_external_subtitle_track_locked(player, player->primary_ext_raw, is_ass, false);
}

void dk_player_load_secondary_external_subtitle(DKPlayer* player, const char* content_utf8, bool is_ass) {
    DKReaderGuard guard(player);
    if (!guard || !content_utf8 || !player->ass_lib) return;

    std::lock_guard<std::mutex> slk(player->ass_mtx);
    player->secondary_sub_stream_idx.store(-1);
    if (player->secondary_sub_codec_ctx) {
        avcodec_free_context(&player->secondary_sub_codec_ctx);
    }
    player->secondary_ass_events.clear();
    player->secondary_codec_private.clear();
    player->sub_rgba_buf.clear();
    player->sub_last_non_empty = false;
    player->sub_dirty_y0 = 0;
    player->sub_dirty_y1 = 0;
    player->sub_serial++;
    player->secondary_ext_raw = content_utf8;
    player->secondary_ext_is_ass = is_ass;
    dk_populate_external_subtitle_track_locked(player, player->secondary_ext_raw, is_ass, true);
}

void dk_player_set_subtitle_style(DKPlayer* player, const DKSubtitleStyleConfig* config) {
    DKReaderGuard guard(player);
    if (!guard || !config) return;

    std::lock_guard<std::mutex> slk(player->ass_mtx);
    const bool transform_changed = (player->sub_style.text_transform != config->text_transform);
    const bool forced_changed = (player->sub_style.forced_only != config->forced_only);
    const bool override_changed = (player->sub_style.override_ass_style != config->override_ass_style);
    const bool font_changed = (player->sub_style.unify_pingfang_font != config->unify_pingfang_font);
    const bool yellow_changed = (player->sub_style.enhance_secondary_yellow != config->enhance_secondary_yellow);
    player->sub_style = *config;

    if (transform_changed || forced_changed || override_changed || font_changed || yellow_changed) {
        if (!player->primary_ext_raw.empty()) {
            dk_populate_external_subtitle_track_locked(player, player->primary_ext_raw, player->primary_ext_is_ass, false);
        } else if (player->sub_stream_idx.load(std::memory_order_relaxed) >= 0 && !player->has_bitmap_subs) {
            dk_rebuild_embedded_ass_track_locked(player, false);
        }
        if (!player->secondary_ext_raw.empty()) {
            dk_populate_external_subtitle_track_locked(player, player->secondary_ext_raw, player->secondary_ext_is_ass, true);
        } else if (player->secondary_sub_stream_idx.load(std::memory_order_relaxed) >= 0) {
            dk_rebuild_embedded_ass_track_locked(player, true);
        }
    }

    if (player->ass_track) {
        dk_apply_style_to_ass_track_locked(player, player->ass_track, false);
    }
    if (player->secondary_ass_track) {
        dk_apply_style_to_ass_track_locked(player, player->secondary_ass_track, true);
    }
    player->sub_last_non_empty = false;
    player->sub_style_dirty = true;
    player->rendered_pgs_gen = 0;
    player->sub_serial++;
}

bool dk_player_get_subtitle_vertical_bounds(DKPlayer* player, int32_t* out_y0, int32_t* out_y1, int32_t* out_canvas_h) {
    DKReaderGuard guard(player);
    if (!guard || !out_y0 || !out_y1 || !out_canvas_h) return false;
    std::lock_guard<std::mutex> slk(player->ass_mtx);
    if (!player->sub_last_non_empty || player->ass_canvas_h <= 0 || player->sub_dirty_y1 <= player->sub_dirty_y0) {
        *out_y0 = 0;
        *out_y1 = 0;
        *out_canvas_h = 0;
        return false;
    }
    *out_y0 = player->sub_dirty_y0;
    *out_y1 = player->sub_dirty_y1;
    *out_canvas_h = player->ass_canvas_h;
    return true;
}

CVPixelBufferRef dk_player_acquire_frame(DKPlayer* player, double* out_pts, DKGpuColorUniforms* out_color) {
    DKReaderGuard guard(player);
    if (!guard) return nullptr;

    // Detect genuine continuous hardware audio starvation (>=100ms silence) even if video frames remain queued,
    // preventing frozen-video + choppy-audio-blip loops when audio runs dry before video_queue empties.
    if (player->state.load() == DK_STATE_PLAYING &&
        !dk_is_seeking(player) &&
        !player->demux_eof.load(std::memory_order_relaxed) &&
        !player->video_eof.load(std::memory_order_relaxed) &&
        !player->audio_eof.load(std::memory_order_relaxed) &&
        !player->audio_hal_disabled.load(std::memory_order_relaxed) &&
        player->buffered_audio_samples.load(std::memory_order_relaxed) <= 0 &&
        player->audio_consecutive_underrun_samples.load(std::memory_order_relaxed) >= 4800 &&
        player->audio_queue != nullptr &&
        !player->audio_queue_starting.load(std::memory_order_acquire) &&
        player->audio_queue_started.exchange(false, std::memory_order_acq_rel)) {
        uint32_t streak = player->audio_rebuffer_count.fetch_add(1, std::memory_order_relaxed) + 1;
        if (streak > 3) {
            player->audio_rebuffer_count.store(3, std::memory_order_relaxed);
        }
        AudioQueueStop(player->audio_queue, true);
        AudioQueueReset(player->audio_queue);
        player->audio_consecutive_underrun_samples.store(0, std::memory_order_relaxed);
    }

    // Wake background audio decoder to start AudioQueue without blocking the CVDisplayLink render thread
    if (player->state.load() == DK_STATE_PLAYING &&
        !dk_is_seeking(player) &&
        player->audio_stream_idx.load(std::memory_order_relaxed) >= 0 &&
        player->audio_queue != nullptr &&
        !player->audio_hal_disabled.load(std::memory_order_acquire) &&
        !player->audio_queue_started.load(std::memory_order_acquire) &&
        !player->audio_queue_starting.load(std::memory_order_acquire) &&
        player->buffered_audio_samples.load(std::memory_order_relaxed) > 0 &&
        !player->audio_eof.load(std::memory_order_relaxed)) {
        player->audio_decode_cv.notify_one();
    }

    double master_pts = dk_get_master_clock(player);

    std::unique_lock<std::mutex> lock(player->video_queue_mtx);
    if (player->video_queue.empty()) {
        if (player->video_eof.load() && player->demux_eof.load() && player->state.load() == DK_STATE_PLAYING) {
            if (player->audio_stream_idx.load() < 0 || (player->audio_eof.load() && player->buffered_audio_samples.load() <= 0)) {
                player->state.store(DK_STATE_ENDED);
            }
        }
        if (player->last_frame) {
            CVPixelBufferRetain(player->last_frame);
            if (out_pts) *out_pts = player->last_pts;
            if (out_color) *out_color = player->last_color;
            return player->last_frame;
        }
        return nullptr;
    }

    if (player->audio_queue_started.load(std::memory_order_relaxed) &&
        player->audio_rebuffer_count.load(std::memory_order_relaxed) > 0) {
        int64_t steady_ns = player->audio_steady_start_ns.load(std::memory_order_relaxed);
        if (steady_ns > 0 && dk_elapsed_since_ns(steady_ns) >= 15.0) {
            player->audio_rebuffer_count.store(0, std::memory_order_relaxed);
        }
    }

    // Deliver the very first frame synchronized with AudioQueue start (when playing with audio)
    // so playback begins with immediate fluid motion instead of a 200-500ms frozen still frame.
    if (player->last_frame == nullptr && !player->video_queue.empty()) {
        const bool audio_expected =
            (player->state.load(std::memory_order_relaxed) == DK_STATE_PLAYING) &&
            (player->audio_stream_idx.load(std::memory_order_relaxed) >= 0) &&
            (player->audio_queue != nullptr) &&
            !player->audio_hal_disabled.load(std::memory_order_acquire) &&
            !player->audio_queue_started.load(std::memory_order_acquire) &&
            !player->audio_eof.load(std::memory_order_relaxed) &&
            !player->demux_eof.load(std::memory_order_relaxed);
        const bool audio_track_silent_fallback =
            (player->video_queue.size() >= 10 && player->buffered_audio_samples.load(std::memory_order_relaxed) <= 0);
        if (audio_expected && !audio_track_silent_fallback) {
            return nullptr;
        }
        player->force_present_next_frame.store(false, std::memory_order_release);
        auto& front = player->video_queue.front();
        player->last_frame = front.pixel_buffer;
        player->last_pts = front.pts;
        player->last_color = front.color;
        player->current_pos_sec.store(front.pts);
        player->video_queue.pop();
        player->video_frame_cv.notify_one();

        CVPixelBufferRetain(player->last_frame);
        if (out_pts) *out_pts = player->last_pts;
        if (out_color) *out_color = player->last_color;
        dk_log(0, "DKEngine: First video frame presented smoothly (PTS: %.3fs, audio_started=%d)",
               player->last_pts, player->audio_queue_started.load(std::memory_order_relaxed) ? 1 : 0);
        return player->last_frame;
    }

    if (player->force_present_next_frame.load(std::memory_order_acquire) && !player->video_queue.empty()) {
        const bool wait_for_audio_sync =
            (player->state.load(std::memory_order_relaxed) == DK_STATE_PLAYING) &&
            (player->audio_stream_idx.load(std::memory_order_relaxed) >= 0) &&
            (player->audio_queue != nullptr) &&
            !player->audio_hal_disabled.load(std::memory_order_acquire) &&
            !player->audio_queue_started.load(std::memory_order_acquire) &&
            !player->audio_eof.load(std::memory_order_relaxed) &&
            !player->demux_eof.load(std::memory_order_relaxed);
        if (!wait_for_audio_sync && player->force_present_next_frame.exchange(false, std::memory_order_acq_rel)) {
            auto& front = player->video_queue.front();
            if (player->last_frame) {
                CVPixelBufferRelease(player->last_frame);
            }
            player->last_frame = front.pixel_buffer;
            player->last_pts = front.pts;
            player->last_color = front.color;
            player->current_pos_sec.store(front.pts);
            player->ext_clock_base_pts.store(front.pts, std::memory_order_relaxed);
            player->ext_clock_start_ns.store(dk_steady_now_ns(), std::memory_order_relaxed);
            if (!player->audio_queue_started.load(std::memory_order_acquire)) {
                player->audio_clock_base_pts.store(front.pts, std::memory_order_relaxed);
                player->fallback_audio_clock.store(front.pts, std::memory_order_relaxed);
                player->fallback_clock_ns.store(dk_steady_now_ns(), std::memory_order_relaxed);
            }
            player->video_queue.pop();
            player->video_frame_cv.notify_one();

            CVPixelBufferRetain(player->last_frame);
            if (out_pts) *out_pts = player->last_pts;
            if (out_color) *out_color = player->last_color;
            return player->last_frame;
        }
    }

    // Wait for AudioQueue clock calibration after seek before dropping or advancing frames,
    // preventing post-seek fast-forward jitter when keyframe PTS precedes target_sec.
    if (player->audio_stream_idx.load(std::memory_order_relaxed) >= 0 &&
        player->audio_queue != nullptr &&
        !player->audio_hal_disabled.load(std::memory_order_acquire) &&
        !player->audio_queue_started.load(std::memory_order_acquire) &&
        !player->audio_eof.load(std::memory_order_relaxed)) {
        if (player->last_frame) {
            CVPixelBufferRetain(player->last_frame);
            if (out_pts) *out_pts = player->last_pts;
            if (out_color) *out_color = player->last_color;
            return player->last_frame;
        }
        return nullptr;
    }

    while (!player->video_queue.empty()) {
        auto& front = player->video_queue.front();
        double diff = front.pts - master_pts;

        if (diff < -0.08 && player->video_queue.size() > 1) {
            // Frame is late (> 80ms behind master clock), drop to catch up ONLY if more frames are buffered
            CVPixelBufferRelease(front.pixel_buffer);
            player->video_queue.pop();
            player->video_frame_cv.notify_one();
            continue;
        }

        if (diff <= 0.015) {
            // Frame is in presentation window [-0.08s, +0.015s]
            if (player->last_frame) {
                CVPixelBufferRelease(player->last_frame);
            }
            player->last_frame = front.pixel_buffer;
            player->last_pts = front.pts;
            player->last_color = front.color;
            player->current_pos_sec.store(front.pts);
            player->video_queue.pop();
            player->video_frame_cv.notify_one();
            break;
        }

        // diff > 0.015s: Frame is in the future, hold current frame
        break;
    }

    if (player->last_frame) {
        CVPixelBufferRetain(player->last_frame);
        if (out_pts) *out_pts = player->last_pts;
        if (out_color) *out_color = player->last_color;
        return player->last_frame;
    }
    return nullptr;
}

CVPixelBufferRef dk_player_acquire_frame_for_host_time(DKPlayer* player, double* out_pts) {
    return dk_player_acquire_frame(player, out_pts, nullptr);
}

static void dk_composite_ass_images_to_rgba(
    ASS_Image* img,
    uint8_t* rgba_buf,
    int canvas_w,
    int canvas_h,
    int y_offset,
    int& inout_y0,
    int& inout_y1
) {
    for (ASS_Image* cur = img; cur != nullptr; cur = cur->next) {
        if (cur->w <= 0 || cur->h <= 0 || !cur->bitmap) continue;
        uint8_t cr = (cur->color >> 24) & 0xFF;
        uint8_t cg = (cur->color >> 16) & 0xFF;
        uint8_t cb = (cur->color >> 8) & 0xFF;
        uint8_t ca = 255 - (cur->color & 0xFF);
        if (ca == 0) continue;

        int max_c = std::max({static_cast<int>(cr), static_cast<int>(cg), static_cast<int>(cb)});
        int min_c = std::min({static_cast<int>(cr), static_cast<int>(cg), static_cast<int>(cb)});
        if (max_c >= 140 && (max_c - min_c) <= 18) {
            float scale = 245.0f / static_cast<float>(max_c);
            cr = static_cast<uint8_t>(std::clamp(static_cast<int>(std::lround(cr * scale)), 0, 255));
            cg = static_cast<uint8_t>(std::clamp(static_cast<int>(std::lround(cg * scale)), 0, 255));
            cb = static_cast<uint8_t>(std::clamp(static_cast<int>(std::lround(cb * scale)), 0, 255));
        }

        for (int y = 0; y < cur->h; y++) {
            int dy = cur->dst_y + y + y_offset;
            if (dy < 0 || dy >= canvas_h) continue;
            inout_y0 = std::min(inout_y0, dy);
            inout_y1 = std::max(inout_y1, dy + 1);
            const uint8_t* mask_row = cur->bitmap + y * cur->stride;
            uint8_t* dst_row = rgba_buf + static_cast<size_t>(dy) * canvas_w * 4;
            for (int x = 0; x < cur->w; x++) {
                int dx = cur->dst_x + x;
                if (dx < 0 || dx >= canvas_w) continue;
                uint32_t m = mask_row[x];
                if (m == 0) continue;
                uint32_t a = (m * ca + 127) / 255;
                uint8_t sr = static_cast<uint8_t>((cr * a + 127) / 255);
                uint8_t sg = static_cast<uint8_t>((cg * a + 127) / 255);
                uint8_t sb = static_cast<uint8_t>((cb * a + 127) / 255);
                uint8_t* dp = dst_row + dx * 4;
                uint32_t inv_a = 255 - a;
                dp[0] = static_cast<uint8_t>(std::min<uint32_t>(255, sr + (dp[0] * inv_a + 127) / 255));
                dp[1] = static_cast<uint8_t>(std::min<uint32_t>(255, sg + (dp[1] * inv_a + 127) / 255));
                dp[2] = static_cast<uint8_t>(std::min<uint32_t>(255, sb + (dp[2] * inv_a + 127) / 255));
                dp[3] = static_cast<uint8_t>(std::min<uint32_t>(255, a + (dp[3] * inv_a + 127) / 255));
            }
        }
    }
}

static bool dk_update_subtitle_rgba_locked(
    DKPlayer* player,
    double pts,
    int32_t canvas_w,
    int32_t canvas_h,
    const uint8_t** out_rgba,
    int32_t* out_w,
    int32_t* out_h,
    uint64_t* out_serial
) {
    auto clear_subtitle_canvas = [&](int target_w, int target_h) {
        const size_t expected_bytes = static_cast<size_t>(target_w) * static_cast<size_t>(target_h) * 4;
        if (player->sub_rgba_buf.size() != expected_bytes) {
            player->sub_rgba_buf.resize(expected_bytes);
            std::memset(player->sub_rgba_buf.data(), 0, expected_bytes);
            player->sub_dirty_y0 = 0;
            player->sub_dirty_y1 = 0;
            return;
        }
        int y0 = std::clamp(player->sub_dirty_y0, 0, target_h);
        int y1 = std::clamp(player->sub_dirty_y1, y0, target_h);
        if (y1 > y0) {
            const size_t row_bytes = static_cast<size_t>(target_w) * 4;
            std::memset(
                player->sub_rgba_buf.data() + static_cast<size_t>(y0) * row_bytes,
                0,
                static_cast<size_t>(y1 - y0) * row_bytes
            );
        }
        player->sub_dirty_y0 = 0;
        player->sub_dirty_y1 = 0;
    };

    if (canvas_w > 1920) {
        canvas_h = std::max(1, (canvas_h * 1920) / canvas_w);
        canvas_w = 1920;
    }

    *out_serial = player->sub_serial;
    const double pri_pts = pts - player->sub_style.primary_delay_sec;
    const double sec_pts = pts - player->sub_style.secondary_delay_sec;

    if (player->has_bitmap_subs) {
        while (!player->pgs_cues.empty() && player->pgs_cues.front().end_sec < pri_pts - 2.0) {
            player->pgs_cues.pop_front();
        }
        const PgsCue* active_cue = nullptr;
        for (const auto& cue : player->pgs_cues) {
            if (pri_pts >= cue.start_sec && pri_pts < cue.end_sec && !cue.rects.empty()) {
                active_cue = &cue;
                break;
            }
        }
        if (!active_cue && !player->secondary_ass_track) {
            if (player->sub_last_non_empty) {
                if (player->ass_canvas_w > 0 && player->ass_canvas_h > 0) {
                    clear_subtitle_canvas(player->ass_canvas_w, player->ass_canvas_h);
                }
                player->sub_last_non_empty = false;
                player->sub_serial++;
            }
            *out_serial = player->sub_serial;
            return false;
        }
        if (active_cue) {
            int cue_w = std::max(1, active_cue->canvas_w);
            int cue_h = std::max(1, active_cue->canvas_h);
            int dst_w = cue_w;
            int dst_h = (canvas_w > 0 && canvas_h > 0) ? std::max(1, (cue_w * canvas_h) / canvas_w) : cue_h;
            int crop_top = (cue_h > dst_h + 20) ? ((cue_h - dst_h) / 2) : 0;

            if (player->rendered_pgs_gen != active_cue->id || player->sub_style_dirty || player->ass_canvas_w != dst_w || player->ass_canvas_h != dst_h) {
                player->ass_canvas_w = dst_w;
                player->ass_canvas_h = dst_h;
                clear_subtitle_canvas(dst_w, dst_h);
                int new_y0 = dst_h;
                int new_y1 = 0;

                // Apply real-time user scale & vertical position to PGS bitmap subtitles
                const float user_scale = std::clamp(player->sub_style.scale > 0.1f ? player->sub_style.scale : 1.0f, 0.5f, 2.5f);
                const float pos_pct = std::clamp(player->sub_style.vertical_pos_percent > 10.0f ? player->sub_style.vertical_pos_percent : 92.0f, 50.0f, 100.0f);
                int union_x0 = dst_w, union_y0 = dst_h, union_x1 = 0, union_y1 = 0;
                for (const auto& r : active_cue->rects) {
                    int my = r.y - crop_top;
                    union_x0 = std::min(union_x0, r.x);
                    union_y0 = std::min(union_y0, my);
                    union_x1 = std::max(union_x1, r.x + r.w);
                    union_y1 = std::max(union_y1, my + r.h);
                }
                const float union_cx = 0.5f * static_cast<float>(union_x0 + union_x1);
                const float union_h = std::max(1.0f, static_cast<float>(union_y1 - union_y0));
                const float scaled_union_h = union_h * user_scale;
                const float target_bottom = std::clamp(
                    (pos_pct * 0.01f) * static_cast<float>(dst_h) - 6.0f,
                    scaled_union_h + 8.0f,
                    static_cast<float>(dst_h - 4)
                );

                for (const auto& r : active_cue->rects) {
                    if (r.w <= 0 || r.h <= 0 || r.rgba.empty()) continue;
                    int mapped_y = r.y - crop_top;
                    int sw = std::max(1, static_cast<int>(std::lround(static_cast<float>(r.w) * user_scale)));
                    int sh = std::max(1, static_cast<int>(std::lround(static_cast<float>(r.h) * user_scale)));
                    float rel_x = (static_cast<float>(r.x) - union_cx) * user_scale;
                    float rel_bottom = static_cast<float>(union_y1 - (mapped_y + r.h)) * user_scale;
                    int base_x = static_cast<int>(std::lround(union_cx + rel_x));
                    int base_y = static_cast<int>(std::lround(target_bottom - rel_bottom - static_cast<float>(sh)));
                    base_x = std::clamp(base_x, 0, std::max(0, dst_w - sw));
                    base_y = std::clamp(base_y, 4, std::max(4, dst_h - sh - 4));

                    for (int y = 0; y < sh; y++) {
                        int dy = base_y + y;
                        if (dy < 0 || dy >= dst_h) continue;
                        new_y0 = std::min(new_y0, dy);
                        new_y1 = std::max(new_y1, dy + 1);
                        float fy = (static_cast<float>(y) + 0.5f) / user_scale - 0.5f;
                        int sy0 = std::clamp(static_cast<int>(std::floor(fy)), 0, r.h - 1);
                        int sy1 = std::clamp(sy0 + 1, 0, r.h - 1);
                        float wy = std::clamp(fy - static_cast<float>(sy0), 0.0f, 1.0f);
                        for (int x = 0; x < sw; x++) {
                            int dx = base_x + x;
                            if (dx < 0 || dx >= dst_w) continue;
                            float fx = (static_cast<float>(x) + 0.5f) / user_scale - 0.5f;
                            int sx0 = std::clamp(static_cast<int>(std::floor(fx)), 0, r.w - 1);
                            int sx1 = std::clamp(sx0 + 1, 0, r.w - 1);
                            float wx = std::clamp(fx - static_cast<float>(sx0), 0.0f, 1.0f);

                            const uint8_t* p00 = &r.rgba[(static_cast<size_t>(sy0) * r.w + sx0) * 4];
                            const uint8_t* p10 = &r.rgba[(static_cast<size_t>(sy0) * r.w + sx1) * 4];
                            const uint8_t* p01 = &r.rgba[(static_cast<size_t>(sy1) * r.w + sx0) * 4];
                            const uint8_t* p11 = &r.rgba[(static_cast<size_t>(sy1) * r.w + sx1) * 4];
                            float w00 = (1.0f - wx) * (1.0f - wy);
                            float w10 = wx * (1.0f - wy);
                            float w01 = (1.0f - wx) * wy;
                            float w11 = wx * wy;
                            uint8_t sr = static_cast<uint8_t>(std::clamp(std::lround(p00[0]*w00 + p10[0]*w10 + p01[0]*w01 + p11[0]*w11), 0L, 255L));
                            uint8_t sg = static_cast<uint8_t>(std::clamp(std::lround(p00[1]*w00 + p10[1]*w10 + p01[1]*w01 + p11[1]*w11), 0L, 255L));
                            uint8_t sb = static_cast<uint8_t>(std::clamp(std::lround(p00[2]*w00 + p10[2]*w10 + p01[2]*w01 + p11[2]*w11), 0L, 255L));
                            uint8_t sa = static_cast<uint8_t>(std::clamp(std::lround(p00[3]*w00 + p10[3]*w10 + p01[3]*w01 + p11[3]*w11), 0L, 255L));
                            if (sa == 0) continue;

                            uint8_t* dp = &player->sub_rgba_buf[(static_cast<size_t>(dy) * dst_w + dx) * 4];
                            uint8_t inv_a = 255 - sa;
                            dp[0] = static_cast<uint8_t>(std::min(255, static_cast<int>(sr) + (dp[0] * inv_a + 127) / 255));
                            dp[1] = static_cast<uint8_t>(std::min(255, static_cast<int>(sg) + (dp[1] * inv_a + 127) / 255));
                            dp[2] = static_cast<uint8_t>(std::min(255, static_cast<int>(sb) + (dp[2] * inv_a + 127) / 255));
                            dp[3] = static_cast<uint8_t>(std::min(255, static_cast<int>(sa) + (dp[3] * inv_a + 127) / 255));
                        }
                    }
                }
                player->sub_style_dirty = false;
                if (player->secondary_ass_track && player->ass_renderer) {
                    ass_set_frame_size(player->ass_renderer, dst_w, dst_h);
                    ass_set_storage_size(player->ass_renderer, dst_w, dst_h);
                    int sec_change = 0;
                    ASS_Image* sec_img = ass_render_frame(
                        player->ass_renderer,
                        player->secondary_ass_track,
                        static_cast<long long>(std::max(0.0, sec_pts) * 1000.0),
                        &sec_change
                    );
                    if (sec_img) {
                        int sec_y1 = 0;
                        for (ASS_Image* c = sec_img; c != nullptr; c = c->next) {
                            if (c->w > 0 && c->h > 0) sec_y1 = std::max(sec_y1, c->dst_y + c->h);
                        }
                        int y_off = (new_y1 > new_y0 && sec_y1 > new_y0 - 6) ? ((new_y0 - 8) - sec_y1) : 0;
                        dk_composite_ass_images_to_rgba(sec_img, player->sub_rgba_buf.data(), dst_w, dst_h, y_off, new_y0, new_y1);
                    }
                }
                if (new_y1 > new_y0) {
                    player->sub_dirty_y0 = new_y0;
                    player->sub_dirty_y1 = new_y1;
                }
                player->rendered_pgs_gen = active_cue->id;
                player->sub_last_non_empty = true;
                player->sub_serial++;
            }
            *out_rgba = player->sub_rgba_buf.data();
            *out_w = dst_w;
            *out_h = dst_h;
            *out_serial = player->sub_serial;
            return true;
        }
    }

    if (!player->ass_renderer || (!player->ass_track && !player->secondary_ass_track)) {
        if (player->sub_last_non_empty) {
            if (player->ass_canvas_w > 0 && player->ass_canvas_h > 0) {
                clear_subtitle_canvas(player->ass_canvas_w, player->ass_canvas_h);
            }
            player->sub_last_non_empty = false;
            player->sub_serial++;
            *out_serial = player->sub_serial;
        }
        return false;
    }
    if (player->ass_canvas_w != canvas_w || player->ass_canvas_h != canvas_h) {
        player->ass_canvas_w = canvas_w;
        player->ass_canvas_h = canvas_h;
        player->sub_dirty_y0 = 0;
        player->sub_dirty_y1 = 0;
        ass_set_frame_size(player->ass_renderer, canvas_w, canvas_h);
        ass_set_storage_size(player->ass_renderer, canvas_w, canvas_h);
        if (player->secondary_ass_renderer) {
            ass_set_frame_size(player->secondary_ass_renderer, canvas_w, canvas_h);
            ass_set_storage_size(player->secondary_ass_renderer, canvas_w, canvas_h);
        }
    }

    long long pri_ms = static_cast<long long>(std::max(0.0, pri_pts) * 1000.0);
    long long sec_ms = static_cast<long long>(std::max(0.0, sec_pts) * 1000.0);

    int change_pri = 0;
    int change_sec = 0;
    ASS_Image* img_pri = player->ass_track
        ? ass_render_frame(player->ass_renderer, player->ass_track, pri_ms, &change_pri)
        : nullptr;
    ASS_Renderer* sec_rend = player->secondary_ass_renderer ? player->secondary_ass_renderer : player->ass_renderer;
    ASS_Image* img_sec = (player->secondary_ass_track && sec_rend)
        ? ass_render_frame(sec_rend, player->secondary_ass_track, sec_ms, &change_sec)
        : nullptr;

    if (!img_pri && !img_sec) {
        if (player->sub_last_non_empty) {
            clear_subtitle_canvas(canvas_w, canvas_h);
            player->sub_last_non_empty = false;
            player->sub_serial++;
        }
        *out_serial = player->sub_serial;
        return false;
    }

    if (change_pri != 0 || change_sec != 0 || !player->sub_last_non_empty || player->sub_style_dirty ||
        player->sub_rgba_buf.size() != static_cast<size_t>(canvas_w) * canvas_h * 4) {
        player->sub_style_dirty = false;
        clear_subtitle_canvas(canvas_w, canvas_h);
        int new_y0 = canvas_h;
        int new_y1 = 0;
        int pri_y0 = canvas_h;
        int pri_y1 = 0;
        if (img_pri) {
            dk_composite_ass_images_to_rgba(img_pri, player->sub_rgba_buf.data(), canvas_w, canvas_h, 0, pri_y0, pri_y1);
            new_y0 = std::min(new_y0, pri_y0);
            new_y1 = std::max(new_y1, pri_y1);
        }
        if (img_sec) {
            int sec_raw_y0 = canvas_h;
            int sec_raw_y1 = 0;
            for (ASS_Image* cur = img_sec; cur != nullptr; cur = cur->next) {
                if (cur->w <= 0 || cur->h <= 0 || !cur->bitmap) continue;
                sec_raw_y0 = std::min(sec_raw_y0, cur->dst_y);
                sec_raw_y1 = std::max(sec_raw_y1, cur->dst_y + cur->h);
            }
            int y_offset = 0;
            if (pri_y1 > pri_y0 && sec_raw_y1 > pri_y0 - 6) {
                y_offset = (pri_y0 - 8) - sec_raw_y1;
            }
            dk_composite_ass_images_to_rgba(img_sec, player->sub_rgba_buf.data(), canvas_w, canvas_h, y_offset, new_y0, new_y1);
        }
        if (new_y1 > new_y0) {
            player->sub_dirty_y0 = new_y0;
            player->sub_dirty_y1 = new_y1;
        }
        player->sub_last_non_empty = true;
        player->sub_serial++;
    }

    *out_rgba = player->sub_rgba_buf.data();
    *out_w = canvas_w;
    *out_h = canvas_h;
    *out_serial = player->sub_serial;
    return true;
}

bool dk_player_get_subtitle_rgba(
    DKPlayer* player,
    double pts,
    int32_t canvas_w,
    int32_t canvas_h,
    const uint8_t** out_rgba,
    int32_t* out_w,
    int32_t* out_h,
    uint64_t* out_serial
) {
    DKReaderGuard guard(player);
    if (!guard || !out_rgba || !out_w || !out_h || !out_serial) return false;
    if (canvas_w <= 0 || canvas_h <= 0) return false;

    std::lock_guard<std::mutex> lock(player->ass_mtx);
    return dk_update_subtitle_rgba_locked(player, pts, canvas_w, canvas_h, out_rgba, out_w, out_h, out_serial);
}

void dk_player_sync_subtitle_rgba(
    DKPlayer* player,
    double pts,
    int32_t canvas_w,
    int32_t canvas_h,
    uint64_t last_serial,
    DKSubtitleRgbaCallback callback,
    void* context
) {
    DKReaderGuard guard(player);
    if (!guard || !callback || canvas_w <= 0 || canvas_h <= 0) return;

    std::lock_guard<std::mutex> lock(player->ass_mtx);
    const uint8_t* rgba = nullptr;
    int32_t w = 0;
    int32_t h = 0;
    uint64_t serial = player->sub_serial;
    bool has_sub = dk_update_subtitle_rgba_locked(player, pts, canvas_w, canvas_h, &rgba, &w, &h, &serial);
    if (serial != last_serial) {
        callback(has_sub ? rgba : nullptr, has_sub ? w : 0, has_sub ? h : 0, serial, context);
    }
}

bool dk_player_get_subtitle_overlay(DKPlayer* player, double pts, DKSubtitleBitmap* out_bitmap) {
    DKReaderGuard guard(player);
    if (!guard || !player->ass_renderer || !player->ass_track || !out_bitmap) return false;
    std::lock_guard<std::mutex> lock(player->ass_mtx);
    long long now_ms = static_cast<long long>(pts * 1000.0);
    int change = 0;
    ASS_Image* img = ass_render_frame(player->ass_renderer, player->ass_track, now_ms, &change);
    if (!img) return false;

    out_bitmap->x = img->dst_x;
    out_bitmap->y = img->dst_y;
    out_bitmap->w = img->w;
    out_bitmap->h = img->h;
    out_bitmap->stride = img->stride;
    out_bitmap->rgba_data = img->bitmap;
    return true;
}

DKPlayerState dk_player_get_state(DKPlayer* player) {
    DKReaderGuard guard(player);
    return guard ? player->state.load() : DK_STATE_IDLE;
}

double dk_player_get_position(DKPlayer* player) {
    DKReaderGuard guard(player);
    if (!guard) return 0.0;
    return dk_get_master_clock(player);
}

double dk_player_get_duration(DKPlayer* player) {
    DKReaderGuard guard(player);
    return guard ? player->duration_sec : 0.0;
}

double dk_player_get_buffered_duration(DKPlayer* player) {
    DKReaderGuard guard(player);
    if (!guard) return 0.0;

    const double cur_pts = std::max(0.0, dk_get_master_clock(player));
    if (player->demux_eof.load(std::memory_order_relaxed) && player->duration_sec > cur_pts) {
        return player->duration_sec - cur_pts;
    }

    double video_q_sec = 0.0;
    {
        std::lock_guard<std::mutex> lock(player->video_queue_mtx);
        if (!player->video_queue.empty()) {
            video_q_sec = std::max(0.0, player->video_queue.back().pts - cur_pts);
        }
    }

    const double demux_ahead_sec = std::max(0.0, player->last_demuxed_pts.load(std::memory_order_relaxed) - cur_pts);

    const int64_t queued_bytes = std::max<int64_t>(0, player->queued_pkt_bytes.load(std::memory_order_relaxed));
    double bitrate_bps = 25.0 * 1024.0 * 1024.0;
    const double measured_mbps = player->atomic_video_bitrate_mbps.load(std::memory_order_relaxed);
    if (measured_mbps > 0.1) {
        bitrate_bps = measured_mbps * 1000000.0;
    }
    const double pkt_bytes_sec = static_cast<double>(queued_bytes) / (bitrate_bps / 8.0);

    double ahead = std::max({demux_ahead_sec, video_q_sec, pkt_bytes_sec});
    if (player->duration_sec > cur_pts) {
        ahead = std::min(ahead, player->duration_sec - cur_pts);
    }
    return std::max(0.0, ahead);
}

void dk_player_get_stats(DKPlayer* player, DKRuntimeStats* out_stats) {
    DKReaderGuard guard(player);
    if (guard && out_stats) {
        int64_t total_bytes = dk_player_get_total_bytes_read(player);
        double speed_mbs = dk_player_get_download_speed_mbs(player);
        int64_t cached = std::max<int64_t>(0, player->queued_pkt_bytes.load(std::memory_order_relaxed));
        std::lock_guard<std::mutex> lock(player->stats_mtx);
        *out_stats = player->stats;
        out_stats->cached_bytes = cached;
        out_stats->total_bytes_read = total_bytes;
        out_stats->download_speed_mbs = speed_mbs;
    }
}

double dk_player_get_download_speed_mbs(DKPlayer* player) {
    DKReaderGuard guard(player);
    if (!guard) return 0.0;

    auto now = std::chrono::steady_clock::now();
    int64_t cur_bytes = player->total_bytes_read.load(std::memory_order_relaxed);
    if (player->format_ctx && player->format_ctx->pb) {
        int64_t pb_bytes = player->format_ctx->pb->bytes_read;
        if (pb_bytes > cur_bytes) {
            cur_bytes = pb_bytes;
            player->total_bytes_read.store(cur_bytes, std::memory_order_relaxed);
        }
    }

    std::lock_guard<std::mutex> lock(player->speed_mtx);
    double dt = std::chrono::duration<double>(now - player->last_speed_time).count();
    if (dt >= 0.25) {
        int64_t delta = cur_bytes - player->last_speed_bytes;
        if (delta < 0) delta = 0;
        double current_mbs = (static_cast<double>(delta) / (1024.0 * 1024.0)) / dt;

        double prev_mbs = player->instant_download_speed_mbs.load(std::memory_order_relaxed);
        double smoothed = 0.0;
        if (delta > 0) {
            smoothed = (prev_mbs > 0.0) ? ((prev_mbs * 0.35) + (current_mbs * 0.65)) : current_mbs;
        } else {
            smoothed = (dt > 0.6) ? 0.0 : (prev_mbs * 0.25);
        }
        player->instant_download_speed_mbs.store(smoothed, std::memory_order_relaxed);
        player->last_speed_bytes = cur_bytes;
        player->last_speed_time = now;
    }

    return std::max(0.0, player->instant_download_speed_mbs.load(std::memory_order_relaxed));
}

int64_t dk_player_get_total_bytes_read(DKPlayer* player) {
    DKReaderGuard guard(player);
    if (!guard) return 0;
    int64_t cur_bytes = player->total_bytes_read.load(std::memory_order_relaxed);
    if (player->format_ctx && player->format_ctx->pb) {
        int64_t pb_bytes = player->format_ctx->pb->bytes_read;
        if (pb_bytes > cur_bytes) {
            cur_bytes = pb_bytes;
            player->total_bytes_read.store(cur_bytes, std::memory_order_relaxed);
        }
    }
    return cur_bytes;
}

CGImageRef dk_extract_video_thumbnail(const char* file_path_or_url, double target_sec) {
    if (!file_path_or_url) return nullptr;
    std::string path = dk_normalize_path_or_url(file_path_or_url);
    if (path.empty()) return nullptr;

    AVFormatContext* fmt_ctx = nullptr;
    AVDictionary* opts = nullptr;
    av_dict_set(&opts, "scan_all_pmts", "1", 0);
    if (avformat_open_input(&fmt_ctx, path.c_str(), nullptr, &opts) < 0) {
        if (opts) av_dict_free(&opts);
        return nullptr;
    }
    if (opts) av_dict_free(&opts);

    if (avformat_find_stream_info(fmt_ctx, nullptr) < 0) {
        avformat_close_input(&fmt_ctx);
        return nullptr;
    }

    int video_stream_idx = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (video_stream_idx < 0) {
        avformat_close_input(&fmt_ctx);
        return nullptr;
    }

    AVStream* st = fmt_ctx->streams[video_stream_idx];
    const AVCodec* decoder = avcodec_find_decoder(st->codecpar->codec_id);
    if (!decoder) {
        avformat_close_input(&fmt_ctx);
        return nullptr;
    }

    AVCodecContext* codec_ctx = avcodec_alloc_context3(decoder);
    if (!codec_ctx) {
        avformat_close_input(&fmt_ctx);
        return nullptr;
    }
    if (avcodec_parameters_to_context(codec_ctx, st->codecpar) < 0) {
        avcodec_free_context(&codec_ctx);
        avformat_close_input(&fmt_ctx);
        return nullptr;
    }
    codec_ctx->thread_count = 2;
    if (avcodec_open2(codec_ctx, decoder, nullptr) < 0) {
        avcodec_free_context(&codec_ctx);
        avformat_close_input(&fmt_ctx);
        return nullptr;
    }

    if (target_sec > 0.05) {
        int64_t ts = static_cast<int64_t>(target_sec * AV_TIME_BASE);
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
        avcodec_send_packet(codec_ctx, nullptr);
        if (avcodec_receive_frame(codec_ctx, frame) == 0) {
            got_frame = true;
        }
    }

    CGImageRef result_cg = nullptr;
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
            src_w, src_h, (AVPixelFormat)frame->format,
            dst_w, dst_h, AV_PIX_FMT_RGBA,
            SWS_FAST_BILINEAR, nullptr, nullptr, nullptr
        );

        if (sws) {
            std::vector<uint8_t> rgba_data(dst_w * dst_h * 4);
            uint8_t* dst_data[4] = { rgba_data.data(), nullptr, nullptr, nullptr };
            int dst_linesize[4] = { dst_w * 4, 0, 0, 0 };

            sws_scale(sws, frame->data, frame->linesize, 0, src_h, dst_data, dst_linesize);
            sws_freeContext(sws);

            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CFDataRef cf_data = CFDataCreate(kCFAllocatorDefault, rgba_data.data(), rgba_data.size());
            CGDataProviderRef provider = CGDataProviderCreateWithCFData(cf_data);

            result_cg = CGImageCreate(
                dst_w, dst_h, 8, 32, dst_w * 4, cs,
                static_cast<CGBitmapInfo>(kCGImageAlphaNoneSkipLast) | kCGBitmapByteOrderDefault,
                provider, nullptr, true, kCGRenderingIntentDefault
            );

            CGDataProviderRelease(provider);
            CFRelease(cf_data);
            CGColorSpaceRelease(cs);
        }
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&codec_ctx);
    avformat_close_input(&fmt_ctx);

    return result_cg;
}
