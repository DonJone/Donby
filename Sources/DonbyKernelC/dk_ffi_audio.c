#include "dk_ffi_shim_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>

#include <AudioToolbox/AudioToolbox.h>

// -----------------------------------------------------------------------------
// Audio Decoder, SwrContext Resampler, VAD Mono Tap & AudioQueue
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
