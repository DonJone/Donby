use crate::abi::{
    DKCustomIOAbortCallback, DKCustomIOCloseCallback, DKCustomIOReadCallback,
    DKCustomIOSeekCallback, DKGpuColorUniforms, DKPlayerState, DKRuntimeStats,
};
use crate::clock::{load_f64, store_f64, ClockState, SpeedTracker};
use crate::ffi::{dk_shim_avio_bytes_read, AvPacket, OwnedPixelBuffer};
use crate::subtitle::SubtitleEngine;
use crate::vad::VadAudioRing;
use std::collections::VecDeque;
use std::ffi::c_void;
use std::ptr;
use std::sync::atomic::{
    AtomicBool, AtomicI32, AtomicI64, AtomicPtr, AtomicU32, AtomicU64, AtomicU8, Ordering,
};
use std::sync::{Condvar, Mutex};
use std::thread::JoinHandle;

pub(crate) struct VideoFrameEntry {
    pub(crate) pixbuf: OwnedPixelBuffer,
    pub(crate) pts: f64,
    pub(crate) color: DKGpuColorUniforms,
}

pub(crate) struct AudioChunk {
    pub(crate) pcm: Vec<f32>,
    pub(crate) pts: f64,
    pub(crate) read_offset: usize,
}

#[derive(Copy, Clone, Default)]
pub(crate) struct CustomIoSlot {
    pub(crate) opaque: usize,
    pub(crate) read_cb: DKCustomIOReadCallback,
    pub(crate) seek_cb: DKCustomIOSeekCallback,
    pub(crate) abort_cb: DKCustomIOAbortCallback,
    pub(crate) close_cb: DKCustomIOCloseCallback,
}

pub(crate) struct VideoQueueState {
    pub(crate) frames: VecDeque<VideoFrameEntry>,
    pub(crate) last_frame: Option<OwnedPixelBuffer>,
    pub(crate) last_pts: f64,
    pub(crate) last_color: DKGpuColorUniforms,
    pub(crate) last_decoded_pts: f64,
}

impl Default for VideoQueueState {
    fn default() -> Self {
        Self {
            frames: VecDeque::new(),
            last_frame: None,
            last_pts: 0.0,
            last_color: DKGpuColorUniforms::default_sdr(),
            last_decoded_pts: -1.0,
        }
    }
}

pub(crate) struct SwVideoState {
    pub(crate) sws: usize,
    pub(crate) pool: usize,
    pub(crate) pool_w: i32,
    pub(crate) pool_h: i32,
    pub(crate) pool_fmt: u32,
}

impl Default for SwVideoState {
    fn default() -> Self {
        Self {
            sws: 0,
            pool: 0,
            pool_w: 0,
            pool_h: 0,
            pool_fmt: 0,
        }
    }
}

pub(crate) struct AudioCodecState {
    pub(crate) codec_ctx: usize,
    pub(crate) swr_ctx: usize,
    pub(crate) swr_fmt: i32,
    pub(crate) swr_rate: i32,
    pub(crate) swr_ch: i32,
}

impl Default for AudioCodecState {
    fn default() -> Self {
        Self {
            codec_ctx: 0,
            swr_ctx: 0,
            swr_fmt: -1,
            swr_rate: 0,
            swr_ch: 0,
        }
    }
}

pub(crate) struct SubHistoryState {
    pub(crate) pkts: VecDeque<AvPacket>,
    pub(crate) bytes: usize,
}

impl Default for SubHistoryState {
    fn default() -> Self {
        Self {
            pkts: VecDeque::new(),
            bytes: 0,
        }
    }
}

pub(crate) struct WorkerHandles {
    pub(crate) demux: Option<JoinHandle<()>>,
    pub(crate) video: Option<JoinHandle<()>>,
    pub(crate) audio: Option<JoinHandle<()>>,
}

impl Default for WorkerHandles {
    fn default() -> Self {
        Self {
            demux: None,
            video: None,
            audio: None,
        }
    }
}

pub(crate) struct AudioStartingGuard<'a>(pub(crate) &'a AtomicBool);
impl Drop for AudioStartingGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

pub(crate) struct SeekScopeGuard<'a>(pub(crate) &'a AtomicBool);
impl Drop for SeekScopeGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

#[repr(C)]
pub struct DKPlayer {
    pub(crate) state: AtomicI32,
    pub(crate) is_closing: AtomicBool,
    pub(crate) in_flight_readers: AtomicI32,
    pub(crate) abort_requested: AtomicBool,
    pub(crate) external_abort_requested: AtomicBool,

    pub(crate) duration_bits: AtomicU64,
    pub(crate) rate_bits: AtomicU32,
    pub(crate) volume_bits: AtomicU32,
    pub(crate) is_muted: AtomicBool,
    pub(crate) hw_decode_enabled: AtomicBool,

