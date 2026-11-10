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

static DKLogCallback g_log_callback = nullptr;

void dk_set_log_callback(DKLogCallback callback) {
    g_log_callback = callback;
}

static void dk_log(int level, const char* fmt, ...) {
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    if (g_log_callback) {
        g_log_callback(level, buf);
    }
}

static void dk_ffmpeg_log_callback(void* ptr, int level, const char* fmt, va_list vl) {
    if (level > AV_LOG_INFO) return;
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, vl);
    size_t len = strlen(buf);
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) {
        buf[len - 1] = '\0';
        len--;
    }
    if (len > 0 && g_log_callback) {
        int dk_lvl = (level <= AV_LOG_ERROR) ? 2 : (level <= AV_LOG_WARNING ? 1 : 0);
        g_log_callback(dk_lvl, buf);
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

    // Rust Arena Sliding Cache
    DKRSArenaCache* rs_cache{nullptr};

    // FFmpeg context
    AVFormatContext* format_ctx{nullptr};
    int video_stream_idx{-1};
    std::atomic<int> audio_stream_idx{-1};
    std::atomic<int> sub_stream_idx{-1};

    AVCodecContext* video_codec_ctx{nullptr};
    AVCodecContext* audio_codec_ctx{nullptr};
    AVCodecContext* sub_codec_ctx{nullptr};
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
    uint8_t stream_dovi_profile{0};

    // Demux / Seek / Interrupt
    std::atomic<bool> is_closing{false};
    std::atomic<int> in_flight_readers{0};
    std::atomic<bool> abort_requested{false};
    std::atomic<bool> seek_requested{false};
    std::atomic<double> seek_target_sec{0.0};
    std::atomic<bool> seek_accurate{false};
    std::atomic<double> seek_drop_until_pts{-1.0};
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

    // Master Clock Synchronization
    std::atomic<double> audio_clock_base_pts{-1.0};
    std::atomic<int64_t> audio_clock_base_sample_time{0};
    std::atomic<int64_t> audio_underrun_samples{0};
    std::atomic<bool> audio_clock_calibrated{false};
    std::atomic<double> fallback_audio_clock{0.0};
    std::chrono::steady_clock::time_point fallback_clock_time;

    std::atomic<double> ext_clock_base_pts{0.0};
    std::chrono::steady_clock::time_point ext_clock_start_time;

    // Subtitle (libass)
    ASS_Library* ass_lib{nullptr};
    ASS_Renderer* ass_renderer{nullptr};
    ASS_Track* ass_track{nullptr};
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
    bool sub_last_non_empty{false};

    // Worker Threads
    std::thread demux_thread;
    std::thread video_decode_thread;
    std::thread audio_decode_thread;

    // Runtime Stats
    std::mutex stats_mtx;
    DKRuntimeStats stats{};

    // Download / Throughput Tracking
    std::mutex speed_mtx;
    std::atomic<int64_t> total_bytes_read{0};
    std::atomic<double> instant_download_speed_mbs{0.0};
    int64_t last_speed_bytes{0};
    std::chrono::steady_clock::time_point last_speed_time{std::chrono::steady_clock::now()};
};

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
    } else if (trc == AVCOL_TRC_ARIB_STD_B67) {
        u.transfer_fn = 2;
        u.source_peak_nits = 1000.0f;
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
        if (player->audio_clock_calibrated.load(std::memory_order_relaxed)) {
            player->audio_underrun_samples.fetch_add(static_cast<int64_t>((needed_floats - filled_floats) / 2), std::memory_order_relaxed);
        }
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
        player->fallback_clock_time = std::chrono::steady_clock::now();
        return clock;
    }

    if (player->state.load() == DK_STATE_PLAYING && player->audio_clock_calibrated.load()) {
        auto now = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - player->fallback_clock_time).count() * player->playback_rate.load();
        return player->fallback_audio_clock.load() + elapsed;
    }
    return player->fallback_audio_clock.load();
}

