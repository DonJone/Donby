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
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <ass/ass.h>
}

#include <AudioToolbox/AudioToolbox.h>
#include <CoreVideo/CoreVideo.h>
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
};

struct AudioChunk {
    std::vector<float> pcm; // Canonical interleaved stereo Float32 (L, R, L, R...)
    double pts{0.0};
    size_t read_offset{0};
};

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
    int audio_stream_idx{-1};
    int sub_stream_idx{-1};

    AVCodecContext* video_codec_ctx{nullptr};
    AVCodecContext* audio_codec_ctx{nullptr};
    AVBufferRef* hw_device_ctx{nullptr};
    SwrContext* swr_ctx{nullptr};
    SwsContext* sws_ctx{nullptr};

    // Demux / Seek / Interrupt
    std::atomic<bool> is_closing{false};
    std::atomic<int> in_flight_readers{0};
    std::atomic<bool> abort_requested{false};
    std::atomic<bool> seek_requested{false};
    std::atomic<double> seek_target_sec{0.0};
    std::atomic<bool> seek_accurate{false};
    std::mutex demux_mtx;
    std::condition_variable demux_cv;

    // Packet Queues
    std::mutex video_pkt_mtx;
    std::queue<AVPacket*> video_pkt_queue;
    std::condition_variable video_decode_cv;

    std::mutex audio_pkt_mtx;
    std::queue<AVPacket*> audio_pkt_queue;
    std::condition_variable audio_decode_cv;

    // Decoded Video Frame Queue
    std::mutex video_queue_mtx;
    std::queue<VideoFrameEntry> video_queue;
    std::condition_variable video_frame_cv;
    CVPixelBufferRef last_frame{nullptr};
    double last_pts{0.0};

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

    // Worker Threads
    std::thread demux_thread;
    std::thread video_decode_thread;
    std::thread audio_decode_thread;

    // Runtime Stats
    std::mutex stats_mtx;
    DKRuntimeStats stats{};
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
    for (const enum AVPixelFormat* p = pix_fmts; *p != -1; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
            return *p;
        }
    }
    return AV_PIX_FMT_NONE;
}

// Convert software AVFrame to bi-planar NV12 CVPixelBuffer (Plane 0: Y, Plane 1: UV interleaved)
static CVPixelBufferRef dk_convert_software_frame_to_cvpixelbuffer(DKPlayer* player, AVFrame* frame) {
    int width = frame->width;
    int height = frame->height;
    if (width <= 0 || height <= 0) return nullptr;

    player->sws_ctx = sws_getCachedContext(
        player->sws_ctx,
        width, height, static_cast<AVPixelFormat>(frame->format),
        width, height, AV_PIX_FMT_NV12,
        SWS_BILINEAR, nullptr, nullptr, nullptr
    );
    if (!player->sws_ctx) return nullptr;

    CVPixelBufferRef pixbuf = nullptr;
    CFDictionaryRef empty_dict = CFDictionaryCreate(
        kCFAllocatorDefault, nullptr, nullptr, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        empty_dict,
        &pixbuf
    );
    if (empty_dict) CFRelease(empty_dict);

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
            player->audio_clock_calibrated.store(true);
            dk_log(0, "DKEngine: Master audio clock calibrated at hardware sample %lld (base PTS: %.3fs)",
                   static_cast<long long>(ts.mSampleTime), player->audio_clock_base_pts.load());
        }
        int64_t sample_diff = static_cast<int64_t>(ts.mSampleTime) - player->audio_clock_base_sample_time.load();
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

// Resampler configuration (48000 Hz stereo Float32)
static bool dk_setup_swr(DKPlayer* player) {
    if (!player || !player->audio_codec_ctx) return false;
    if (player->swr_ctx) {
        swr_free(&player->swr_ctx);
    }

    AVChannelLayout out_layout;
    av_channel_layout_default(&out_layout, 2);

    AVChannelLayout in_layout;
    if (player->audio_codec_ctx->ch_layout.nb_channels > 0) {
        av_channel_layout_copy(&in_layout, &player->audio_codec_ctx->ch_layout);
    } else {
        av_channel_layout_default(&in_layout, 2);
    }

    int in_sample_rate = player->audio_codec_ctx->sample_rate > 0 ? player->audio_codec_ctx->sample_rate : 48000;
    enum AVSampleFormat in_fmt = player->audio_codec_ctx->sample_fmt != AV_SAMPLE_FMT_NONE ? player->audio_codec_ctx->sample_fmt : AV_SAMPLE_FMT_FLTP;

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

    return swr_init(player->swr_ctx) >= 0;
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

        {
            std::unique_lock<std::mutex> lk(player->audio_pkt_mtx);
            player->audio_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || !player->audio_pkt_queue.empty() || player->seek_requested.load();
            });
            if (player->abort_requested.load()) break;
            if (player->seek_requested.load() || player->audio_pkt_queue.empty()) continue;

            pkt = player->audio_pkt_queue.front();
            player->audio_pkt_queue.pop();
        }
        player->demux_cv.notify_one();

        if (!player->audio_codec_ctx) {
            av_packet_free(&pkt);
            continue;
        }

        int ret = avcodec_send_packet(player->audio_codec_ctx, pkt);
        av_packet_free(&pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN)) {
            continue;
        }

        while (!player->abort_requested.load()) {
            ret = avcodec_receive_frame(player->audio_codec_ctx, frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF || ret < 0) {
                break;
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
    }

    av_frame_free(&frame);
}