    pub(crate) format_ctx: AtomicPtr<c_void>,
    pub(crate) custom_avio_ctx: AtomicPtr<c_void>,
    pub(crate) hw_fmt_ctx_opaque: AtomicPtr<c_void>,
    /// Lock partial order: `LIVE_PLAYERS` -> `custom_io`. Never acquire `LIVE_PLAYERS` while holding `custom_io`.
    pub(crate) custom_io: Mutex<CustomIoSlot>,

    pub(crate) video_stream_idx: AtomicI32,
    pub(crate) audio_stream_idx: AtomicI32,
    pub(crate) sub_stream_idx: AtomicI32,
    pub(crate) secondary_sub_stream_idx: AtomicI32,

    /// Lock partial order: `video_codec_mtx` -> `stats_mtx`.
    pub(crate) video_codec_mtx: Mutex<(usize, usize)>, // (video_codec_ctx, hw_device_ctx)
    pub(crate) sw_video_mtx: Mutex<SwVideoState>,
    /// Lock partial order: `audio_codec_mtx` -> `{vad_mtx, audio_chunks_mtx, video_queue_mtx, audio_buffers, audio_pkt_mtx, stats_mtx, workers_mtx}`.
    pub(crate) audio_codec_mtx: Mutex<AudioCodecState>,

    pub(crate) vt_failed: AtomicBool,
    pub(crate) dovi_detected: AtomicBool,
    pub(crate) stream_dovi_profile: AtomicU8,

    pub(crate) seek_requested: AtomicBool,
    pub(crate) latest_seek_seq: AtomicU64,
    pub(crate) executing_seek_seq: AtomicU64,
    pub(crate) seek_executing: AtomicBool,
    pub(crate) seek_target_bits: AtomicU64,
    pub(crate) seek_accurate: AtomicBool,
    pub(crate) video_seek_drop_bits: AtomicU64,
    pub(crate) audio_seek_drop_bits: AtomicU64,
    pub(crate) seek_preview_pending: AtomicBool,
    pub(crate) force_present_next_frame: AtomicBool,
    pub(crate) demux_eof: AtomicBool,
    pub(crate) video_eof: AtomicBool,
    pub(crate) audio_eof: AtomicBool,

    /// Lock partial order: `demux_mtx` -> `{video_pkt_mtx, audio_pkt_mtx, video_codec_mtx, audio_codec_mtx, sub_mtx, sub_hist_mtx, video_queue_mtx, audio_chunks_mtx, vad_mtx, speed_mtx}`.
    pub(crate) demux_mtx: Mutex<()>,
    pub(crate) demux_cv: Condvar,

    pub(crate) video_pkt_mtx: Mutex<VecDeque<Option<AvPacket>>>,
    pub(crate) video_decode_cv: Condvar,

    pub(crate) audio_pkt_mtx: Mutex<VecDeque<Option<AvPacket>>>,
    pub(crate) audio_decode_cv: Condvar,

    pub(crate) queued_pkt_bytes: AtomicI64,
    pub(crate) max_buffer_bytes: AtomicI64,
    pub(crate) last_demuxed_pts_bits: AtomicU64,

    pub(crate) video_queue_mtx: Mutex<VideoQueueState>,
    pub(crate) video_frame_cv: Condvar,

    pub(crate) audio_queue_ptr: AtomicPtr<c_void>,
    pub(crate) audio_trampoline_ptr: AtomicPtr<c_void>,
    pub(crate) audio_buffers: Mutex<[*mut c_void; 4]>,
    pub(crate) audio_chunks_mtx: Mutex<VecDeque<AudioChunk>>,
    pub(crate) buffered_audio_samples: AtomicI64,
    pub(crate) audio_queue_started: AtomicBool,
    pub(crate) audio_queue_starting: AtomicBool,
    pub(crate) audio_rebuffer_count: AtomicU32,
    pub(crate) audio_start_fail_count: AtomicU32,
    pub(crate) last_audio_start_attempt_ns: AtomicI64,
    pub(crate) audio_steady_start_ns: AtomicI64,
    pub(crate) audio_hal_disabled: AtomicBool,

    pub(crate) clock: ClockState,
    pub(crate) vad_mtx: Mutex<VadAudioRing>,

    pub(crate) sub_hist_mtx: Mutex<SubHistoryState>,
    pub(crate) sub_hist_trimmed: AtomicBool,
    pub(crate) sub_mtx: Mutex<SubtitleEngine>,

    pub(crate) workers_mtx: Mutex<WorkerHandles>,

    pub(crate) stats_mtx: Mutex<DKRuntimeStats>,
    pub(crate) atomic_video_bitrate_bits: AtomicU64,
    pub(crate) total_bytes_read: AtomicI64,
    pub(crate) speed_mtx: Mutex<SpeedTracker>,
}