// Master A/V synchronization clock
static double dk_get_master_clock(DKPlayer* player) {
    if (!player || player->abort_requested.load() || player->is_closing.load()) return 0.0;
    if (player->audio_stream_idx >= 0 && player->audio_queue != nullptr) {
        return dk_get_audio_clock(player);
    }
    // Fallback: System monotonic clock when no audio track exists
    if (player->state.load() == DK_STATE_PLAYING) {
        auto now = std::chrono::steady_clock::now();
        double elapsed = std::chrono::duration<double>(now - player->ext_clock_start_time).count() * player->playback_rate.load();
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

    float vol = player->is_muted.load() ? 0.0f : player->volume.load();
    AudioQueueSetParameter(player->audio_queue, kAudioQueueParam_Volume, vol);

    for (int i = 0; i < DKPlayer::kNumAudioBuffers; i++) {
        AudioQueueAllocateBuffer(player->audio_queue, DKPlayer::kAudioBufferSize, &player->audio_buffers[i]);
    }

    return true;
}

// Start audio queue when sufficient initial audio samples are decoded
static void dk_start_audio_queue_with_buffered_data(DKPlayer* player) {
    if (!player || player->abort_requested.load() || player->is_closing.load() || !player->audio_queue || player->audio_queue_started.load()) return;

    {
        std::lock_guard<std::mutex> lock(player->audio_queue_mtx);
        if (player->audio_chunks.empty()) return;
        player->audio_clock_base_pts.store(player->audio_chunks.front().pts);
    }

    player->audio_clock_calibrated.store(false);
    player->audio_clock_base_sample_time.store(0);
    player->audio_underrun_samples.store(0);

    for (int i = 0; i < DKPlayer::kNumAudioBuffers; i++) {
        if (player->audio_buffers[i]) {
            dk_fill_audio_buffer(player, player->audio_buffers[i]);
            AudioQueueEnqueueBuffer(player->audio_queue, player->audio_buffers[i], 0, nullptr);
        }
    }

    if (player->state.load() == DK_STATE_PLAYING) {
        OSStatus startStatus = AudioQueueStart(player->audio_queue, nullptr);
        if (startStatus == noErr) {
            player->audio_queue_started.store(true);
            dk_log(0, "DKEngine: AudioQueue started smoothly (base PTS: %.3fs)", player->audio_clock_base_pts.load());
        } else {
            dk_log(2, "DKEngine Error: AudioQueueStart returned OSStatus %d", static_cast<int>(startStatus));
        }
    }
}

// Worker: Audio decoding and resampling
static void dk_audio_decode_worker(DKPlayer* player) {
    AVPacket* pkt = nullptr;
    AVFrame* frame = av_frame_alloc();

    while (!player->abort_requested.load()) {
        if (player->state.load() == DK_STATE_PAUSED) {
            std::unique_lock<std::mutex> lk(player->audio_pkt_mtx);
            player->audio_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || player->state.load() != DK_STATE_PAUSED || player->seek_requested.load();
            });
            continue;
        }

        // Flow control: keep ~2.5s of audio buffered in RAM (120,000 samples)
        if (player->buffered_audio_samples.load() > 120000) {
            std::unique_lock<std::mutex> lk(player->audio_queue_mtx);
            player->audio_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || player->buffered_audio_samples.load() <= 96000 || player->seek_requested.load();
            });
            if (player->abort_requested.load() || player->seek_requested.load()) continue;
        }

        bool is_flush_pkt = false;
        {
            std::unique_lock<std::mutex> lk(player->audio_pkt_mtx);
            player->audio_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || !player->audio_pkt_queue.empty() || player->seek_requested.load();
            });
            if (player->abort_requested.load()) break;
            if (player->seek_requested.load() || player->audio_pkt_queue.empty()) continue;

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

        while (!player->abort_requested.load() && !player->seek_requested.load()) {
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

            double drop_target = player->seek_drop_until_pts.load(std::memory_order_relaxed);
            if (drop_target > 0.0 && pts + (static_cast<double>(frame->nb_samples) / f_rate) < drop_target - 0.03) {
                av_frame_unref(frame);
                continue;
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

                if (!player->abort_requested.load() && !player->is_closing.load() && !player->audio_queue_started.load() && player->buffered_audio_samples.load() >= 4096) {
                    dk_start_audio_queue_with_buffered_data(player);
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
        if (player->state.load() == DK_STATE_PAUSED) {
            std::unique_lock<std::mutex> lk(player->video_pkt_mtx);
            player->video_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || player->state.load() != DK_STATE_PAUSED || player->seek_requested.load();
            });
            continue;
        }

        // Flow control: keep video queue buffered with up to 12 frames.
        // Wait while queue is full without dropping unrendered frames!
        {
            std::unique_lock<std::mutex> q_lock(player->video_queue_mtx);
            while (player->video_queue.size() >= 12 && !player->abort_requested.load() && !player->seek_requested.load()) {
                player->video_frame_cv.wait_for(q_lock, std::chrono::milliseconds(10));
            }
            if (player->abort_requested.load() || player->seek_requested.load()) continue;
        }

        bool is_flush_pkt = false;
        {
            std::unique_lock<std::mutex> lk(player->video_pkt_mtx);
            player->video_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || !player->video_pkt_queue.empty() || player->seek_requested.load();
            });
            if (player->abort_requested.load()) break;
            if (player->seek_requested.load() || player->video_pkt_queue.empty()) continue;

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

        while (!player->abort_requested.load() && !player->seek_requested.load()) {
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

            double drop_target = player->seek_drop_until_pts.load(std::memory_order_relaxed);
            if (drop_target > 0.0) {
                if (pts < drop_target - 0.04) {
                    av_frame_unref(frame);
                    continue;
                }
                player->seek_drop_until_pts.store(-1.0, std::memory_order_relaxed);
            }

            CVPixelBufferRef pixbuf = nullptr;
            if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                pixbuf = reinterpret_cast<CVPixelBufferRef>(frame->data[3]);
                if (pixbuf) CVPixelBufferRetain(pixbuf);
            } else {
                pixbuf = dk_convert_software_frame_to_cvpixelbuffer(player, frame);
            }

            if (pixbuf) {
                DKGpuColorUniforms color = dk_build_color_uniforms(player, frame, pixbuf);

                std::lock_guard<std::mutex> lock(player->video_queue_mtx);
                player->video_queue.push({ pixbuf, pts, color });
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

static void dk_ensure_default_ass_track_header(DKPlayer* player) {
    if (!player || !player->ass_lib || !player->ass_track) return;
    if (player->ass_track->n_styles > 0) return;
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
    ass_process_codec_private(player->ass_track, const_cast<char*>(default_hdr), static_cast<int>(std::strlen(default_hdr)));
}

static void dk_open_subtitle_decoder_locked(DKPlayer* player, int stream_idx) {
    if (player->sub_codec_ctx) {
        avcodec_free_context(&player->sub_codec_ctx);
    }
    if (player->ass_track) {
        ass_free_track(player->ass_track);
        player->ass_track = nullptr;
    }
    player->pgs_cues.clear();
    player->sub_rgba_buf.clear();
    player->pgs_generation++;
    player->rendered_pgs_gen = 0;
    player->has_bitmap_subs = false;
    player->sub_last_non_empty = false;
    player->sub_serial++;

    if (!player->format_ctx || stream_idx < 0 || static_cast<unsigned>(stream_idx) >= player->format_ctx->nb_streams) {
        return;
    }
    AVStream* st = player->format_ctx->streams[stream_idx];
    if (st->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) return;

    if (player->ass_lib) {
        player->ass_track = ass_new_track(player->ass_lib);
    }
    if (st->codecpar->width > 0 && st->codecpar->height > 0) {
        player->sub_storage_w = st->codecpar->width;
        player->sub_storage_h = st->codecpar->height;
    } else if (player->stats.width > 0 && player->stats.height > 0) {
        player->sub_storage_w = player->stats.width;
        player->sub_storage_h = player->stats.height;
    }

    const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) {
        if (player->ass_track && st->codecpar->extradata && st->codecpar->extradata_size > 0) {
            ass_process_codec_private(player->ass_track, reinterpret_cast<char*>(st->codecpar->extradata), st->codecpar->extradata_size);
        }
        dk_ensure_default_ass_track_header(player);
        return;
    }

    player->sub_codec_ctx = avcodec_alloc_context3(dec);
    if (!player->sub_codec_ctx) return;
    avcodec_parameters_to_context(player->sub_codec_ctx, st->codecpar);
    player->sub_codec_ctx->pkt_timebase = st->time_base;
    if (avcodec_open2(player->sub_codec_ctx, dec, nullptr) < 0) {
        avcodec_free_context(&player->sub_codec_ctx);
        return;
    }

    if (player->ass_track) {
        if (st->codecpar->codec_id == AV_CODEC_ID_ASS || st->codecpar->codec_id == AV_CODEC_ID_SSA) {
            if (st->codecpar->extradata && st->codecpar->extradata_size > 0) {
                ass_process_codec_private(player->ass_track, reinterpret_cast<char*>(st->codecpar->extradata), st->codecpar->extradata_size);
            } else if (player->sub_codec_ctx->subtitle_header && player->sub_codec_ctx->subtitle_header_size > 0) {
                ass_process_codec_private(player->ass_track, reinterpret_cast<char*>(player->sub_codec_ctx->subtitle_header), player->sub_codec_ctx->subtitle_header_size);
            }
            dk_ensure_default_ass_track_header(player);
        } else {
            dk_ensure_default_ass_track_header(player);
        }
    }
    dk_log(0, "DKEngine: Opened embedded subtitle stream #%d (%s)", stream_idx, dec->name ? dec->name : "subtitle");
}