// Worker: Video decoding and frame conversion
static void dk_video_decode_worker(DKPlayer* player) {
    AVPacket* pkt = nullptr;
    AVFrame* frame = av_frame_alloc();

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

        {
            std::unique_lock<std::mutex> lk(player->video_pkt_mtx);
            player->video_decode_cv.wait_for(lk, std::chrono::milliseconds(15), [player] {
                return player->abort_requested.load() || !player->video_pkt_queue.empty() || player->seek_requested.load();
            });
            if (player->abort_requested.load()) break;
            if (player->seek_requested.load() || player->video_pkt_queue.empty()) continue;

            pkt = player->video_pkt_queue.front();
            player->video_pkt_queue.pop();
        }
        player->demux_cv.notify_one();

        if (!player->video_codec_ctx) {
            av_packet_free(&pkt);
            continue;
        }

        int ret = avcodec_send_packet(player->video_codec_ctx, pkt);
        av_packet_free(&pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN)) {
            continue;
        }

        while (!player->abort_requested.load()) {
            ret = avcodec_receive_frame(player->video_codec_ctx, frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF || ret < 0) {
                break;
            }

            CVPixelBufferRef pixbuf = nullptr;
            if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                pixbuf = reinterpret_cast<CVPixelBufferRef>(frame->data[3]);
                if (pixbuf) CVPixelBufferRetain(pixbuf);
            } else {
                pixbuf = dk_convert_software_frame_to_cvpixelbuffer(player, frame);
            }

            if (pixbuf) {
                double pts = 0.0;
                if (frame->best_effort_timestamp != AV_NOPTS_VALUE && player->video_stream_idx >= 0 && player->format_ctx) {
                    pts = frame->best_effort_timestamp * av_q2d(player->format_ctx->streams[player->video_stream_idx]->time_base);
                } else if (frame->pts != AV_NOPTS_VALUE && player->video_stream_idx >= 0 && player->format_ctx) {
                    pts = frame->pts * av_q2d(player->format_ctx->streams[player->video_stream_idx]->time_base);
                }

                std::lock_guard<std::mutex> lock(player->video_queue_mtx);
                player->video_queue.push({ pixbuf, pts });
            }

            av_frame_unref(frame);
        }
    }

    av_frame_free(&frame);
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
            avformat_seek_file(player->format_ctx, -1, INT64_MIN, target_ts, INT64_MAX, accurate ? 0 : AVSEEK_FLAG_BACKWARD);

            // Flush packet queues
            {
                std::lock_guard<std::mutex> v_lock(player->video_pkt_mtx);
                while (!player->video_pkt_queue.empty()) {
                    AVPacket* p = player->video_pkt_queue.front();
                    player->video_pkt_queue.pop();
                    av_packet_free(&p);
                }
            }
            {
                std::lock_guard<std::mutex> a_lock(player->audio_pkt_mtx);
                while (!player->audio_pkt_queue.empty()) {
                    AVPacket* p = player->audio_pkt_queue.front();
                    player->audio_pkt_queue.pop();
                    av_packet_free(&p);
                }
            }

            // Flush decoders
            if (player->video_codec_ctx) avcodec_flush_buffers(player->video_codec_ctx);
            if (player->audio_codec_ctx) avcodec_flush_buffers(player->audio_codec_ctx);

            // Flush video decoded frames
            {
                std::lock_guard<std::mutex> vf_lock(player->video_queue_mtx);
                while (!player->video_queue.empty()) {
                    CVPixelBufferRelease(player->video_queue.front().pixel_buffer);
                    player->video_queue.pop();
                }
            }

            // Flush audio queue and AudioQueue hardware buffers
            {
                std::lock_guard<std::mutex> aq_lock(player->audio_queue_mtx);
                player->audio_chunks.clear();
                player->buffered_audio_samples.store(0);
                player->audio_clock_base_pts.store(target_sec);
                player->audio_clock_calibrated.store(false);
    player->audio_clock_base_sample_time.store(0);
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
        if (v_pkts >= 60 || a_pkts >= 120) {
            std::unique_lock<std::mutex> lock(player->demux_mtx);
            player->demux_cv.wait_for(lock, std::chrono::milliseconds(15));
            continue;
        }

        int ret = av_read_frame(player->format_ctx, pkt);
        if (ret < 0) {
            if (ret == AVERROR_EOF) {
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
            }
            player->video_decode_cv.notify_one();
        } else if (pkt->stream_index == player->audio_stream_idx) {
            AVPacket* a_copy = av_packet_alloc();
            av_packet_ref(a_copy, pkt);
            {
                std::lock_guard<std::mutex> lock(player->audio_pkt_mtx);
                player->audio_pkt_queue.push(a_copy);
            }
            player->audio_decode_cv.notify_one();
        } else if (pkt->stream_index == player->sub_stream_idx && player->ass_track) {
            std::lock_guard<std::mutex> lock(player->ass_mtx);
            ass_process_chunk(player->ass_track, reinterpret_cast<char*>(pkt->data), pkt->size, pkt->pts, pkt->duration);
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

int dk_player_open(DKPlayer* player, const char* url, const char* headers_crlf, double start_sec, bool hw_decode) {
    if (!player || !url) return -1;
    dk_player_close(player);

    dk_log(0, "DKEngine: Opening URL: %s (hw_decode=%d, start=%.2fs)", url, hw_decode ? 1 : 0, start_sec);
    auto start_time = std::chrono::steady_clock::now();

    player->state.store(DK_STATE_OPENING);
    player->is_closing.store(false);
    player->current_url = url;
    player->hw_decode_enabled = hw_decode;
    player->abort_requested.store(false);
    player->seek_requested.store(false);
    player->video_stream_idx = -1;
    player->audio_stream_idx = -1;
    player->sub_stream_idx = -1;

    AVDictionary* opts = nullptr;
    av_dict_set(&opts, "reconnect", "1", 0);
    av_dict_set(&opts, "reconnect_streamed", "1", 0);
    av_dict_set(&opts, "reconnect_delay_max", "3", 0);
    av_dict_set(&opts, "rw_timeout", "3000000", 0);
    av_dict_set(&opts, "timeout", "3000000", 0);
    av_dict_set(&opts, "probesize", "1048576", 0);        // 1MB probe size for fast network stream start
    av_dict_set(&opts, "analyzeduration", "2000000", 0);   // 2s analyze duration limit
    av_dict_set(&opts, "tcp_nodelay", "1", 0);
    av_dict_set(&opts, "buffer_size", "1048576", 0);
    if (headers_crlf && std::strlen(headers_crlf) > 0) {
        av_dict_set(&opts, "headers", headers_crlf, 0);
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

    int open_ret = avformat_open_input(&player->format_ctx, url, nullptr, &opts);
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

    for (unsigned int i = 0; i < player->format_ctx->nb_streams; i++) {
        AVStream* st = player->format_ctx->streams[i];
        if (st->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && player->video_stream_idx < 0) {
            player->video_stream_idx = i;
            const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
            if (dec) {
                player->video_codec_ctx = avcodec_alloc_context3(dec);
                avcodec_parameters_to_context(player->video_codec_ctx, st->codecpar);

                if (hw_decode) {
                    if (av_hwdevice_ctx_create(&player->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0) == 0) {
                        player->video_codec_ctx->hw_device_ctx = av_buffer_ref(player->hw_device_ctx);
                        player->video_codec_ctx->get_format = dk_get_hw_format;
                        player->stats.is_hw_accelerated = true;
                    }
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
                if (st->codecpar->color_trc == AVCOL_TRC_SMPTE2084) {
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
        } else if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && player->audio_stream_idx < 0) {
            player->audio_stream_idx = i;
            const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
            if (dec) {
                player->audio_codec_ctx = avcodec_alloc_context3(dec);
                avcodec_parameters_to_context(player->audio_codec_ctx, st->codecpar);
                if (avcodec_open2(player->audio_codec_ctx, dec, nullptr) == 0) {
                    dk_setup_swr(player);
                    std::snprintf(player->stats.audio_codec, sizeof(player->stats.audio_codec), "%s", dec->name);
                    dk_log(0, "DKEngine: Audio Stream #%u: %s (%d channels, %dHz)",
                           i, dec->name, st->codecpar->ch_layout.nb_channels, st->codecpar->sample_rate);
                }
            }
        } else if (st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE && player->sub_stream_idx < 0) {
            player->sub_stream_idx = i;
        }
    }

    if (player->audio_codec_ctx && player->swr_ctx) {
        dk_init_audio_queue(player);
    }

    if (player->ass_lib && player->ass_renderer && !player->ass_track) {
        player->ass_track = ass_new_track(player->ass_lib);
    }

    player->audio_clock_calibrated.store(false);
    player->audio_clock_base_sample_time.store(0);
    if (start_sec > 0.5) {
        int64_t target_ts = static_cast<int64_t>(start_sec * AV_TIME_BASE);
        avformat_seek_file(player->format_ctx, -1, INT64_MIN, target_ts, INT64_MAX, 0);
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
            av_packet_free(&p);
        }
    }
    {
        std::lock_guard<std::mutex> lock(player->audio_pkt_mtx);
        while (!player->audio_pkt_queue.empty()) {
            AVPacket* p = player->audio_pkt_queue.front();
            player->audio_pkt_queue.pop();
            av_packet_free(&p);
        }
    }

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

void dk_player_select_track(DKPlayer* player, int track_type, int stream_index) {
    DKReaderGuard guard(player);
    if (!guard || !player->format_ctx) return;
    if (track_type == 1) { // Audio
        if (stream_index < 0 || static_cast<unsigned int>(stream_index) >= player->format_ctx->nb_streams) return;
        if (player->format_ctx->streams[stream_index]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) return;
        if (player->audio_stream_idx == stream_index) return;

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
                av_packet_free(&p);
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
            if (avcodec_open2(player->audio_codec_ctx, dec, nullptr) == 0) {
                player->audio_stream_idx = stream_index;
                dk_setup_swr(player);
                std::lock_guard<std::mutex> lock(player->stats_mtx);
                std::snprintf(player->stats.audio_codec, sizeof(player->stats.audio_codec), "%s", dec->name);
            }
        }
    } else if (track_type == 2) { // Subtitle
        player->sub_stream_idx = stream_index;
    }
}

// Frame acquisition called by 60Hz display link with precision A/V synchronization
CVPixelBufferRef dk_player_acquire_frame_for_host_time(DKPlayer* player, double* out_pts) {
    DKReaderGuard guard(player);
    if (!guard) return nullptr;

    double master_pts = dk_get_master_clock(player);

    std::unique_lock<std::mutex> lock(player->video_queue_mtx);
    if (player->video_queue.empty()) {
        if (player->last_frame) {
            CVPixelBufferRetain(player->last_frame);
            if (out_pts) *out_pts = player->last_pts;
            return player->last_frame;
        }
        return nullptr;
    }

    // Always immediately deliver the very first frame to initialize the surface without black screen
    if (player->last_frame == nullptr && !player->video_queue.empty()) {
        auto& front = player->video_queue.front();
        player->last_frame = front.pixel_buffer;
        player->last_pts = front.pts;
        player->current_pos_sec.store(front.pts);
        player->video_queue.pop();
        player->video_frame_cv.notify_one();

        CVPixelBufferRetain(player->last_frame);
        if (out_pts) *out_pts = player->last_pts;
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
        return player->last_frame;
    }
    return nullptr;
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

    double video_q_sec = 0.0;
    {
        std::lock_guard<std::mutex> lock(player->video_queue_mtx);
        if (player->video_queue.size() > 1) {
            video_q_sec = player->video_queue.back().pts - player->video_queue.front().pts;
            if (video_q_sec < 0.0) video_q_sec = 0.0;
        }
    }

    size_t bytes = dk_rs_cache_get_bytes(player->rs_cache);
    double bitrate_bps = 25.0 * 1024.0 * 1024.0;
    if (player->stats.video_bitrate_mbps > 0.1) {
        bitrate_bps = player->stats.video_bitrate_mbps * 1000000.0;
    }
    double cache_sec = static_cast<double>(bytes) / (bitrate_bps / 8.0);
    return std::max(video_q_sec, cache_sec);
}

void dk_player_get_stats(DKPlayer* player, DKRuntimeStats* out_stats) {
    DKReaderGuard guard(player);
    if (guard && out_stats) {
        std::lock_guard<std::mutex> lock(player->stats_mtx);
        *out_stats = player->stats;
        out_stats->cached_bytes = dk_rs_cache_get_bytes(player->rs_cache);
    }
}