unsafe impl Send for DKPlayer {}
unsafe impl Sync for DKPlayer {}

impl DKPlayer {
    pub(crate) fn new() -> Self {
        Self {
            state: AtomicI32::new(DKPlayerState::Idle as i32),
            is_closing: AtomicBool::new(false),
            in_flight_readers: AtomicI32::new(0),
            abort_requested: AtomicBool::new(false),
            external_abort_requested: AtomicBool::new(false),
            duration_bits: AtomicU64::new(0.0f64.to_bits()),
            rate_bits: AtomicU32::new(1.0f32.to_bits()),
            volume_bits: AtomicU32::new(1.0f32.to_bits()),
            is_muted: AtomicBool::new(false),
            hw_decode_enabled: AtomicBool::new(true),
            format_ctx: AtomicPtr::new(ptr::null_mut()),
            custom_avio_ctx: AtomicPtr::new(ptr::null_mut()),
            hw_fmt_ctx_opaque: AtomicPtr::new(ptr::null_mut()),
            custom_io: Mutex::new(CustomIoSlot::default()),
            video_stream_idx: AtomicI32::new(-1),
            audio_stream_idx: AtomicI32::new(-1),
            sub_stream_idx: AtomicI32::new(-1),
            secondary_sub_stream_idx: AtomicI32::new(-1),
            video_codec_mtx: Mutex::new((0, 0)),
            sw_video_mtx: Mutex::new(SwVideoState::default()),
            audio_codec_mtx: Mutex::new(AudioCodecState::default()),
            vt_failed: AtomicBool::new(false),
            dovi_detected: AtomicBool::new(false),
            stream_dovi_profile: AtomicU8::new(0),
            seek_requested: AtomicBool::new(false),
            latest_seek_seq: AtomicU64::new(0),
            executing_seek_seq: AtomicU64::new(0),
            seek_executing: AtomicBool::new(false),
            seek_target_bits: AtomicU64::new(0.0f64.to_bits()),
            seek_accurate: AtomicBool::new(false),
            video_seek_drop_bits: AtomicU64::new((-1.0f64).to_bits()),
            audio_seek_drop_bits: AtomicU64::new((-1.0f64).to_bits()),
            seek_preview_pending: AtomicBool::new(false),
            force_present_next_frame: AtomicBool::new(false),
            demux_eof: AtomicBool::new(false),
            video_eof: AtomicBool::new(false),
            audio_eof: AtomicBool::new(false),
            demux_mtx: Mutex::new(()),
            demux_cv: Condvar::new(),
            video_pkt_mtx: Mutex::new(VecDeque::new()),
            video_decode_cv: Condvar::new(),
            audio_pkt_mtx: Mutex::new(VecDeque::new()),
            audio_decode_cv: Condvar::new(),
            queued_pkt_bytes: AtomicI64::new(0),
            max_buffer_bytes: AtomicI64::new(256 * 1024 * 1024),
            last_demuxed_pts_bits: AtomicU64::new(0.0f64.to_bits()),
            video_queue_mtx: Mutex::new(VideoQueueState::default()),
            video_frame_cv: Condvar::new(),
            audio_queue_ptr: AtomicPtr::new(ptr::null_mut()),
            audio_trampoline_ptr: AtomicPtr::new(ptr::null_mut()),
            audio_buffers: Mutex::new([ptr::null_mut(); 4]),
            audio_chunks_mtx: Mutex::new(VecDeque::new()),
            buffered_audio_samples: AtomicI64::new(0),
            audio_queue_started: AtomicBool::new(false),
            audio_queue_starting: AtomicBool::new(false),
            audio_rebuffer_count: AtomicU32::new(0),
            audio_start_fail_count: AtomicU32::new(0),
            last_audio_start_attempt_ns: AtomicI64::new(0),
            audio_steady_start_ns: AtomicI64::new(0),
            audio_hal_disabled: AtomicBool::new(false),
            clock: ClockState::default(),
            vad_mtx: Mutex::new(VadAudioRing::default()),
            sub_hist_mtx: Mutex::new(SubHistoryState::default()),
            sub_hist_trimmed: AtomicBool::new(false),
            sub_mtx: Mutex::new(SubtitleEngine::new()),
            workers_mtx: Mutex::new(WorkerHandles::default()),
            stats_mtx: Mutex::new(DKRuntimeStats::default()),
            atomic_video_bitrate_bits: AtomicU64::new(0.0f64.to_bits()),
            total_bytes_read: AtomicI64::new(0),
            speed_mtx: Mutex::new(SpeedTracker::default()),
        }
    }