static void dk_decode_subtitle_packet(DKPlayer* player, AVPacket* pkt) {
    if (!player || !pkt || !player->format_ctx) return;
    std::lock_guard<std::mutex> lk(player->ass_mtx);
    const int active_sub_idx = player->sub_stream_idx.load(std::memory_order_relaxed);
    if (active_sub_idx < 0 || pkt->stream_index != active_sub_idx ||
        static_cast<unsigned>(active_sub_idx) >= player->format_ctx->nb_streams) {
        return;
    }
    AVStream* st = player->format_ctx->streams[active_sub_idx];

    int64_t raw_ts = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
    long long pkt_pts_ms = (raw_ts != AV_NOPTS_VALUE)
        ? av_rescale_q(raw_ts, st->time_base, AVRational{1, 1000})
        : 0;
    long long pkt_dur_ms = (pkt->duration > 0)
        ? av_rescale_q(pkt->duration, st->time_base, AVRational{1, 1000})
        : 3500;

    if ((st->codecpar->codec_id == AV_CODEC_ID_ASS || st->codecpar->codec_id == AV_CODEC_ID_SSA) && player->ass_track && pkt->data && pkt->size > 0) {
        dk_ensure_default_ass_track_header(player);
        const char* raw_ass = reinterpret_cast<const char*>(pkt->data);
        if (pkt->size >= 9 && std::strncmp(raw_ass, "Dialogue:", 9) == 0) {
            ass_process_data(player->ass_track, const_cast<char*>(raw_ass), pkt->size);
        } else {
            ass_process_chunk(player->ass_track, const_cast<char*>(raw_ass), pkt->size, pkt_pts_ms, pkt_dur_ms);
        }
        return;
    }

    if (!player->sub_codec_ctx) return;
    AVSubtitle sub{};
    int got_sub = 0;
    int ret = avcodec_decode_subtitle2(player->sub_codec_ctx, &sub, &got_sub, pkt);
    if (ret < 0 || !got_sub) {
        avsubtitle_free(&sub);
        return;
    }

    long long base_ms = (sub.pts != AV_NOPTS_VALUE) ? (sub.pts / 1000) : pkt_pts_ms;
    long long start_ms = base_ms + sub.start_display_time;
    long long dur_ms = (sub.end_display_time > sub.start_display_time && sub.end_display_time < 3600000)
        ? (sub.end_display_time - sub.start_display_time)
        : pkt_dur_ms;

    if (sub.format == 0) {
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
            cue.canvas_w = (player->sub_codec_ctx->width > 0) ? player->sub_codec_ctx->width : player->sub_storage_w;
            cue.canvas_h = (player->sub_codec_ctx->height > 0) ? player->sub_codec_ctx->height : player->sub_storage_h;

            // Measure peak bright-glyph luma across all rects in this PGS cue so UHD Blu-ray
            // HDR-dimmed palettes (e.g. Y=145..180) and standard palettes (Y=235) render at
            // a consistent 245/255 paper-white matching SRT/ASS subtitles.
            float cue_peak_luma = 0.0f;
            for (unsigned r = 0; r < sub.num_rects; r++) {
                const AVSubtitleRect* rect = sub.rects[r];
                if (!rect || rect->type != SUBTITLE_BITMAP || rect->w <= 0 || rect->h <= 0 || !rect->data[0] || !rect->data[1]) continue;
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
    } else if (player->ass_track) {
        dk_ensure_default_ass_track_header(player);
        for (unsigned r = 0; r < sub.num_rects; r++) {
            const AVSubtitleRect* rect = sub.rects[r];
            if (!rect) continue;
            if (rect->type == SUBTITLE_ASS && rect->ass) {
                const char* ass_line = rect->ass;
                if (std::strncmp(ass_line, "Dialogue:", 9) == 0) {
                    ass_process_data(player->ass_track, const_cast<char*>(ass_line), static_cast<int>(std::strlen(ass_line)));
                } else {
                    // Normalize FFmpeg internal ReadOrder chunk style name if needed
                    ass_process_chunk(player->ass_track, const_cast<char*>(ass_line), static_cast<int>(std::strlen(ass_line)), start_ms, dur_ms);
                }
            } else if (rect->type == SUBTITLE_TEXT && rect->text) {
                std::string clean_txt = rect->text;
                std::string formatted;
                for (size_t k = 0; k < clean_txt.size(); k++) {
                    if (clean_txt[k] == '\r') continue;
                    if (clean_txt[k] == '\n') formatted += "\\N";
                    else formatted += clean_txt[k];
                }
                std::string chunk = "0,0,Default,,0,0,0,," + formatted;
                ass_process_chunk(player->ass_track, chunk.data(), static_cast<int>(chunk.size()), start_ms, dur_ms);
            }
        }
    }

    avsubtitle_free(&sub);
}

// Worker: Demuxing, thread-safe seeking, and cache writing
static void dk_demux_worker(DKPlayer* player) {
    AVPacket* pkt = av_packet_alloc();

    while (!player->abort_requested.load()) {
        // Thread-safe seek handling
        if (player->seek_requested.load()) {
            std::lock_guard<std::mutex> lock(player->demux_mtx);
            double target_sec = player->seek_target_sec.load();
            bool accurate = player->seek_accurate.load();

            int64_t target_ts = static_cast<int64_t>(target_sec * AV_TIME_BASE);
            avformat_seek_file(player->format_ctx, -1, INT64_MIN, target_ts, target_ts, AVSEEK_FLAG_BACKWARD);
            player->demux_eof.store(false);
            player->video_eof.store(false);
            player->audio_eof.store(false);
            player->seek_drop_until_pts.store(accurate ? target_sec : -1.0);

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
                if (player->sub_codec_ctx) avcodec_flush_buffers(player->sub_codec_ctx);
                if (player->ass_track) ass_flush_events(player->ass_track);
                player->pgs_cues.clear();
                player->sub_rgba_buf.clear();
                player->pgs_generation++;
                player->rendered_pgs_gen = 0;
                player->sub_last_non_empty = false;
                player->sub_serial++;
            }

            // Flush video decoded frames
            {
                std::lock_guard<std::mutex> vf_lock(player->video_queue_mtx);
                while (!player->video_queue.empty()) {
                    CVPixelBufferRelease(player->video_queue.front().pixel_buffer);
                    player->video_queue.pop();
                }
                player->last_decoded_video_pts = target_sec;
                player->last_pts = target_sec;
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
                player->fallback_audio_clock.store(target_sec);
                player->fallback_clock_time = std::chrono::steady_clock::now();
            }

            if (player->audio_queue) {
                AudioQueueStop(player->audio_queue, true);
                AudioQueueReset(player->audio_queue);
                player->audio_queue_started.store(false);
            }

            player->ext_clock_base_pts.store(target_sec);
            player->ext_clock_start_time = std::chrono::steady_clock::now();
            player->current_pos_sec.store(target_sec);

            if (player->rs_cache) {
                dk_rs_cache_clear(player->rs_cache);
            }

            {
                std::lock_guard<std::mutex> sl(player->speed_mtx);
                player->last_speed_bytes = player->total_bytes_read.load(std::memory_order_relaxed);
                player->last_speed_time = std::chrono::steady_clock::now();
                player->instant_download_speed_mbs.store(0.0, std::memory_order_relaxed);
            }

            dk_log(0, "DKEngine: Seek completed to %.2fs (accurate=%d)", target_sec, accurate ? 1 : 0);
            player->seek_requested.store(false);
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
        const bool mem_enough = (total_pkt_bytes >= (128LL * 1024LL * 1024LL));

        if (time_enough || pkts_enough || mem_enough) {
            std::unique_lock<std::mutex> lock(player->demux_mtx);
            player->demux_cv.wait_for(lock, std::chrono::milliseconds(15));
            continue;
        }

        int ret = av_read_frame(player->format_ctx, pkt);
        if (ret < 0) {
            if (ret == AVERROR_EOF) {
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
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
                continue;
            }
            if (player->abort_requested.load()) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }

        if (player->rs_cache && pkt->data && pkt->size > 0 && pkt->pos >= 0) {
            dk_rs_cache_write(player->rs_cache, pkt->pos, pkt->data, pkt->size);
        }

        if (player->format_ctx && player->format_ctx->pb) {
            int64_t pb_bytes = player->format_ctx->pb->bytes_read;
            if (pb_bytes > 0) {
                player->total_bytes_read.store(pb_bytes, std::memory_order_relaxed);
            } else if (pkt->size > 0) {
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
            if (dk_rs_check_dovi_fel(pkt->data, pkt->size)) {
                std::lock_guard<std::mutex> lock(player->stats_mtx);
                player->stats.is_dolby_vision = true;
            }
            AVPacket* v_copy = av_packet_alloc();
            av_packet_ref(v_copy, pkt);
            {
                std::lock_guard<std::mutex> lock(player->video_pkt_mtx);
                player->video_pkt_queue.push(v_copy);
                player->queued_pkt_bytes.fetch_add(v_copy->size, std::memory_order_relaxed);
            }
            player->video_decode_cv.notify_one();
        } else if (pkt->stream_index == player->audio_stream_idx.load(std::memory_order_relaxed)) {
            AVPacket* a_copy = av_packet_alloc();
            av_packet_ref(a_copy, pkt);
            {
                std::lock_guard<std::mutex> lock(player->audio_pkt_mtx);
                player->audio_pkt_queue.push(a_copy);
                player->queued_pkt_bytes.fetch_add(a_copy->size, std::memory_order_relaxed);
            }
            player->audio_decode_cv.notify_one();
        } else if (pkt->stream_index == player->sub_stream_idx.load(std::memory_order_relaxed)) {
            dk_decode_subtitle_packet(player, pkt);
        }

        av_packet_unref(pkt);
    }

    av_packet_free(&pkt);
}

DKPlayer* dk_player_create(void) {
    av_log_set_level(AV_LOG_INFO);
    av_log_set_callback(dk_ffmpeg_log_callback);
    DKPlayer* player = new DKPlayer();

    // 64MB memory sliding arena, 256KB chunks
    player->rs_cache = dk_rs_cache_create(64 * 1024 * 1024, 256 * 1024);

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
    dk_log(0, "DKEngine: Created native player instance (Rust 64MB arena + libass initialized)");
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
    while (player->in_flight_readers.load(std::memory_order_acquire) > 0) {
        std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
    dk_player_close(player);

    if (player->ass_track) {
        ass_free_track(player->ass_track);
        player->ass_track = nullptr;
    }
    if (player->ass_renderer) {
        ass_renderer_done(player->ass_renderer);
        player->ass_renderer = nullptr;
    }
    if (player->ass_lib) {
        ass_library_done(player->ass_lib);
        player->ass_lib = nullptr;
    }
    if (player->rs_cache) {
        dk_rs_cache_destroy(player->rs_cache);
        player->rs_cache = nullptr;
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

int dk_player_open(DKPlayer* player, const char* url, const char* headers_crlf, double start_sec, bool hw_decode) {
    if (!player || !url) return -1;
    dk_player_close(player);

    std::string normalized_url = dk_normalize_path_or_url(url);
    const char* open_target = normalized_url.c_str();
    bool is_local_file = (!normalized_url.empty() && normalized_url[0] == '/');

    dk_log(0, "DKEngine: Opening URL: %s (target=%s, local=%d, hw_decode=%d, start=%.2fs)",
           url, open_target, is_local_file ? 1 : 0, hw_decode ? 1 : 0, start_sec);
    auto start_time = std::chrono::steady_clock::now();

    player->state.store(DK_STATE_OPENING);
    player->is_closing.store(false);
    player->current_url = open_target;
    player->hw_decode_enabled = hw_decode;
    player->vt_failed.store(false);
    player->stream_dovi_profile = 0;
    player->demux_eof.store(false);
    player->video_eof.store(false);
    player->audio_eof.store(false);
    player->seek_drop_until_pts.store(-1.0);
    player->queued_pkt_bytes.store(0);
    player->last_demuxed_pts.store(std::max(0.0, start_sec));
    player->last_decoded_video_pts = -1.0;
    player->abort_requested.store(false);
    player->seek_requested.store(false);
    player->video_stream_idx = -1;
    player->audio_stream_idx.store(-1);
    player->sub_stream_idx.store(-1);
    {
        std::lock_guard<std::mutex> lk(player->stats_mtx);
        player->stats = DKRuntimeStats{};
    }

    AVDictionary* opts = nullptr;
    if (is_local_file) {
        av_dict_set(&opts, "probesize", "10485760", 0);
        av_dict_set(&opts, "analyzeduration", "5000000", 0);
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
        av_dict_set(&opts, "probesize", "10485760", 0);
        av_dict_set(&opts, "analyzeduration", "5000000", 0);
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

    int open_ret = avformat_open_input(&player->format_ctx, open_target, nullptr, &opts);
    av_dict_free(&opts);
    if (open_ret < 0) {
        char errbuf[256];
        av_strerror(open_ret, errbuf, sizeof(errbuf));
        dk_log(2, "DKEngine Error: avformat_open_input failed (%d: %s)", open_ret, errbuf);
        avformat_free_context(player->format_ctx);
        player->format_ctx = nullptr;
        player->state.store(DK_STATE_ERROR);
        return -1;
    }

    if (avformat_find_stream_info(player->format_ctx, nullptr) < 0) {
        dk_log(2, "DKEngine Error: avformat_find_stream_info failed");
        player->state.store(DK_STATE_ERROR);
        return -1;
    }

    auto open_elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start_time).count();
    dk_log(0, "DKEngine: Stream connected and parsed in %.1fms (nb_streams=%u)", open_elapsed, player->format_ctx->nb_streams);

    if (player->format_ctx->duration > 0) {
        player->duration_sec = static_cast<double>(player->format_ctx->duration) / AV_TIME_BASE;
    } else {
        player->duration_sec = 0.0;
    }

    int preferred_audio_idx = -1;
    int preferred_sub_idx = -1;
    for (unsigned int i = 0; i < player->format_ctx->nb_streams; i++) {
        AVStream* st = player->format_ctx->streams[i];
        if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            if (preferred_audio_idx < 0 || (st->disposition & AV_DISPOSITION_DEFAULT)) {
                if (preferred_audio_idx < 0 || !(player->format_ctx->streams[preferred_audio_idx]->disposition & AV_DISPOSITION_DEFAULT)) {
                    preferred_audio_idx = static_cast<int>(i);
                }
            }
        } else if (st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            const AVDictionaryEntry* lang_tag = av_dict_get(st->metadata, "language", nullptr, 0);
            std::string lang = lang_tag && lang_tag->value ? lang_tag->value : "";
            bool is_zh = (lang.find("chi") != std::string::npos || lang.find("zho") != std::string::npos || lang.find("zh") != std::string::npos);
            if (preferred_sub_idx < 0) {
                preferred_sub_idx = static_cast<int>(i);
            } else if ((st->disposition & AV_DISPOSITION_DEFAULT) || is_zh) {
                AVStream* cur_st = player->format_ctx->streams[preferred_sub_idx];
                const AVDictionaryEntry* cur_lang_tag = av_dict_get(cur_st->metadata, "language", nullptr, 0);
                std::string cur_lang = cur_lang_tag && cur_lang_tag->value ? cur_lang_tag->value : "";
                bool cur_zh = (cur_lang.find("chi") != std::string::npos || cur_lang.find("zho") != std::string::npos || cur_lang.find("zh") != std::string::npos);
                if (!cur_zh && is_zh) {
                    preferred_sub_idx = static_cast<int>(i);
                }
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
                avcodec_open2(player->video_codec_ctx, dec, nullptr);

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
                }
            }
        } else if (st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE && player->sub_stream_idx < 0 &&
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
    if (start_sec > 0.5) {
        int64_t target_ts = static_cast<int64_t>(start_sec * AV_TIME_BASE);
        avformat_seek_file(player->format_ctx, -1, INT64_MIN, target_ts, target_ts, AVSEEK_FLAG_BACKWARD);
        player->seek_drop_until_pts.store(start_sec);
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

    player->ext_clock_start_time = std::chrono::steady_clock::now();
    player->fallback_clock_time = std::chrono::steady_clock::now();

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
        player->pgs_cues.clear();
    }

    if (player->video_codec_ctx) { avcodec_free_context(&player->video_codec_ctx); }
    if (player->audio_codec_ctx) { avcodec_free_context(&player->audio_codec_ctx); }
    if (player->hw_device_ctx) { av_buffer_unref(&player->hw_device_ctx); }
    if (player->format_ctx) { avformat_close_input(&player->format_ctx); }

    if (player->rs_cache) {
        dk_rs_cache_clear(player->rs_cache);
    }

    player->video_stream_idx = -1;
    player->audio_stream_idx = -1;
    player->sub_stream_idx = -1;
    player->audio_queue_started.store(false);
    player->state.store(DK_STATE_IDLE);
}

void dk_player_play(DKPlayer* player) {
    DKReaderGuard guard(player);
    if (!guard) return;
    if (player && player->state.load() == DK_STATE_PAUSED) {
        player->state.store(DK_STATE_PLAYING);
        if (player->audio_queue && player->audio_queue_started.load()) {
            AudioQueueStart(player->audio_queue, nullptr);
        }
        player->ext_clock_start_time = std::chrono::steady_clock::now();
        player->fallback_clock_time = std::chrono::steady_clock::now();
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
    player->seek_target_sec.store(target_sec);
    player->seek_accurate.store(accurate);
    player->seek_requested.store(true);
    player->demux_cv.notify_all();
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
    player->ext_clock_start_time = std::chrono::steady_clock::now();
    player->fallback_audio_clock.store(current_pos);
    player->fallback_clock_time = std::chrono::steady_clock::now();
}

void dk_player_set_volume(DKPlayer* player, float volume, bool muted) {
    DKReaderGuard guard(player);
    if (!guard) return;
    player->volume.store(volume);
    player->is_muted.store(muted);
    if (player->audio_queue) {
        float effective_vol = muted ? 0.0f : volume;
        AudioQueueSetParameter(player->audio_queue, kAudioQueueParam_Volume, effective_vol);
    }
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

void dk_player_select_track(DKPlayer* player, int track_type, int stream_index) {
    DKReaderGuard guard(player);
    if (!guard || !player->format_ctx) return;
    if (track_type == 1) { // Audio
        if (stream_index < 0 || static_cast<unsigned int>(stream_index) >= player->format_ctx->nb_streams) return;
        if (player->format_ctx->streams[stream_index]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) return;
        if (player->audio_stream_idx.load() == stream_index) return;

        double cur_pts = dk_get_master_clock(player);
        std::lock_guard<std::mutex> codec_lk(player->audio_codec_mtx);

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
        }

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
            }
        }
        player->seek_target_sec.store(cur_pts);
        player->seek_accurate.store(true);
        player->seek_requested.store(true);
        player->demux_cv.notify_all();
    } else if (track_type == 2) { // Subtitle
        if (stream_index >= 0) {
            if (static_cast<unsigned int>(stream_index) >= player->format_ctx->nb_streams ||
                player->format_ctx->streams[stream_index]->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) {
                dk_log(1, "DKEngine: Ignored invalid subtitle stream index %d", stream_index);
                return;
            }
        }
        double cur_pts = dk_get_master_clock(player);
        {
            std::lock_guard<std::mutex> slk(player->ass_mtx);
            player->sub_stream_idx.store(stream_index);
            dk_open_subtitle_decoder_locked(player, stream_index);
        }
        if (stream_index >= 0) {
            player->seek_target_sec.store(std::max(0.0, cur_pts));
            player->seek_accurate.store(true);
            player->seek_requested.store(true);
            player->demux_cv.notify_all();
        } else {
            dk_log(0, "DKEngine: Subtitles disabled by user");
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

void dk_player_load_external_subtitle(DKPlayer* player, const char* content_utf8, bool is_ass) {
    DKReaderGuard guard(player);
    if (!guard || !content_utf8 || !player->ass_lib) return;

    std::lock_guard<std::mutex> slk(player->ass_mtx);
    player->sub_stream_idx.store(-1);
    if (player->sub_codec_ctx) {
        avcodec_free_context(&player->sub_codec_ctx);
    }
    player->pgs_cues.clear();
    player->sub_rgba_buf.clear();
    player->has_bitmap_subs = false;
    player->rendered_pgs_gen = 0;
    player->sub_last_non_empty = false;
    player->sub_serial++;
    if (player->ass_track) {
        ass_free_track(player->ass_track);
        player->ass_track = nullptr;
    }

    size_t len = std::strlen(content_utf8);
    if (len == 0) return;

    if (is_ass) {
        player->ass_track = ass_read_memory(player->ass_lib, const_cast<char*>(content_utf8), len, nullptr);
        if (player->ass_track) {
            dk_ensure_default_ass_track_header(player);
        }
        return;
    }

    player->ass_track = ass_new_track(player->ass_lib);
    if (!player->ass_track) return;
    dk_ensure_default_ass_track_header(player);

    std::string text(content_utf8, len);
    if (text.size() >= 3 && static_cast<uint8_t>(text[0]) == 0xEF && static_cast<uint8_t>(text[1]) == 0xBB && static_cast<uint8_t>(text[2]) == 0xBF) {
        text.erase(0, 3);
    }

    size_t pos = 0;
    long long cue_start = -1, cue_end = -1;
    std::string cue_body;
    auto flush_cue = [&]() {
        if (cue_start >= 0 && cue_end > cue_start && !cue_body.empty()) {
            std::string chunk = "0,0,Default,,0,0,0,," + dk_sanitize_srt_vtt_tags(cue_body);
            ass_process_chunk(player->ass_track, chunk.data(), static_cast<int>(chunk.size()), cue_start, cue_end - cue_start);
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

CVPixelBufferRef dk_player_acquire_frame(DKPlayer* player, double* out_pts, DKGpuColorUniforms* out_color) {
    DKReaderGuard guard(player);
    if (!guard) return nullptr;

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

    // Always immediately deliver the very first frame to initialize the surface without black screen
    if (player->last_frame == nullptr && !player->video_queue.empty()) {
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
        dk_log(0, "DKEngine: First video frame presented immediately (PTS: %.3fs)", player->last_pts);
        return player->last_frame;
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

    if (canvas_w > 1920) {
        canvas_h = std::max(1, (canvas_h * 1920) / canvas_w);
        canvas_w = 1920;
    }

    std::lock_guard<std::mutex> lock(player->ass_mtx);
    *out_serial = player->sub_serial;

    if (player->has_bitmap_subs) {
        while (!player->pgs_cues.empty() && player->pgs_cues.front().end_sec < pts - 2.0) {
            player->pgs_cues.pop_front();
        }
        const PgsCue* active_cue = nullptr;
        for (const auto& cue : player->pgs_cues) {
            if (pts >= cue.start_sec && pts < cue.end_sec && !cue.rects.empty()) {
                active_cue = &cue;
                break;
            }
        }
        if (!active_cue) {
            if (player->sub_last_non_empty) {
                player->sub_last_non_empty = false;
                player->sub_serial++;
            }
            *out_serial = player->sub_serial;
            return false;
        }
        int cue_w = std::max(1, active_cue->canvas_w);
        int cue_h = std::max(1, active_cue->canvas_h);
        int dst_w = cue_w;
        int dst_h = (canvas_w > 0 && canvas_h > 0) ? std::max(1, (cue_w * canvas_h) / canvas_w) : cue_h;
        int crop_top = (cue_h > dst_h + 20) ? ((cue_h - dst_h) / 2) : 0;

        if (player->rendered_pgs_gen != active_cue->id || player->ass_canvas_w != dst_w || player->ass_canvas_h != dst_h) {
            player->ass_canvas_w = dst_w;
            player->ass_canvas_h = dst_h;
            player->sub_rgba_buf.assign(static_cast<size_t>(dst_w) * static_cast<size_t>(dst_h) * 4, 0);
            for (const auto& r : active_cue->rects) {
                int mapped_y = r.y - crop_top;
                int base_y = std::clamp(mapped_y, 8, std::max(8, dst_h - r.h - 14));
                int base_x = (r.x + r.w > dst_w) ? std::max(0, dst_w - r.w) : std::max(0, r.x);
                for (int y = 0; y < r.h; y++) {
                    int dy = base_y + y;
                    if (dy < 0 || dy >= dst_h) continue;
                    for (int x = 0; x < r.w; x++) {
                        int dx = base_x + x;
                        if (dx < 0 || dx >= dst_w) continue;
                        const uint8_t* sp = &r.rgba[(static_cast<size_t>(y) * r.w + x) * 4];
                        uint8_t* dp = &player->sub_rgba_buf[(static_cast<size_t>(dy) * dst_w + dx) * 4];
                        uint8_t inv_a = 255 - sp[3];
                        dp[0] = static_cast<uint8_t>(std::min(255, sp[0] + (dp[0] * inv_a + 127) / 255));
                        dp[1] = static_cast<uint8_t>(std::min(255, sp[1] + (dp[1] * inv_a + 127) / 255));
                        dp[2] = static_cast<uint8_t>(std::min(255, sp[2] + (dp[2] * inv_a + 127) / 255));
                        dp[3] = static_cast<uint8_t>(std::min(255, sp[3] + (dp[3] * inv_a + 127) / 255));
                    }
                }
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

    if (!player->ass_renderer || !player->ass_track) {
        if (player->sub_last_non_empty) {
            player->sub_last_non_empty = false;
            player->sub_serial++;
            *out_serial = player->sub_serial;
        }
        return false;
    }
    if (player->ass_canvas_w != canvas_w || player->ass_canvas_h != canvas_h) {
        player->ass_canvas_w = canvas_w;
        player->ass_canvas_h = canvas_h;
        ass_set_frame_size(player->ass_renderer, canvas_w, canvas_h);
        ass_set_storage_size(player->ass_renderer, canvas_w, canvas_h);
    }

    long long now_ms = static_cast<long long>(pts * 1000.0);
    int change = 0;
    ASS_Image* img = ass_render_frame(player->ass_renderer, player->ass_track, now_ms, &change);
    if (!img) {
        if (player->sub_last_non_empty) {
            player->sub_last_non_empty = false;
            player->sub_serial++;
        }
        *out_serial = player->sub_serial;
        return false;
    }

    if (change != 0 || !player->sub_last_non_empty || player->sub_rgba_buf.size() != static_cast<size_t>(canvas_w) * canvas_h * 4) {
        player->sub_rgba_buf.assign(static_cast<size_t>(canvas_w) * canvas_h * 4, 0);
        for (ASS_Image* cur = img; cur != nullptr; cur = cur->next) {
            if (cur->w <= 0 || cur->h <= 0 || !cur->bitmap) continue;
            uint8_t cr = (cur->color >> 24) & 0xFF;
            uint8_t cg = (cur->color >> 16) & 0xFF;
            uint8_t cb = (cur->color >> 8) & 0xFF;
            uint8_t ca = 255 - (cur->color & 0xFF);
            if (ca == 0) continue;

            // Keep neutral white/grey dialogue styles uniform with normalized 245/255 PGS white
            int max_c = std::max({static_cast<int>(cr), static_cast<int>(cg), static_cast<int>(cb)});
            int min_c = std::min({static_cast<int>(cr), static_cast<int>(cg), static_cast<int>(cb)});
            if (max_c >= 140 && (max_c - min_c) <= 18) {
                float scale = 245.0f / static_cast<float>(max_c);
                cr = static_cast<uint8_t>(std::clamp(static_cast<int>(std::lround(cr * scale)), 0, 255));
                cg = static_cast<uint8_t>(std::clamp(static_cast<int>(std::lround(cg * scale)), 0, 255));
                cb = static_cast<uint8_t>(std::clamp(static_cast<int>(std::lround(cb * scale)), 0, 255));
            }

            for (int y = 0; y < cur->h; y++) {
                int dy = cur->dst_y + y;
                if (dy < 0 || dy >= canvas_h) continue;
                const uint8_t* mask_row = cur->bitmap + y * cur->stride;
                uint8_t* dst_row = player->sub_rgba_buf.data() + static_cast<size_t>(dy) * canvas_w * 4;
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
        player->sub_last_non_empty = true;
        player->sub_serial++;
    }

    *out_rgba = player->sub_rgba_buf.data();
    *out_w = canvas_w;
    *out_h = canvas_h;
    *out_serial = player->sub_serial;
    return true;
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
    if (player->stats.video_bitrate_mbps > 0.1) {
        bitrate_bps = player->stats.video_bitrate_mbps * 1000000.0;
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
        std::lock_guard<std::mutex> lock(player->stats_mtx);
        *out_stats = player->stats;
        out_stats->cached_bytes = dk_rs_cache_get_bytes(player->rs_cache);
        out_stats->total_bytes_read = dk_player_get_total_bytes_read(player);
        out_stats->download_speed_mbs = dk_player_get_download_speed_mbs(player);
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