    #[inline]
    pub(crate) fn get_state(&self) -> DKPlayerState {
        match self.state.load(Ordering::Acquire) {
            1 => DKPlayerState::Opening,
            2 => DKPlayerState::Buffering,
            3 => DKPlayerState::Playing,
            4 => DKPlayerState::Paused,
            5 => DKPlayerState::Ended,
            6 => DKPlayerState::Error,
            _ => DKPlayerState::Idle,
        }
    }

    #[inline]
    pub(crate) fn rate(&self) -> f32 {
        f32::from_bits(self.rate_bits.load(Ordering::Acquire))
    }

    #[inline]
    pub(crate) fn volume(&self) -> f32 {
        f32::from_bits(self.volume_bits.load(Ordering::Acquire))
    }

    #[inline]
    pub(crate) fn is_seeking(&self) -> bool {
        self.seek_requested.load(Ordering::Acquire) || self.seek_executing.load(Ordering::Acquire)
    }

    #[inline]
    pub(crate) fn should_yield_read(&self) -> bool {
        if self.abort_requested.load(Ordering::Acquire) || self.is_closing.load(Ordering::Acquire) {
            return true;
        }
        if !self.seek_requested.load(Ordering::Acquire) {
            return false;
        }
        !self.seek_executing.load(Ordering::Acquire)
            || self.latest_seek_seq.load(Ordering::Acquire) != self.executing_seek_seq.load(Ordering::Acquire)
    }

    pub(crate) fn effective_volume(&self) -> f32 {
        let env_muted = std::env::var("DONBY_TEST_MUTED")
            .ok()
            .and_then(|v| v.bytes().next())
            .is_some_and(|b| matches!(b, b'1' | b't' | b'T'));
        if self.is_muted.load(Ordering::Acquire) || env_muted {
            0.0
        } else {
            self.volume()
        }
    }

    pub(crate) fn signal_seek_request(&self, target_sec: f64, accurate: bool) {
        store_f64(&self.seek_target_bits, target_sec.max(0.0));
        self.seek_accurate.store(accurate, Ordering::Release);
        self.latest_seek_seq.fetch_add(1, Ordering::AcqRel);
        self.seek_requested.store(true, Ordering::Release);
        self.demux_cv.notify_all();
    }

    pub(crate) fn get_total_bytes_read(&self) -> i64 {
        let mut cur = self.total_bytes_read.load(Ordering::Relaxed);
        let fmt = self.format_ctx.load(Ordering::Acquire);
        if !fmt.is_null() {
            let pb = unsafe { dk_shim_avio_bytes_read(fmt) };
            if pb > cur {
                cur = pb;
                self.total_bytes_read.store(cur, Ordering::Relaxed);
            }
        }
        cur
    }

    pub(crate) fn set_buffer_limit_mb(&self, limit_mb: i32) {
        let clamped = (limit_mb.clamp(32, 2048) as i64) * 1024 * 1024;
        self.max_buffer_bytes.store(clamped, Ordering::Relaxed);
        self.demux_cv.notify_one();
    }

    pub(crate) fn get_buffered_duration(&self) -> f64 {
        let cur_pts = self.get_master_clock().max(0.0);
        let dur = load_f64(&self.duration_bits);
        if self.demux_eof.load(Ordering::Relaxed) && dur > cur_pts {
            return dur - cur_pts;
        }
        let video_q_sec = self
            .video_queue_mtx
            .lock()
            .ok()
            .and_then(|vq| vq.frames.back().map(|f| (f.pts - cur_pts).max(0.0)))
            .unwrap_or(0.0);
        let demux_ahead_sec = (load_f64(&self.last_demuxed_pts_bits) - cur_pts).max(0.0);
        let queued_bytes = self.queued_pkt_bytes.load(Ordering::Relaxed).max(0) as f64;
        let measured_mbps = load_f64(&self.atomic_video_bitrate_bits);
        let bitrate_bps = if measured_mbps > 0.1 {
            measured_mbps * 1_000_000.0
        } else {
            25.0 * 1024.0 * 1024.0
        };
        let pkt_bytes_sec = queued_bytes / (bitrate_bps / 8.0);
        let mut ahead = demux_ahead_sec.max(video_q_sec).max(pkt_bytes_sec);
        if dur > cur_pts {
            ahead = ahead.min(dur - cur_pts);
        }
        ahead.max(0.0)
    }

    pub(crate) fn get_stats(&self, out_stats: &mut DKRuntimeStats) {
        let total_bytes = self.get_total_bytes_read();
        let speed_mbs = self.speed_mtx.lock().map(|mut sp| sp.sample(total_bytes)).unwrap_or(0.0);
        let cached = self.queued_pkt_bytes.load(Ordering::Relaxed).max(0);
        if let Ok(st) = self.stats_mtx.lock() {
            *out_stats = *st;
            out_stats.cached_bytes = cached;
            out_stats.total_bytes_read = total_bytes;
            out_stats.download_speed_mbs = speed_mbs;
        }
    }
}
