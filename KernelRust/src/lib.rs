pub mod abi;
pub mod clock;
pub mod dovi;
pub mod ffi;
pub mod subtitle;
pub mod vad;

use abi::*;
use clock::{elapsed_since_ns, load_f64, steady_now_ns, store_f64, ClockState, SpeedTracker};
use dovi::check_dovi_rpu_or_el;
use ffi::*;
use std::collections::VecDeque;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicPtr, AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::Duration;
use subtitle::SubtitleEngine;
use vad::VadAudioRing;

static LOG_CALLBACK: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
static LIVE_PLAYERS: OnceLock<Mutex<Vec<usize>>> = OnceLock::new();

fn live_players() -> &'static Mutex<Vec<usize>> {
    LIVE_PLAYERS.get_or_init(|| Mutex::new(Vec::new()))
}

pub(crate) fn emit_log(level: c_int, msg: &str) {
    let raw = LOG_CALLBACK.load(Ordering::Acquire);
    if raw.is_null() {
        return;
    }
    if let Ok(cstr) = CString::new(msg) {
        let cb: unsafe extern "C" fn(c_int, *const c_char) = unsafe { std::mem::transmute(raw) };
        unsafe { cb(level, cstr.as_ptr()) };
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_rust_forward_ffmpeg_log(level: c_int, message: *const c_char) {
    let raw = LOG_CALLBACK.load(Ordering::Acquire);
    if raw.is_null() || message.is_null() {
        return;
    }
    let cb: unsafe extern "C" fn(c_int, *const c_char) = std::mem::transmute(raw);
    cb(level, message);
}

struct VideoFrameEntry {
    pixbuf: OwnedPixelBuffer,
    pts: f64,
    color: DKGpuColorUniforms,
}

struct AudioChunk {
    pcm: Vec<f32>,
    pts: f64,
    read_offset: usize,
}

#[derive(Copy, Clone, Default)]
struct CustomIoSlot {
    opaque: usize,
    read_cb: DKCustomIOReadCallback,
    seek_cb: DKCustomIOSeekCallback,
    abort_cb: DKCustomIOAbortCallback,
    close_cb: DKCustomIOCloseCallback,
}

struct VideoQueueState {
    frames: VecDeque<VideoFrameEntry>,
    last_frame: Option<OwnedPixelBuffer>,
    last_pts: f64,
    last_color: DKGpuColorUniforms,
    last_decoded_pts: f64,
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

struct SwVideoState {
    sws: usize,
    pool: usize,
    pool_w: i32,
    pool_h: i32,
    pool_fmt: u32,
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

struct AudioCodecState {
    codec_ctx: usize,
    swr_ctx: usize,
    swr_fmt: i32,
    swr_rate: i32,
    swr_ch: i32,
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

struct SubHistoryState {
    pkts: VecDeque<AvPacket>,
    bytes: usize,
}

impl Default for SubHistoryState {
    fn default() -> Self {
        Self {
            pkts: VecDeque::new(),
            bytes: 0,
        }
    }
}

struct WorkerHandles {
    demux: Option<JoinHandle<()>>,
    video: Option<JoinHandle<()>>,
    audio: Option<JoinHandle<()>>,
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

struct ReaderGuard<'a> {
    player: Option<&'a DKPlayer>,
}

impl<'a> ReaderGuard<'a> {
    unsafe fn acquire(raw: *mut DKPlayer) -> Self {
        if raw.is_null() {
            return Self { player: None };
        }
        let Ok(reg) = live_players().lock() else {
            return Self { player: None };
        };
        if !reg.contains(&(raw as usize)) {
            return Self { player: None };
        }
        let p = &*raw;
        if p.is_closing.load(Ordering::Acquire) || p.abort_requested.load(Ordering::Acquire) {
            return Self { player: None };
        }
        p.in_flight_readers.fetch_add(1, Ordering::AcqRel);
        Self { player: Some(p) }
    }
}

impl Drop for ReaderGuard<'_> {
    fn drop(&mut self) {
        if let Some(p) = self.player {
            p.in_flight_readers.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

struct AudioStartingGuard<'a>(&'a AtomicBool);
impl Drop for AudioStartingGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

struct SeekScopeGuard<'a>(&'a AtomicBool);
impl Drop for SeekScopeGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

#[repr(C)]
pub struct DKPlayer {
    state: AtomicI32,
    is_closing: AtomicBool,
    in_flight_readers: AtomicI32,
    abort_requested: AtomicBool,
    external_abort_requested: AtomicBool,

    duration_bits: AtomicU64,
    rate_bits: AtomicU32,
    volume_bits: AtomicU32,
    is_muted: AtomicBool,
    hw_decode_enabled: AtomicBool,

    format_ctx: AtomicPtr<c_void>,
    custom_avio_ctx: AtomicPtr<c_void>,
    hw_fmt_ctx_opaque: AtomicPtr<c_void>,
    custom_io: Mutex<CustomIoSlot>,

    video_stream_idx: AtomicI32,
    audio_stream_idx: AtomicI32,
    sub_stream_idx: AtomicI32,
    secondary_sub_stream_idx: AtomicI32,

    video_codec_mtx: Mutex<(usize, usize)>, // (video_codec_ctx, hw_device_ctx)
    sw_video_mtx: Mutex<SwVideoState>,
    audio_codec_mtx: Mutex<AudioCodecState>,

    vt_failed: AtomicBool,
    dovi_detected: AtomicBool,
    stream_dovi_profile: AtomicU8,

    seek_requested: AtomicBool,
    latest_seek_seq: AtomicU64,
    executing_seek_seq: AtomicU64,
    seek_executing: AtomicBool,
    seek_target_bits: AtomicU64,
    seek_accurate: AtomicBool,
    video_seek_drop_bits: AtomicU64,
    audio_seek_drop_bits: AtomicU64,
    seek_preview_pending: AtomicBool,
    force_present_next_frame: AtomicBool,
    demux_eof: AtomicBool,
    video_eof: AtomicBool,
    audio_eof: AtomicBool,

    demux_mtx: Mutex<()>,
    demux_cv: Condvar,

    video_pkt_mtx: Mutex<VecDeque<Option<AvPacket>>>,
    video_decode_cv: Condvar,

    audio_pkt_mtx: Mutex<VecDeque<Option<AvPacket>>>,
    audio_decode_cv: Condvar,

    queued_pkt_bytes: AtomicI64,
    max_buffer_bytes: AtomicI64,
    last_demuxed_pts_bits: AtomicU64,

    video_queue_mtx: Mutex<VideoQueueState>,
    video_frame_cv: Condvar,

    audio_queue_ptr: AtomicPtr<c_void>,
    audio_trampoline_ptr: AtomicPtr<c_void>,
    audio_buffers: Mutex<[*mut c_void; 4]>,
    audio_chunks_mtx: Mutex<VecDeque<AudioChunk>>,
    buffered_audio_samples: AtomicI64,
    audio_queue_started: AtomicBool,
    audio_queue_starting: AtomicBool,
    audio_rebuffer_count: AtomicU32,
    audio_start_fail_count: AtomicU32,
    last_audio_start_attempt_ns: AtomicI64,
    audio_steady_start_ns: AtomicI64,
    audio_hal_disabled: AtomicBool,

    clock: ClockState,
    vad_mtx: Mutex<VadAudioRing>,

    sub_hist_mtx: Mutex<SubHistoryState>,
    sub_hist_trimmed: AtomicBool,
    sub_mtx: Mutex<SubtitleEngine>,

    workers_mtx: Mutex<WorkerHandles>,

    stats_mtx: Mutex<DKRuntimeStats>,
    atomic_video_bitrate_bits: AtomicU64,
    total_bytes_read: AtomicI64,
    speed_mtx: Mutex<SpeedTracker>,
}

unsafe impl Send for DKPlayer {}
unsafe impl Sync for DKPlayer {}

impl DKPlayer {
    fn new() -> Self {
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
    fn get_state(&self) -> DKPlayerState {
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
    fn rate(&self) -> f32 {
        f32::from_bits(self.rate_bits.load(Ordering::Acquire))
    }

    #[inline]
    fn volume(&self) -> f32 {
        f32::from_bits(self.volume_bits.load(Ordering::Acquire))
    }

    #[inline]
    fn is_seeking(&self) -> bool {
        self.seek_requested.load(Ordering::Acquire) || self.seek_executing.load(Ordering::Acquire)
    }

    #[inline]
    fn should_yield_read(&self) -> bool {
        if self.abort_requested.load(Ordering::Acquire) || self.is_closing.load(Ordering::Acquire) {
            return true;
        }
        if !self.seek_requested.load(Ordering::Acquire) {
            return false;
        }
        !self.seek_executing.load(Ordering::Acquire)
            || self.latest_seek_seq.load(Ordering::Acquire) != self.executing_seek_seq.load(Ordering::Acquire)
    }

    fn effective_volume(&self) -> f32 {
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

    fn get_audio_clock(&self) -> f64 {
        let aq = self.audio_queue_ptr.load(Ordering::Acquire);
        if self.abort_requested.load(Ordering::Acquire) || self.is_closing.load(Ordering::Acquire) || aq.is_null() {
            return load_f64(&self.clock.current_pos_bits);
        }
        if !self.audio_queue_started.load(Ordering::Acquire) {
            let base = load_f64(&self.clock.audio_clock_base_pts_bits);
            return if base >= 0.0 { base } else { load_f64(&self.clock.current_pos_bits) };
        }
        let mut hw_sample_time = 0i64;
        if unsafe { dk_shim_aq_get_sample_time(aq, &mut hw_sample_time) } {
            if !self.clock.audio_clock_calibrated.load(Ordering::Acquire) {
                self.clock.audio_clock_base_sample_time.store(hw_sample_time, Ordering::Release);
                self.clock.audio_underrun_samples.store(0, Ordering::Release);
                self.clock.audio_clock_calibrated.store(true, Ordering::Release);
                emit_log(
                    0,
                    &format!(
                        "DKEngine: Master audio clock calibrated at hardware sample {} (base PTS: {:.3}s)",
                        hw_sample_time,
                        load_f64(&self.clock.audio_clock_base_pts_bits)
                    ),
                );
            }
            let mut sample_diff = hw_sample_time - self.clock.audio_clock_base_sample_time.load(Ordering::Acquire);
            sample_diff -= self.clock.audio_underrun_samples.load(Ordering::Relaxed);
            if sample_diff < 0 {
                sample_diff = 0;
            }
            let clk = load_f64(&self.clock.audio_clock_base_pts_bits) + (sample_diff as f64) / 48_000.0;
            store_f64(&self.clock.fallback_audio_clock_bits, clk);
            self.clock.fallback_clock_ns.store(steady_now_ns(), Ordering::Relaxed);
            return clk;
        }
        if self.get_state() == DKPlayerState::Playing && self.clock.audio_clock_calibrated.load(Ordering::Acquire) {
            let elapsed = elapsed_since_ns(self.clock.fallback_clock_ns.load(Ordering::Relaxed)) * (self.rate() as f64);
            return load_f64(&self.clock.fallback_audio_clock_bits) + elapsed;
        }
        let base_pts = load_f64(&self.clock.audio_clock_base_pts_bits);
        if base_pts >= 0.0 {
            base_pts
        } else {
            load_f64(&self.clock.fallback_audio_clock_bits)
        }
    }

    fn get_master_clock(&self) -> f64 {
        if self.abort_requested.load(Ordering::Acquire) || self.is_closing.load(Ordering::Acquire) {
            return 0.0;
        }
        if self.is_seeking() {
            return load_f64(&self.seek_target_bits);
        }
        if self.audio_stream_idx.load(Ordering::Acquire) >= 0
            && !self.audio_queue_ptr.load(Ordering::Acquire).is_null()
            && !self.audio_hal_disabled.load(Ordering::Acquire)
        {
            return self.get_audio_clock();
        }
        if self.get_state() == DKPlayerState::Playing {
            let elapsed = elapsed_since_ns(self.clock.ext_clock_start_ns.load(Ordering::Relaxed)) * (self.rate() as f64);
            return load_f64(&self.clock.ext_clock_base_pts_bits) + elapsed;
        }
        load_f64(&self.clock.ext_clock_base_pts_bits)
    }

    fn fill_audio_buffer(&self, dst: &mut [f32]) {
        let needed_floats = dst.len();
        let mut filled = 0usize;
        if let Ok(mut chunks) = self.audio_chunks_mtx.lock() {
            while filled < needed_floats {
                let Some(front) = chunks.front_mut() else { break };
                let avail = front.pcm.len().saturating_sub(front.read_offset);
                let to_copy = (needed_floats - filled).min(avail);
                dst[filled..filled + to_copy]
                    .copy_from_slice(&front.pcm[front.read_offset..front.read_offset + to_copy]);
                filled += to_copy;
                front.read_offset += to_copy;
                if front.read_offset >= front.pcm.len() {
                    let samples = (front.pcm.len() / 2) as i64;
                    self.buffered_audio_samples.fetch_sub(samples, Ordering::Relaxed);
                    chunks.pop_front();
                }
            }
        }
        if filled < needed_floats {
            dst[filled..].fill(0.0);
            if self.clock.audio_clock_calibrated.load(Ordering::Relaxed) && !self.audio_eof.load(Ordering::Relaxed) {
                let silence_samples = ((needed_floats - filled) / 2) as i64;
                self.clock.audio_underrun_samples.fetch_add(silence_samples, Ordering::Relaxed);
                self.clock
                    .audio_consecutive_underrun_samples
                    .fetch_add(silence_samples, Ordering::Relaxed);
            }
        } else {
            self.clock.audio_consecutive_underrun_samples.store(0, Ordering::Relaxed);
        }
    }

    fn init_audio_queue(&self) -> bool {
        let mut aq: *mut c_void = ptr::null_mut();
        let mut tr: *mut c_void = ptr::null_mut();
        let mut bufs = [ptr::null_mut(); 4];
        let ok = unsafe {
            dk_shim_aq_create(
                aq_callback_trampoline,
                self as *const Self as *mut c_void,
                self.rate(),
                self.effective_volume(),
                &mut aq,
                &mut tr,
                bufs.as_mut_ptr(),
            )
        };
        if !ok || aq.is_null() {
            return false;
        }
        self.audio_queue_ptr.store(aq, Ordering::Release);
        self.audio_trampoline_ptr.store(tr, Ordering::Release);
        if let Ok(mut guard) = self.audio_buffers.lock() {
            *guard = bufs;
        }
        true
    }

    fn required_audio_preroll_samples(&self) -> i64 {
        match self.audio_rebuffer_count.load(Ordering::Relaxed) {
            0 => 24_000,
            1 => 84_000,
            _ => 120_000,
        }
    }

    fn try_start_audio_queue_if_ready(&self) {
        if self.abort_requested.load(Ordering::Acquire)
            || self.is_closing.load(Ordering::Acquire)
            || self.audio_queue_ptr.load(Ordering::Acquire).is_null()
            || self.audio_hal_disabled.load(Ordering::Acquire)
            || self.audio_queue_started.load(Ordering::Acquire)
            || self.is_seeking()
        {
            return;
        }
        let buffered = self.buffered_audio_samples.load(Ordering::Relaxed);
        let eof_reached = self.audio_eof.load(Ordering::Relaxed) || self.demux_eof.load(Ordering::Relaxed);
        let rebuf = self.audio_rebuffer_count.load(Ordering::Relaxed);
        if buffered < self.required_audio_preroll_samples() && !eof_reached {
            return;
        }
        let solo_samples = match rebuf {
            0 => 36_000,
            1 => 96_000,
            _ => 144_000,
        };
        let mut video_ready = self.video_stream_idx.load(Ordering::Relaxed) < 0
            || self.video_eof.load(Ordering::Relaxed)
            || eof_reached
            || buffered >= solo_samples;
        if !video_ready {
            if let Ok(vq) = self.video_queue_mtx.lock() {
                let min_frames = if rebuf >= 2 {
                    8
                } else if rebuf == 1 {
                    6
                } else if self.force_present_next_frame.load(Ordering::Relaxed) {
                    4
                } else {
                    3
                };
                video_ready = vq.frames.len() >= min_frames
                    || self.video_eof.load(Ordering::Relaxed)
                    || self.demux_eof.load(Ordering::Relaxed);
            }
        }
        if video_ready {
            self.start_audio_queue_with_buffered_data();
        }
    }

    fn start_audio_queue_with_buffered_data(&self) {
        let aq = self.audio_queue_ptr.load(Ordering::Acquire);
        if self.abort_requested.load(Ordering::Acquire)
            || self.is_closing.load(Ordering::Acquire)
            || aq.is_null()
            || self.audio_hal_disabled.load(Ordering::Acquire)
            || self.audio_queue_started.load(Ordering::Acquire)
            || self.is_seeking()
        {
            return;
        }
        if self
            .audio_queue_starting
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }
        let _guard = AudioStartingGuard(&self.audio_queue_starting);

        let now_ns = steady_now_ns();
        let prev_ns = self.last_audio_start_attempt_ns.load(Ordering::Relaxed);
        if self.audio_start_fail_count.load(Ordering::Relaxed) > 0 && prev_ns > 0 && (now_ns - prev_ns) < 80_000_000 {
            return;
        }
        self.last_audio_start_attempt_ns.store(now_ns, Ordering::Relaxed);

        let first_v_pts = self
            .video_queue_mtx
            .lock()
            .ok()
            .and_then(|vq| vq.frames.front().map(|f| f.pts))
            .unwrap_or(-1.0);

        let base_pts = {
            let Ok(mut chunks) = self.audio_chunks_mtx.lock() else { return };
            if self.audio_queue_started.load(Ordering::Acquire) || chunks.is_empty() {
                return;
            }
            if first_v_pts >= 0.0 && chunks[0].pts < first_v_pts - 0.04 {
                let mut cur_samples = self.buffered_audio_samples.load(Ordering::Relaxed);
                while chunks.len() > 1 && cur_samples > 12_000 {
                    let chunk_samples = ((chunks[0].pcm.len() - chunks[0].read_offset) / 2) as i64;
                    let chunk_end = chunks[0].pts + (chunk_samples as f64) / 48_000.0;
                    if chunk_end >= first_v_pts - 0.015 || (cur_samples - chunk_samples) < 8_000 {
                        break;
                    }
                    self.buffered_audio_samples.fetch_sub(chunk_samples, Ordering::Relaxed);
                    cur_samples -= chunk_samples;
                    chunks.pop_front();
                }
            }
            let bp = chunks[0].pts;
            store_f64(&self.clock.audio_clock_base_pts_bits, bp);
            store_f64(&self.clock.fallback_audio_clock_bits, bp);
            self.clock.fallback_clock_ns.store(steady_now_ns(), Ordering::Relaxed);
            self.clock.audio_clock_calibrated.store(false, Ordering::Release);
            self.clock.audio_clock_base_sample_time.store(0, Ordering::Release);
            self.clock.audio_underrun_samples.store(0, Ordering::Release);
            self.clock.audio_consecutive_underrun_samples.store(0, Ordering::Release);
            bp
        };

        if base_pts >= 0.0 {
            if let Ok(mut vq) = self.video_queue_mtx.lock() {
                while vq.frames.len() > 1 && vq.frames[0].pts < base_pts - 0.03 {
                    vq.frames.pop_front();
                    self.video_frame_cv.notify_one();
                }
            }
        }

        let bufs = self.audio_buffers.lock().map(|g| *g).unwrap_or([ptr::null_mut(); 4]);
        for b in bufs {
            if !b.is_null() {
                unsafe {
                    dk_shim_aq_fill_and_enqueue(aq, b, aq_fill_only_trampoline, self as *const Self as *mut c_void);
                }
            }
        }

        if self.get_state() == DKPlayerState::Playing && !self.is_seeking() {
            let status = unsafe { dk_shim_aq_prime_and_start(aq) };
            if status == 0 {
                if self.is_seeking()
                    || self.abort_requested.load(Ordering::Acquire)
                    || self.is_closing.load(Ordering::Acquire)
                    || self.get_state() != DKPlayerState::Playing
                {
                    unsafe { dk_shim_aq_stop_reset(aq) };
                    return;
                }
                self.audio_start_fail_count.store(0, Ordering::Relaxed);
                let started_ns = steady_now_ns();
                self.audio_steady_start_ns.store(started_ns, Ordering::Relaxed);
                self.clock.fallback_clock_ns.store(started_ns, Ordering::Relaxed);
                self.audio_queue_started.store(true, Ordering::Release);
                emit_log(
                    0,
                    &format!(
                        "DKEngine: AudioQueue started smoothly (base PTS: {:.3}s, rebuf={})",
                        load_f64(&self.clock.audio_clock_base_pts_bits),
                        self.audio_rebuffer_count.load(Ordering::Relaxed)
                    ),
                );
            } else {
                self.audio_queue_started.store(false, Ordering::Release);
                let fails = self.audio_start_fail_count.fetch_add(1, Ordering::Relaxed) + 1;
                if fails == 1 || fails == 6 {
                    emit_log(2, &format!("DKEngine Error: AudioQueueStart returned OSStatus {status} (attempt {fails})"));
                }
                if fails >= 6 {
                    self.audio_hal_disabled.store(true, Ordering::Release);
                    let fb_pts = load_f64(&self.clock.current_pos_bits).max(0.0);
                    store_f64(&self.clock.ext_clock_base_pts_bits, fb_pts);
                    self.clock.ext_clock_start_ns.store(steady_now_ns(), Ordering::Relaxed);
                    emit_log(1, "DKEngine: Falling back to system presentation clock after repeated AudioQueueStart errors");
                }
            }
        } else {
            unsafe { dk_shim_aq_reset_only(aq) };
            self.audio_queue_started.store(false, Ordering::Release);
        }
    }

    fn signal_seek_request(&self, target_sec: f64, accurate: bool) {
        store_f64(&self.seek_target_bits, target_sec.max(0.0));
        self.seek_accurate.store(accurate, Ordering::Release);
        self.latest_seek_seq.fetch_add(1, Ordering::AcqRel);
        self.seek_requested.store(true, Ordering::Release);
        self.demux_cv.notify_all();
    }

    fn clear_sub_pkt_history(&self) {
        if let Ok(mut hist) = self.sub_hist_mtx.lock() {
            hist.pkts.clear();
            hist.bytes = 0;
        }
        self.sub_hist_trimmed.store(false, Ordering::Relaxed);
    }

    fn record_sub_pkt_history(&self, pkt: &AvPacket) {
        let sz = pkt.size();
        if sz <= 0 {
            return;
        }
        let Some(clone) = pkt.clone_pkt() else { return };
        const MAX_SUB_HIST_BYTES: usize = 4 * 1024 * 1024;
        const MAX_SUB_HIST_PKTS: usize = 2500;
        if let Ok(mut hist) = self.sub_hist_mtx.lock() {
            hist.bytes += sz as usize;
            hist.pkts.push_back(clone);
            while hist.pkts.len() > MAX_SUB_HIST_PKTS || hist.bytes > MAX_SUB_HIST_BYTES {
                if let Some(old) = hist.pkts.pop_front() {
                    let old_sz = old.size().max(0) as usize;
                    hist.bytes = hist.bytes.saturating_sub(old_sz);
                }
                self.sub_hist_trimmed.store(true, Ordering::Relaxed);
            }
        }
    }

    fn replay_sub_pkt_history(&self, target_stream_idx: i32, is_secondary: bool) {
        if target_stream_idx < 0 {
            return;
        }
        let mut clones = Vec::new();
        if let Ok(hist) = self.sub_hist_mtx.lock() {
            for src in &hist.pkts {
                if src.stream_index() == target_stream_idx {
                    if let Some(cp) = src.clone_pkt() {
                        clones.push(cp);
                    }
                }
            }
        }
        if clones.is_empty() {
            return;
        }
        let fmt = self.format_ctx.load(Ordering::Acquire);
        if let Ok(mut sub) = self.sub_mtx.lock() {
            for cp in &clones {
                sub.decode_packet_for_slot(fmt, cp.0, target_stream_idx, is_secondary);
            }
            sub.sub_last_non_empty = false;
            sub.sub_style_dirty = true;
            sub.sub_serial += 1;
        }
    }

    fn fallback_video_to_software(&self) -> bool {
        let fmt = self.format_ctx.load(Ordering::Acquire);
        let v_idx = self.video_stream_idx.load(Ordering::Acquire);
        if fmt.is_null() || v_idx < 0 {
            return false;
        }
        self.vt_failed.store(true, Ordering::Release);
        let Ok(mut vc) = self.video_codec_mtx.lock() else { return false };
        let mut old_ctx = vc.0 as *mut c_void;
        let mut old_hw = vc.1 as *mut c_void;
        unsafe {
            dk_shim_close_codec(&mut old_ctx);
            dk_shim_unref_hw_ctx(&mut old_hw);
        }
        vc.0 = 0;
        vc.1 = 0;

        let threads = thread::available_parallelism().map(|n| n.get() as i32).unwrap_or(4).clamp(2, 8);
        let mut new_ctx: *mut c_void = ptr::null_mut();
        let mut new_hw: *mut c_void = ptr::null_mut();
        let mut is_hw = false;
        let mut dec_name = [0 as c_char; 32];
        let rc = unsafe {
            dk_shim_open_video_decoder(
                fmt,
                v_idx,
                false,
                threads,
                self.hw_fmt_ctx_opaque.load(Ordering::Acquire),
                &mut new_ctx,
                &mut new_hw,
                &mut is_hw,
                dec_name.as_mut_ptr(),
            )
        };
        if rc < 0 || new_ctx.is_null() {
            return false;
        }
        vc.0 = new_ctx as usize;
        vc.1 = new_hw as usize;
        if let Ok(mut st) = self.stats_mtx.lock() {
            st.is_hw_accelerated = false;
        }
        emit_log(
            1,
            &format!("DKEngine: VideoToolbox unsupported for stream profile; switched seamlessly to {threads}-thread software decode"),
        );
        true
    }

    fn demux_worker(&self) {
        let Some(mut pkt) = AvPacket::alloc() else { return };
        let mut consecutive_io_errors = 0;
        let mut dovi_probe_packets = 0;

        while !self.abort_requested.load(Ordering::Acquire) {
            if self.seek_requested.load(Ordering::Acquire) {
                let _demux_lk = self.demux_mtx.lock();
                let my_seek_seq = self.latest_seek_seq.load(Ordering::Acquire);
                let target_sec = load_f64(&self.seek_target_bits);
                let accurate = self.seek_accurate.load(Ordering::Acquire);

                self.executing_seek_seq.store(my_seek_seq, Ordering::Release);
                self.seek_executing.store(true, Ordering::Release);
                self.seek_requested.store(false, Ordering::Release);
                let _seek_guard = SeekScopeGuard(&self.seek_executing);

                while self.audio_queue_starting.load(Ordering::Acquire) && !self.abort_requested.load(Ordering::Acquire) {
                    thread::sleep(Duration::from_millis(1));
                }
                let aq = self.audio_queue_ptr.load(Ordering::Acquire);
                if !aq.is_null() && self.audio_queue_started.swap(false, Ordering::AcqRel) {
                    unsafe { dk_shim_aq_stop_reset(aq) };
                }

                let fmt = self.format_ctx.load(Ordering::Acquire);
                let mut seek_ret = unsafe { dk_shim_seek_format(fmt, target_sec, false) };
                if seek_ret < 0
                    && !self.abort_requested.load(Ordering::Acquire)
                    && self.latest_seek_seq.load(Ordering::Acquire) == my_seek_seq
                {
                    seek_ret = unsafe { dk_shim_seek_format(fmt, target_sec, true) };
                }
                if self.abort_requested.load(Ordering::Acquire) {
                    break;
                }
                if self.latest_seek_seq.load(Ordering::Acquire) != my_seek_seq {
                    continue;
                }
                if seek_ret < 0 {
                    emit_log(
                        1,
                        &format!(
                            "DKEngine Warning: Seek to {:.2}s returned {} ({})",
                            target_sec,
                            seek_ret,
                            ffmpeg_err_string(seek_ret)
                        ),
                    );
                }

                self.demux_eof.store(false, Ordering::Release);
                self.video_eof.store(false, Ordering::Release);
                self.audio_eof.store(false, Ordering::Release);
                let drop_until = if accurate { target_sec } else { -1.0 };
                store_f64(&self.video_seek_drop_bits, drop_until);
                store_f64(&self.audio_seek_drop_bits, drop_until);
                consecutive_io_errors = 0;
                pkt.unref();

                if let Ok(mut vq) = self.video_pkt_mtx.lock() {
                    vq.clear();
                }
                if let Ok(mut aq_pkts) = self.audio_pkt_mtx.lock() {
                    aq_pkts.clear();
                }
                self.queued_pkt_bytes.store(0, Ordering::Relaxed);
                store_f64(&self.last_demuxed_pts_bits, target_sec);

                if let Ok(vc) = self.video_codec_mtx.lock() {
                    if vc.0 != 0 {
                        unsafe { dk_shim_flush_codec(vc.0 as *mut c_void) };
                    }
                }
                if let Ok(ac) = self.audio_codec_mtx.lock() {
                    if ac.codec_ctx != 0 {
                        unsafe { dk_shim_flush_codec(ac.codec_ctx as *mut c_void) };
                    }
                }
                if let Ok(mut sub) = self.sub_mtx.lock() {
                    sub.flush_for_seek(
                        self.sub_stream_idx.load(Ordering::Relaxed) >= 0,
                        self.secondary_sub_stream_idx.load(Ordering::Relaxed) >= 0,
                    );
                }
                self.clear_sub_pkt_history();

                if let Ok(mut vf) = self.video_queue_mtx.lock() {
                    vf.frames.clear();
                    vf.last_decoded_pts = target_sec;
                }
                if let Ok(mut ach) = self.audio_chunks_mtx.lock() {
                    ach.clear();
                }
                self.buffered_audio_samples.store(0, Ordering::Release);
                self.clock.reset_to(target_sec);
                if let Ok(mut vad) = self.vad_mtx.lock() {
                    vad.clear();
                }
                self.audio_rebuffer_count.store(0, Ordering::Relaxed);
                self.audio_start_fail_count.store(0, Ordering::Relaxed);
                self.audio_hal_disabled.store(false, Ordering::Relaxed);

                if !aq.is_null() && self.audio_queue_started.swap(false, Ordering::AcqRel) {
                    unsafe { dk_shim_aq_stop_reset(aq) };
                }

                if let Ok(mut spd) = self.speed_mtx.lock() {
                    spd.reset(self.get_total_bytes_read());
                }

                emit_log(0, &format!("DKEngine: Seek completed to {:.2}s (accurate={})", target_sec, i32::from(accurate)));
                let cur_st = self.get_state();
                let was_paused = matches!(cur_st, DKPlayerState::Paused | DKPlayerState::Ended);
                if cur_st == DKPlayerState::Ended {
                    self.state.store(DKPlayerState::Paused as i32, Ordering::Release);
                }
                self.seek_preview_pending.store(was_paused, Ordering::Release);
                self.force_present_next_frame.store(true, Ordering::Release);
                drop(_seek_guard);
                self.video_decode_cv.notify_all();
                self.audio_decode_cv.notify_all();
                self.video_frame_cv.notify_all();
                continue;
            }

            let v_pkts = self.video_pkt_mtx.lock().map(|q| q.len()).unwrap_or(0);
            let a_pkts = self.audio_pkt_mtx.lock().map(|q| q.len()).unwrap_or(0);
            let cur_pts = self.get_master_clock().max(0.0);
            let ahead_sec = (load_f64(&self.last_demuxed_pts_bits) - cur_pts).max(0.0);
            let total_pkt_bytes = self.queued_pkt_bytes.load(Ordering::Relaxed);

            let time_enough = if self.video_stream_idx.load(Ordering::Relaxed) < 0 {
                a_pkts >= 1500
            } else {
                ahead_sec >= 90.0 && v_pkts >= 60
            };
            let pkts_enough = v_pkts >= 2500;
            let mem_enough = total_pkt_bytes >= self.max_buffer_bytes.load(Ordering::Relaxed);

            if time_enough || pkts_enough || mem_enough {
                if let Ok(lk) = self.demux_mtx.lock() {
                    let _ = self.demux_cv.wait_timeout(lk, Duration::from_millis(15));
                }
                continue;
            }

            let fmt = self.format_ctx.load(Ordering::Acquire);
            let mut stream_idx = -1i32;
            let mut pkt_size = 0i32;
            let mut corrupt = false;
            let mut pkt_sec = 0.0f64;
            let mut has_pts = false;
            let mut data_ptr: *const u8 = ptr::null();

            let ret = unsafe {
                dk_shim_read_frame(
                    fmt,
                    pkt.0,
                    &mut stream_idx,
                    &mut pkt_size,
                    &mut corrupt,
                    &mut pkt_sec,
                    &mut has_pts,
                    &mut data_ptr,
                )
            };

            if ret < 0 {
                if self.abort_requested.load(Ordering::Acquire) || self.is_closing.load(Ordering::Acquire) {
                    break;
                }
                if self.seek_requested.load(Ordering::Acquire) {
                    unsafe { dk_shim_clear_avio_error(fmt) };
                    continue;
                }
                if unsafe { dk_shim_is_eof(ret) } {
                    consecutive_io_errors = 0;
                    if !self.demux_eof.swap(true, Ordering::AcqRel) {
                        if let Ok(mut vq) = self.video_pkt_mtx.lock() {
                            vq.push_back(None);
                        }
                        self.video_decode_cv.notify_one();
                        if let Ok(mut aq_pkts) = self.audio_pkt_mtx.lock() {
                            aq_pkts.push_back(None);
                        }
                        self.audio_decode_cv.notify_one();
                    }
                    if let Ok(lk) = self.demux_mtx.lock() {
                        let _ = self.demux_cv.wait_timeout_while(lk, Duration::from_millis(50), |_| {
                            !self.abort_requested.load(Ordering::Acquire)
                                && !self.seek_requested.load(Ordering::Acquire)
                                && self.demux_eof.load(Ordering::Acquire)
                        });
                    }
                    continue;
                }
                if unsafe { dk_shim_is_eagain(ret) } {
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
                consecutive_io_errors += 1;
                if consecutive_io_errors == 1 {
                    emit_log(
                        1,
                        &format!("DKEngine Warning: av_read_frame failed ({}: {}), retrying", ret, ffmpeg_err_string(ret)),
                    );
                }
                if consecutive_io_errors >= 10 {
                    emit_log(
                        2,
                        &format!(
                            "DKEngine Error: av_read_frame failed {} consecutive times ({}: {}), stopping playback",
                            consecutive_io_errors,
                            ret,
                            ffmpeg_err_string(ret)
                        ),
                    );
                    self.state.store(DKPlayerState::Error as i32, Ordering::Release);
                    break;
                }
                unsafe { dk_shim_avio_retry_reseek(fmt) };
                thread::sleep(Duration::from_millis(120));
                continue;
            }

            consecutive_io_errors = 0;
            if self.seek_requested.load(Ordering::Acquire) || corrupt {
                pkt.unref();
                unsafe { dk_shim_clear_avio_error(fmt) };
                continue;
            }

            let pb_bytes = unsafe { dk_shim_avio_bytes_read(fmt) };
            let has_custom_read = self.custom_io.lock().map(|io| io.read_cb.is_some()).unwrap_or(false);
            if pb_bytes > 0 && pb_bytes > self.total_bytes_read.load(Ordering::Relaxed) {
                self.total_bytes_read.store(pb_bytes, Ordering::Relaxed);
            } else if !has_custom_read && pkt_size > 0 && pb_bytes <= 0 {
                self.total_bytes_read.fetch_add(pkt_size as i64, Ordering::Relaxed);
            }

            let v_idx = self.video_stream_idx.load(Ordering::Relaxed);
            let a_idx = self.audio_stream_idx.load(Ordering::Relaxed);

            if (stream_idx == v_idx || stream_idx == a_idx) && has_pts && pkt_sec > load_f64(&self.last_demuxed_pts_bits) {
                store_f64(&self.last_demuxed_pts_bits, pkt_sec);
            }

            if stream_idx == v_idx {
                if !self.dovi_detected.load(Ordering::Relaxed)
                    && dovi_probe_packets < 120
                    && !data_ptr.is_null()
                    && pkt_size > 0
                    && unsafe { dk_shim_is_hevc_stream(fmt, stream_idx) }
                {
                    dovi_probe_packets += 1;
                    let slice = unsafe { std::slice::from_raw_parts(data_ptr, pkt_size as usize) };
                    if check_dovi_rpu_or_el(slice) {
                        self.dovi_detected.store(true, Ordering::Relaxed);
                        if let Ok(mut st) = self.stats_mtx.lock() {
                            st.is_dolby_vision = true;
                        }
                    }
                }
                if let Some(moved) = pkt.move_out() {
                    let sz = moved.size() as i64;
                    if let Ok(mut vq) = self.video_pkt_mtx.lock() {
                        vq.push_back(Some(moved));
                        self.queued_pkt_bytes.fetch_add(sz, Ordering::Relaxed);
                    }
                    self.video_decode_cv.notify_one();
                } else {
                    pkt.unref();
                }
            } else if stream_idx == a_idx {
                if let Some(moved) = pkt.move_out() {
                    let sz = moved.size() as i64;
                    if let Ok(mut aq_pkts) = self.audio_pkt_mtx.lock() {
                        aq_pkts.push_back(Some(moved));
                        self.queued_pkt_bytes.fetch_add(sz, Ordering::Relaxed);
                    }
                    self.audio_decode_cv.notify_one();
                } else {
                    pkt.unref();
                }
            } else {
                let mut smeta = DKShimStreamMeta::default();
                if stream_idx >= 0
                    && unsafe { dk_shim_get_stream_meta(fmt, stream_idx as u32, &mut smeta) }
                    && smeta.codec_type == 2
                {
                    self.record_sub_pkt_history(&pkt);
                    let pri_sub = self.sub_stream_idx.load(Ordering::Relaxed);
                    let sec_sub = self.secondary_sub_stream_idx.load(Ordering::Relaxed);
                    if stream_idx == pri_sub || stream_idx == sec_sub {
                        if let Ok(mut sub) = self.sub_mtx.lock() {
                            if pri_sub >= 0 && stream_idx == pri_sub {
                                sub.decode_packet_for_slot(fmt, pkt.0, pri_sub, false);
                            }
                            if sec_sub >= 0 && stream_idx == sec_sub && sec_sub != pri_sub {
                                sub.decode_packet_for_slot(fmt, pkt.0, sec_sub, true);
                            }
                        }
                    }
                }
                pkt.unref();
            }
        }
    }

    fn video_decode_worker(&self) {
        let Some(mut frame) = AvFrame::alloc() else { return };
        let mut got_any_frame = false;

        while !self.abort_requested.load(Ordering::Acquire) {
            if self.is_seeking() {
                if let Ok(lk) = self.video_pkt_mtx.lock() {
                    let _ = self.video_decode_cv.wait_timeout_while(lk, Duration::from_millis(15), |_| {
                        !self.abort_requested.load(Ordering::Acquire) && self.is_seeking()
                    });
                }
                continue;
            }

            if self.get_state() == DKPlayerState::Paused && !self.seek_preview_pending.load(Ordering::Acquire) {
                if let Ok(lk) = self.video_pkt_mtx.lock() {
                    let _ = self.video_decode_cv.wait_timeout_while(lk, Duration::from_millis(15), |_| {
                        !self.abort_requested.load(Ordering::Acquire)
                            && !self.is_seeking()
                            && self.get_state() == DKPlayerState::Paused
                            && !self.seek_preview_pending.load(Ordering::Acquire)
                    });
                }
                continue;
            }

            {
                let Ok(mut vq) = self.video_queue_mtx.lock() else { continue };
                while vq.frames.len() >= 12 && !self.abort_requested.load(Ordering::Acquire) && !self.is_seeking() {
                    let (next_guard, _) = match self.video_frame_cv.wait_timeout(vq, Duration::from_millis(10)) {
                        Ok(res) => res,
                        Err(e) => e.into_inner(),
                    };
                    vq = next_guard;
                }
                if self.abort_requested.load(Ordering::Acquire) || self.is_seeking() {
                    continue;
                }
            }

            let dequeued = {
                let Ok(mut lk) = self.video_pkt_mtx.lock() else { continue };
                if lk.is_empty() {
                    let (next_lk, _) = match self.video_decode_cv.wait_timeout(lk, Duration::from_millis(15)) {
                        Ok(res) => res,
                        Err(e) => e.into_inner(),
                    };
                    lk = next_lk;
                }
                if self.abort_requested.load(Ordering::Acquire) {
                    break;
                }
                if self.is_seeking() || lk.is_empty() {
                    continue;
                }
                let item = lk.pop_front().unwrap();
                if let Some(ref p) = item {
                    self.queued_pkt_bytes.fetch_sub(p.size() as i64, Ordering::Relaxed);
                }
                item
            };
            self.demux_cv.notify_one();

            let is_flush = dequeued.is_none();
            let mut cur_pkt = dequeued;

            let Ok(vc_guard) = self.video_codec_mtx.lock() else { continue };
            let mut codec_ctx = vc_guard.0 as *mut c_void;
            drop(vc_guard);
            if codec_ctx.is_null() {
                continue;
            }

            let mut pkt_consumed = is_flush;
            if is_flush {
                let _vc = self.video_codec_mtx.lock();
                if let Ok(ref g) = _vc {
                    if g.0 != 0 {
                        unsafe { dk_shim_send_packet(g.0 as *mut c_void, ptr::null()) };
                    }
                }
            }

            while !self.abort_requested.load(Ordering::Acquire) && !self.is_seeking() {
                if !pkt_consumed {
                    if let Some(ref p) = cur_pkt {
                        let sret = {
                            let Ok(vc) = self.video_codec_mtx.lock() else { break };
                            codec_ctx = vc.0 as *mut c_void;
                            if codec_ctx.is_null() {
                                break;
                            }
                            unsafe { dk_shim_send_packet(codec_ctx, p.0) }
                        };
                        if !unsafe { dk_shim_is_eagain(sret) } {
                            let mut final_sret = sret;
                            if sret < 0
                                && !got_any_frame
                                && !self.vt_failed.load(Ordering::Acquire)
                                && self.hw_decode_enabled.load(Ordering::Acquire)
                                && self.fallback_video_to_software()
                            {
                                if let Ok(vc) = self.video_codec_mtx.lock() {
                                    codec_ctx = vc.0 as *mut c_void;
                                    if !codec_ctx.is_null() {
                                        final_sret = unsafe { dk_shim_send_packet(codec_ctx, p.0) };
                                    }
                                }
                            }
                            cur_pkt = None;
                            pkt_consumed = true;
                            if final_sret < 0 {
                                break;
                            }
                        }
                    }
                }

                let rret = {
                    let Ok(vc) = self.video_codec_mtx.lock() else { break };
                    codec_ctx = vc.0 as *mut c_void;
                    if codec_ctx.is_null() {
                        break;
                    }
                    unsafe { dk_shim_receive_frame(codec_ctx, frame.0) }
                };
                if unsafe { dk_shim_is_eagain(rret) } {
                    if !pkt_consumed && cur_pkt.is_some() {
                        continue;
                    }
                    break;
                }
                if unsafe { dk_shim_is_eof(rret) } {
                    self.video_eof.store(true, Ordering::Release);
                    self.seek_preview_pending.store(false, Ordering::Release);
                    break;
                }
                if rret < 0 {
                    break;
                }

                got_any_frame = true;
                let fallback_fps = self.stats_mtx.lock().map(|s| s.fps).unwrap_or(24.0);
                let prev_pts = self.video_queue_mtx.lock().map(|vq| vq.last_decoded_pts).unwrap_or(-1.0);
                let drop_target = load_f64(&self.video_seek_drop_bits);

                let mut dropped = false;
                let mut pts = 0.0f64;
                let mut color = DKGpuColorUniforms::default_sdr();
                let mut is_hw = false;
                let mut is_hdr = false;
                let mut is_dovi = false;
                let mut cs_label = [0 as c_char; 32];

                let raw_pb = {
                    let Ok(mut sw) = self.sw_video_mtx.lock() else {
                        frame.unref();
                        continue;
                    };
                    let mut sws_p = sw.sws as *mut c_void;
                    let mut pool_p = sw.pool as *mut c_void;
                    let pb = unsafe {
                        dk_shim_process_video_frame(
                            frame.0,
                            self.format_ctx.load(Ordering::Acquire),
                            self.video_stream_idx.load(Ordering::Relaxed),
                            self.stream_dovi_profile.load(Ordering::Relaxed),
                            fallback_fps,
                            prev_pts,
                            drop_target,
                            &mut dropped,
                            &mut pts,
                            &mut sws_p,
                            &mut pool_p,
                            &mut sw.pool_w,
                            &mut sw.pool_h,
                            &mut sw.pool_fmt,
                            &mut color,
                            &mut is_hw,
                            &mut is_hdr,
                            &mut is_dovi,
                            cs_label.as_mut_ptr(),
                        )
                    };
                    sw.sws = sws_p as usize;
                    sw.pool = pool_p as usize;
                    pb
                };

                if let Ok(mut vq) = self.video_queue_mtx.lock() {
                    vq.last_decoded_pts = pts;
                }
                if dropped {
                    frame.unref();
                    continue;
                }
                if drop_target > 0.0 {
                    store_f64(&self.video_seek_drop_bits, -1.0);
                }

                if !raw_pb.is_null() {
                    if let Ok(mut st) = self.stats_mtx.lock() {
                        st.is_hw_accelerated = is_hw;
                        if is_hdr {
                            st.is_hdr = true;
                        }
                        if is_dovi {
                            st.is_dolby_vision = true;
                        }
                        if cs_label[0] != 0 {
                            st.color_space = cs_label;
                        }
                    }
                    if let Ok(mut vq) = self.video_queue_mtx.lock() {
                        vq.frames.push_back(VideoFrameEntry {
                            pixbuf: OwnedPixelBuffer(raw_pb),
                            pts,
                            color,
                        });
                    }
                    self.seek_preview_pending.store(false, Ordering::Release);
                    self.video_frame_cv.notify_one();
                    self.try_start_audio_queue_if_ready();
                    if self.get_state() == DKPlayerState::Paused {
                        frame.unref();
                        break;
                    }
                }
                frame.unref();
            }
        }
    }

    fn audio_decode_worker(&self) {
        let Some(mut frame) = AvFrame::alloc() else { return };

        while !self.abort_requested.load(Ordering::Acquire) {
            if self.is_seeking() {
                if let Ok(lk) = self.audio_pkt_mtx.lock() {
                    let _ = self.audio_decode_cv.wait_timeout_while(lk, Duration::from_millis(15), |_| {
                        !self.abort_requested.load(Ordering::Acquire) && self.is_seeking()
                    });
                }
                continue;
            }

            if self.get_state() == DKPlayerState::Paused {
                if let Ok(lk) = self.audio_pkt_mtx.lock() {
                    let _ = self.audio_decode_cv.wait_timeout_while(lk, Duration::from_millis(15), |_| {
                        !self.abort_requested.load(Ordering::Acquire)
                            && !self.is_seeking()
                            && self.get_state() == DKPlayerState::Paused
                    });
                }
                continue;
            }

            if self.audio_hal_disabled.load(Ordering::Acquire) {
                if let Ok(mut ach) = self.audio_chunks_mtx.lock() {
                    ach.clear();
                }
                self.buffered_audio_samples.store(0, Ordering::Relaxed);
            }

            if self.buffered_audio_samples.load(Ordering::Relaxed) > 160_000 {
                if !self.audio_queue_started.load(Ordering::Acquire) {
                    self.try_start_audio_queue_if_ready();
                }
                if let Ok(lk) = self.audio_pkt_mtx.lock() {
                    let _ = self.audio_decode_cv.wait_timeout_while(lk, Duration::from_millis(15), |_| {
                        !self.abort_requested.load(Ordering::Acquire)
                            && self.buffered_audio_samples.load(Ordering::Relaxed) > 120_000
                            && !self.is_seeking()
                            && self.audio_queue_started.load(Ordering::Acquire)
                    });
                }
                if self.abort_requested.load(Ordering::Acquire) || self.is_seeking() {
                    continue;
                }
            }

            let dequeued = {
                let Ok(mut lk) = self.audio_pkt_mtx.lock() else { continue };
                if lk.is_empty() {
                    let (next_lk, _) = match self.audio_decode_cv.wait_timeout(lk, Duration::from_millis(15)) {
                        Ok(res) => res,
                        Err(e) => e.into_inner(),
                    };
                    lk = next_lk;
                }
                if self.abort_requested.load(Ordering::Acquire) {
                    break;
                }
                if self.is_seeking() {
                    continue;
                }
                if lk.is_empty() {
                    drop(lk);
                    if !self.audio_queue_started.load(Ordering::Acquire)
                        && self.buffered_audio_samples.load(Ordering::Relaxed) > 0
                    {
                        self.try_start_audio_queue_if_ready();
                    }
                    continue;
                }
                let item = lk.pop_front().unwrap();
                if let Some(ref p) = item {
                    self.queued_pkt_bytes.fetch_sub(p.size() as i64, Ordering::Relaxed);
                }
                item
            };
            self.demux_cv.notify_one();

            let is_flush = dequeued.is_none();
            let mut cur_pkt = dequeued;

            let Ok(mut ac) = self.audio_codec_mtx.lock() else { continue };
            if ac.codec_ctx == 0 {
                continue;
            }

            let mut pkt_consumed = is_flush;
            if is_flush {
                unsafe { dk_shim_send_packet(ac.codec_ctx as *mut c_void, ptr::null()) };
            }

            while !self.abort_requested.load(Ordering::Acquire) && !self.is_seeking() {
                if !pkt_consumed {
                    if let Some(ref p) = cur_pkt {
                        let sret = unsafe { dk_shim_send_packet(ac.codec_ctx as *mut c_void, p.0) };
                        if !unsafe { dk_shim_is_eagain(sret) } {
                            cur_pkt = None;
                            pkt_consumed = true;
                            if sret < 0 {
                                break;
                            }
                        }
                    }
                }

                let rret = unsafe { dk_shim_receive_frame(ac.codec_ctx as *mut c_void, frame.0) };
                if unsafe { dk_shim_is_eagain(rret) } {
                    if !pkt_consumed && cur_pkt.is_some() {
                        continue;
                    }
                    break;
                }
                if unsafe { dk_shim_is_eof(rret) } {
                    self.audio_eof.store(true, Ordering::Release);
                    drop(ac);
                    if !self.abort_requested.load(Ordering::Acquire)
                        && !self.is_closing.load(Ordering::Acquire)
                        && !self.audio_queue_started.load(Ordering::Acquire)
                        && self.buffered_audio_samples.load(Ordering::Relaxed) > 0
                    {
                        self.start_audio_queue_with_buffered_data();
                    }
                    break;
                }
                if rret < 0 {
                    break;
                }

                let drop_target = load_f64(&self.audio_seek_drop_bits);
                let mut dropped = false;
                let mut pts = 0.0f64;
                let mut has_pts = false;
                let mut swr_p = ac.swr_ctx as *mut c_void;
                let max_out = unsafe {
                    dk_shim_audio_frame_prepare(
                        frame.0,
                        ac.codec_ctx as *const c_void,
                        self.format_ctx.load(Ordering::Acquire),
                        self.audio_stream_idx.load(Ordering::Relaxed),
                        &mut swr_p,
                        &mut ac.swr_fmt,
                        &mut ac.swr_rate,
                        &mut ac.swr_ch,
                        drop_target,
                        &mut dropped,
                        &mut pts,
                        &mut has_pts,
                    )
                };
                ac.swr_ctx = swr_p as usize;

                if dropped {
                    frame.unref();
                    continue;
                }
                if drop_target > 0.0 {
                    store_f64(&self.audio_seek_drop_bits, -1.0);
                }
                if max_out <= 0 || swr_p.is_null() {
                    frame.unref();
                    continue;
                }

                let mut pcm = vec![0.0f32; (max_out as usize) * 2];
                let mut vad_mono = vec![0.0f32; max_out as usize];
                let converted = unsafe {
                    dk_shim_audio_frame_convert(frame.0, swr_p, pcm.as_mut_ptr(), max_out, vad_mono.as_mut_ptr())
                };
                if converted > 0 {
                    let conv = converted as usize;
                    pcm.truncate(conv * 2);
                    if let Ok(mut vad) = self.vad_mtx.lock() {
                        vad.push_mono_48k(&vad_mono[..conv], pts, has_pts);
                    }
                    if let Ok(mut ach) = self.audio_chunks_mtx.lock() {
                        ach.push_back(AudioChunk {
                            pcm,
                            pts,
                            read_offset: 0,
                        });
                        self.buffered_audio_samples.fetch_add(converted as i64, Ordering::Relaxed);
                    }
                    self.try_start_audio_queue_if_ready();
                }
                frame.unref();
            }
        }
    }

    fn get_total_bytes_read(&self) -> i64 {
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
}

// -----------------------------------------------------------------------------
// Static C Thunks for FFmpeg & AudioQueue
// -----------------------------------------------------------------------------

unsafe extern "C" fn interrupt_callback_thunk(opaque: *mut c_void) -> c_int {
    if opaque.is_null() {
        return 0;
    }
    let p = &*(opaque as *const DKPlayer);
    i32::from(p.abort_requested.load(Ordering::Acquire) || p.is_closing.load(Ordering::Acquire))
}

unsafe extern "C" fn avio_read_thunk(opaque: *mut c_void, buf: *mut u8, buf_size: c_int) -> c_int {
    if opaque.is_null() {
        return dk_shim_averror_eof();
    }
    let p = &*(opaque as *const DKPlayer);
    if p.abort_requested.load(Ordering::Acquire) || p.is_closing.load(Ordering::Acquire) {
        return dk_shim_averror_exit();
    }
    let (read_cb, io_opaque) = match p.custom_io.lock() {
        Ok(io) => (io.read_cb, io.opaque as *mut c_void),
        Err(_) => return dk_shim_averror_eof(),
    };
    let Some(cb) = read_cb else { return dk_shim_averror_eof() };
    let n = cb(io_opaque, buf, buf_size);
    if n > 0 {
        p.total_bytes_read.fetch_add(n as i64, Ordering::Relaxed);
        return n;
    }
    if n == 0 {
        return dk_shim_averror_eof();
    }
    if p.should_yield_read() {
        dk_shim_averror_exit()
    } else {
        dk_shim_averror_eio()
    }
}

unsafe extern "C" fn avio_seek_thunk(opaque: *mut c_void, offset: i64, whence: c_int) -> i64 {
    if opaque.is_null() {
        return dk_shim_averror_enosys() as i64;
    }
    let p = &*(opaque as *const DKPlayer);
    let (seek_cb, io_opaque) = match p.custom_io.lock() {
        Ok(io) => (io.seek_cb, io.opaque as *mut c_void),
        Err(_) => return dk_shim_averror_enosys() as i64,
    };
    let Some(cb) = seek_cb else { return dk_shim_averror_enosys() as i64 };
    cb(io_opaque, offset, whence)
}

unsafe extern "C" fn is_vt_failed_thunk(opaque: *mut c_void) -> bool {
    if opaque.is_null() {
        return false;
    }
    let p = &*(opaque as *const DKPlayer);
    p.vt_failed.load(Ordering::Relaxed)
}

unsafe extern "C" fn on_sw_format_selected_thunk(opaque: *mut c_void) {
    if opaque.is_null() {
        return;
    }
    let p = &*(opaque as *const DKPlayer);
    if let Ok(mut st) = p.stats_mtx.lock() {
        st.is_hw_accelerated = false;
    }
}

unsafe extern "C" fn aq_fill_only_trampoline(ctx: *mut c_void, dst: *mut f32, cap_floats: u32) {
    if ctx.is_null() || dst.is_null() || cap_floats == 0 {
        return;
    }
    let p = &*(ctx as *const DKPlayer);
    let slice = std::slice::from_raw_parts_mut(dst, cap_floats as usize);
    p.fill_audio_buffer(slice);
}

unsafe extern "C" fn aq_callback_trampoline(
    rust_ctx: *mut c_void,
    aq: *mut c_void,
    buf: *mut c_void,
    dst_floats: *mut f32,
    cap_floats: u32,
) {
    if rust_ctx.is_null() || aq.is_null() || buf.is_null() || dst_floats.is_null() || cap_floats == 0 {
        return;
    }
    let p = &*(rust_ctx as *const DKPlayer);
    if p.abort_requested.load(Ordering::Acquire) || p.is_closing.load(Ordering::Acquire) {
        return;
    }
    let slice = std::slice::from_raw_parts_mut(dst_floats, cap_floats as usize);
    p.fill_audio_buffer(slice);
    dk_shim_aq_commit_and_enqueue(aq, buf);
    p.audio_decode_cv.notify_one();
}

// -----------------------------------------------------------------------------
// URL Normalization, Redaction & Auto-Subtitle Stream Scoring
// -----------------------------------------------------------------------------

fn normalize_path_or_url(in_url: &str) -> String {
    let s = in_url.strip_prefix("file://").unwrap_or(in_url);
    if !s.contains('%') {
        return s.to_owned();
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex_str) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(val) = u8::from_str_radix(hex_str, 16) {
                    out.push(val);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn redact_url_for_log(raw: &str) -> String {
    let base = match raw.find('?') {
        Some(q) => format!("{}?<REDACTED>", &raw[..q]),
        None => raw.to_owned(),
    };
    if let Some(scheme) = base.find("://") {
        let host_start = scheme + 3;
        return match base[host_start..].find('/') {
            Some(rel_slash) => format!("{}<HOST>{}", &base[..host_start], &base[host_start + rel_slash..]),
            None => format!("{}<HOST>", &base[..host_start]),
        };
    }
    base
}

fn cchar_array_to_string(arr: &[c_char]) -> String {
    unsafe { CStr::from_ptr(arr.as_ptr()) }.to_string_lossy().into_owned()
}

fn write_str_to_cchar<const N: usize>(dst: &mut [c_char; N], s: &str) {
    *dst = [0 as c_char; N];
    let bytes = s.as_bytes();
    let n = bytes.len().min(N.saturating_sub(1));
    for i in 0..n {
        dst[i] = bytes[i] as c_char;
    }
}

fn score_auto_subtitle_stream(meta: &DKShimStreamMeta) -> i32 {
    if meta.codec_type != 2 {
        return -1;
    }
    let lang = cchar_array_to_string(&meta.language).to_lowercase();
    let title = cchar_array_to_string(&meta.title).to_lowercase();
    let combined = format!("{lang} {title}");

    let mut score = 0;
    let is_chs = combined.contains("chs")
        || combined.contains("zh-cn")
        || combined.contains("zh_cn")
        || combined.contains("hans")
        || combined.contains('简');
    let is_cht = combined.contains("cht")
        || combined.contains("zh-tw")
        || combined.contains("zh-hk")
        || combined.contains("hant")
        || combined.contains('繁');
    let is_zh = is_chs
        || is_cht
        || lang.contains("chi")
        || lang.contains("zho")
        || lang.contains("zh")
        || combined.contains('中');

    if is_chs {
        score += 100;
    } else if is_zh && !is_cht {
        score += 80;
    } else if is_cht {
        score += 50;
    }

    if meta.is_ass_or_ssa {
        score += 15;
    } else if meta.is_subrip_or_text {
        score += 12;
    }
    if meta.disp_default {
        score += 6;
    }
    if meta.disp_forced {
        score -= 25;
    }
    score
}

// -----------------------------------------------------------------------------
// Public C ABI Exports (37 Functions matching donby_kernel.h)
// -----------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn dk_set_log_callback(callback: DKLogCallback) {
    let ptr = callback.map(|f| f as *mut c_void).unwrap_or(ptr::null_mut());
    LOG_CALLBACK.store(ptr, Ordering::Release);
    dk_shim_install_ffmpeg_log_bridge();
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_create() -> *mut DKPlayer {
    dk_shim_install_ffmpeg_log_bridge();
    let raw = Box::into_raw(Box::new(DKPlayer::new()));
    let hw_ctx = dk_shim_alloc_hw_fmt_ctx(
        raw as *mut c_void,
        is_vt_failed_thunk,
        on_sw_format_selected_thunk,
    );
    (*raw).hw_fmt_ctx_opaque.store(hw_ctx, Ordering::Release);
    if let Ok(mut reg) = live_players().lock() {
        reg.push(raw as usize);
    }
    emit_log(0, "DKEngine: Created native Rust player instance (libass initialized)");
    raw
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_destroy(player: *mut DKPlayer) {
    if player.is_null() {
        return;
    }
    {
        let Ok(mut reg) = live_players().lock() else { return };
        let Some(pos) = reg.iter().position(|&x| x == player as usize) else {
            return;
        };
        (*player).abort_requested.store(true, Ordering::Release);
        reg.swap_remove(pos);
    }
    if let Ok(io) = (*player).custom_io.lock() {
        if let (Some(abort_cb), op) = (io.abort_cb, io.opaque as *mut c_void) {
            if !op.is_null() {
                abort_cb(op);
            }
        }
    }
    while (*player).in_flight_readers.load(Ordering::Acquire) > 0 {
        thread::sleep(Duration::from_micros(200));
    }
    dk_player_close(player);

    let mut hw_opaque = (*player).hw_fmt_ctx_opaque.swap(ptr::null_mut(), Ordering::AcqRel);
    dk_shim_free_hw_fmt_ctx(&mut hw_opaque);

    drop(Box::from_raw(player));
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_custom_io(
    player: *mut DKPlayer,
    opaque: *mut c_void,
    read_cb: DKCustomIOReadCallback,
    seek_cb: DKCustomIOSeekCallback,
    abort_cb: DKCustomIOAbortCallback,
    close_cb: DKCustomIOCloseCallback,
) {
    let Some(p) = player.as_ref() else { return };
    if let Ok(mut io) = p.custom_io.lock() {
        io.opaque = opaque as usize;
        io.read_cb = read_cb;
        io.seek_cb = seek_cb;
        io.abort_cb = abort_cb;
        io.close_cb = close_cb;
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_request_abort(player: *mut DKPlayer) {
    if player.is_null() {
        return;
    }
    let Ok(reg) = live_players().lock() else { return };
    if !reg.contains(&(player as usize)) {
        return;
    }
    let p = &*player;
    p.external_abort_requested.store(true, Ordering::SeqCst);
    p.abort_requested.store(true, Ordering::SeqCst);
    if let Ok(io) = p.custom_io.lock() {
        if let (Some(abort_cb), op) = (io.abort_cb, io.opaque as *mut c_void) {
            if !op.is_null() {
                abort_cb(op);
            }
        }
    }
    p.demux_cv.notify_all();
    p.video_decode_cv.notify_all();
    p.audio_decode_cv.notify_all();
    p.video_frame_cv.notify_all();
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_should_yield_read(player: *mut DKPlayer) -> bool {
    let Some(p) = player.as_ref() else { return false };
    p.should_yield_read()
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_open_with_tracks(
    player: *mut DKPlayer,
    url: *const c_char,
    headers_crlf: *const c_char,
    start_sec: f64,
    hw_decode: bool,
    preferred_audio_hint: i32,
    preferred_sub_hint: i32,
) -> c_int {
    let Some(p) = player.as_ref() else { return -1 };
    if url.is_null() {
        return -1;
    }
    if p.external_abort_requested.load(Ordering::SeqCst) {
        p.state.store(DKPlayerState::Error as i32, Ordering::Release);
        return -1;
    }

    // Preserve any pending custom IO registered prior to open across dk_player_close
    let saved_io = p.custom_io.lock().map(|mut g| std::mem::take(&mut *g)).unwrap_or_default();
    dk_player_close(player);
    if let Ok(mut g) = p.custom_io.lock() {
        *g = saved_io;
    }

    if p.external_abort_requested.load(Ordering::SeqCst) {
        if let Ok(mut io) = p.custom_io.lock() {
            if let (Some(close_cb), op) = (io.close_cb, io.opaque as *mut c_void) {
                if !op.is_null() {
                    close_cb(op);
                }
            }
            *io = CustomIoSlot::default();
        }
        p.state.store(DKPlayerState::Error as i32, Ordering::Release);
        return -1;
    }

    let raw_url = CStr::from_ptr(url).to_string_lossy();
    let normalized_url = normalize_path_or_url(&raw_url);
    let Ok(open_target_c) = CString::new(normalized_url.as_str()) else { return -1 };
    let is_local_file = normalized_url.starts_with('/');
    let (use_custom_io, has_seek_cb) = p
        .custom_io
        .lock()
        .map(|io| (io.read_cb.is_some() && io.opaque != 0, io.seek_cb.is_some()))
        .unwrap_or((false, false));

    let safe_log_url = if is_local_file {
        normalized_url.clone()
    } else {
        redact_url_for_log(&normalized_url)
    };
    emit_log(
        0,
        &format!(
            "DKEngine: Opening URL: {} (local={}, custom_io={}, hw_decode={}, start={:.2}s)",
            safe_log_url,
            i32::from(is_local_file),
            i32::from(use_custom_io),
            i32::from(hw_decode),
            start_sec
        ),
    );
    let t0 = std::time::Instant::now();

    p.state.store(DKPlayerState::Opening as i32, Ordering::Release);
    p.is_closing.store(false, Ordering::Release);
    p.hw_decode_enabled.store(hw_decode, Ordering::Release);
    p.vt_failed.store(false, Ordering::Release);
    p.dovi_detected.store(false, Ordering::Release);
    p.stream_dovi_profile.store(0, Ordering::Release);
    p.demux_eof.store(false, Ordering::Release);
    p.video_eof.store(false, Ordering::Release);
    p.audio_eof.store(false, Ordering::Release);
    store_f64(&p.video_seek_drop_bits, -1.0);
    store_f64(&p.audio_seek_drop_bits, -1.0);
    p.queued_pkt_bytes.store(0, Ordering::Release);
    p.total_bytes_read.store(0, Ordering::Release);
    p.clear_sub_pkt_history();
    p.audio_rebuffer_count.store(0, Ordering::Release);
    p.audio_start_fail_count.store(0, Ordering::Release);
    p.last_audio_start_attempt_ns.store(0, Ordering::Release);
    p.audio_steady_start_ns.store(0, Ordering::Release);
    p.audio_hal_disabled.store(false, Ordering::Release);
    store_f64(&p.last_demuxed_pts_bits, start_sec.max(0.0));
    if let Ok(mut vq) = p.video_queue_mtx.lock() {
        vq.last_decoded_pts = -1.0;
    }
    p.abort_requested.store(false, Ordering::SeqCst);
    if p.external_abort_requested.load(Ordering::SeqCst) {
        p.abort_requested.store(true, Ordering::SeqCst);
        if let Ok(mut io) = p.custom_io.lock() {
            if let (Some(close_cb), op) = (io.close_cb, io.opaque as *mut c_void) {
                if !op.is_null() {
                    close_cb(op);
                }
            }
            *io = CustomIoSlot::default();
        }
        p.state.store(DKPlayerState::Error as i32, Ordering::Release);
        return -1;
    }
    p.seek_requested.store(false, Ordering::Release);
    p.seek_preview_pending.store(false, Ordering::Release);
    p.force_present_next_frame.store(false, Ordering::Release);
    p.video_stream_idx.store(-1, Ordering::Release);
    p.audio_stream_idx.store(-1, Ordering::Release);
    p.sub_stream_idx.store(-1, Ordering::Release);
    p.secondary_sub_stream_idx.store(-1, Ordering::Release);
    if let Ok(mut st) = p.stats_mtx.lock() {
        *st = DKRuntimeStats::default();
    }

    let is_mpeg_ts = normalized_url.contains(".ts") || normalized_url.contains(".m2ts");
    let mut fmt_ctx: *mut c_void = ptr::null_mut();
    let mut custom_avio: *mut c_void = ptr::null_mut();
    let open_ret = dk_shim_open_format(
        open_target_c.as_ptr(),
        headers_crlf,
        is_local_file,
        start_sec > 0.5,
        is_mpeg_ts,
        use_custom_io,
        has_seek_cb,
        player as *mut c_void,
        interrupt_callback_thunk,
        avio_read_thunk,
        avio_seek_thunk,
        &mut fmt_ctx,
        &mut custom_avio,
    );

    if open_ret < 0
        || fmt_ctx.is_null()
        || p.abort_requested.load(Ordering::SeqCst)
        || p.external_abort_requested.load(Ordering::SeqCst)
    {
        emit_log(
            2,
            &format!("DKEngine Error: open/probe failed ({}: {})", open_ret, ffmpeg_err_string(open_ret)),
        );
        dk_shim_close_format(&mut fmt_ctx, &mut custom_avio);
        if let Ok(mut io) = p.custom_io.lock() {
            if let (Some(close_cb), op) = (io.close_cb, io.opaque as *mut c_void) {
                if !op.is_null() {
                    close_cb(op);
                }
            }
            *io = CustomIoSlot::default();
        }
        p.state.store(DKPlayerState::Error as i32, Ordering::Release);
        return -1;
    }

    p.format_ctx.store(fmt_ctx, Ordering::Release);
    p.custom_avio_ctx.store(custom_avio, Ordering::Release);

    let mut nb_streams = 0u32;
    let mut nb_chapters = 0u32;
    let mut duration_sec = 0.0f64;
    let mut fmt_bitrate = 0i64;
    dk_shim_format_summary(fmt_ctx, &mut nb_streams, &mut nb_chapters, &mut duration_sec, &mut fmt_bitrate);
    store_f64(&p.duration_bits, duration_sec);

    emit_log(
        0,
        &format!(
            "DKEngine: Stream connected and parsed in {:.1}ms (nb_streams={})",
            t0.elapsed().as_secs_f64() * 1000.0,
            nb_streams
        ),
    );

    let mut stream_metas = Vec::with_capacity(nb_streams as usize);
    for i in 0..nb_streams {
        let mut m = DKShimStreamMeta::default();
        dk_shim_get_stream_meta(fmt_ctx, i, &mut m);
        stream_metas.push(m);
    }

    let mut preferred_audio_idx = -1i32;
    if preferred_audio_hint >= 0
        && (preferred_audio_hint as usize) < stream_metas.len()
        && stream_metas[preferred_audio_hint as usize].codec_type == 1
    {
        preferred_audio_idx = preferred_audio_hint;
    }

    let disable_auto_sub = preferred_sub_hint == -2;
    let mut preferred_sub_idx = -1i32;
    if preferred_sub_hint >= 0
        && (preferred_sub_hint as usize) < stream_metas.len()
        && stream_metas[preferred_sub_hint as usize].codec_type == 2
    {
        preferred_sub_idx = preferred_sub_hint;
    }

    let mut best_sub_score = -1000i32;
    for (i, m) in stream_metas.iter().enumerate() {
        if m.codec_type == 1 && preferred_audio_hint < 0 {
            if preferred_audio_idx < 0
                || (m.disp_default && !stream_metas[preferred_audio_idx as usize].disp_default)
            {
                preferred_audio_idx = i as i32;
            }
        } else if m.codec_type == 2 && !disable_auto_sub && preferred_sub_hint < 0 {
            let sc = score_auto_subtitle_stream(m);
            if preferred_sub_idx < 0 || sc > best_sub_score {
                preferred_sub_idx = i as i32;
                best_sub_score = sc;
            }
        }
    }

    let sw_threads = thread::available_parallelism().map(|n| n.get() as i32).unwrap_or(4).clamp(2, 8);
    let mut opened_video_w = 0;
    let mut opened_video_h = 0;

    for (i, m) in stream_metas.iter().enumerate() {
        let idx = i as i32;
        if m.codec_type == 0 && p.video_stream_idx.load(Ordering::Relaxed) < 0 && !m.disp_attached_pic {
            if m.dovi_profile > 0 {
                p.stream_dovi_profile.store(m.dovi_profile, Ordering::Release);
                p.dovi_detected.store(true, Ordering::Release);
                emit_log(
                    0,
                    &format!(
                        "DKEngine: Detected Dolby Vision Configuration Record (profile={}, level={}, compat={})",
                        m.dovi_profile, m.dovi_level, m.dovi_compat
                    ),
                );
            }

            let mut v_ctx: *mut c_void = ptr::null_mut();
            let mut hw_ctx: *mut c_void = ptr::null_mut();
            let mut is_hw = false;
            let mut dec_name = [0 as c_char; 32];
            let mut vrc = dk_shim_open_video_decoder(
                fmt_ctx,
                idx,
                hw_decode,
                sw_threads,
                p.hw_fmt_ctx_opaque.load(Ordering::Acquire),
                &mut v_ctx,
                &mut hw_ctx,
                &mut is_hw,
                dec_name.as_mut_ptr(),
            );
            if vrc < 0 && hw_decode {
                p.vt_failed.store(true, Ordering::Release);
                vrc = dk_shim_open_video_decoder(
                    fmt_ctx,
                    idx,
                    false,
                    sw_threads,
                    p.hw_fmt_ctx_opaque.load(Ordering::Acquire),
                    &mut v_ctx,
                    &mut hw_ctx,
                    &mut is_hw,
                    dec_name.as_mut_ptr(),
                );
            }
            if vrc == 0 && !v_ctx.is_null() {
                p.video_stream_idx.store(idx, Ordering::Release);
                if let Ok(mut vc) = p.video_codec_mtx.lock() {
                    vc.0 = v_ctx as usize;
                    vc.1 = hw_ctx as usize;
                }
                opened_video_w = m.width;
                opened_video_h = m.height;
                let br_mbps = if m.bit_rate > 0 {
                    (m.bit_rate as f64) / 1_000_000.0
                } else if fmt_bitrate > 0 {
                    (fmt_bitrate as f64) / 1_000_000.0
                } else {
                    0.0
                };
                store_f64(&p.atomic_video_bitrate_bits, br_mbps);

                if let Ok(mut st) = p.stats_mtx.lock() {
                    st.width = m.width;
                    st.height = m.height;
                    st.fps = m.fps;
                    st.bit_depth = m.bit_depth;
                    st.video_bitrate_mbps = br_mbps;
                    st.is_hw_accelerated = is_hw;
                    st.video_codec = dec_name;

                    if m.dovi_profile > 0 {
                        st.is_dolby_vision = true;
                        st.is_hdr = true;
                        write_str_to_cchar(&mut st.color_space, &format!("Dolby Vision P{}", m.dovi_profile));
                    } else if m.color_trc == 16 {
                        st.is_hdr = true;
                        write_str_to_cchar(&mut st.color_space, "BT.2020 PQ (HDR10)");
                    } else if m.color_trc == 18 {
                        st.is_hdr = true;
                        write_str_to_cchar(&mut st.color_space, "BT.2020 HLG");
                    } else if m.color_primaries == 9 {
                        write_str_to_cchar(&mut st.color_space, "BT.2020");
                    } else if m.color_primaries == 1 {
                        write_str_to_cchar(&mut st.color_space, "BT.709 (SDR)");
                    } else {
                        write_str_to_cchar(&mut st.color_space, "Auto/SDR");
                    }
                }
                emit_log(
                    0,
                    &format!(
                        "DKEngine: Video Stream #{}: {} {}x{} @ {:.2}fps (accel={}, depth={}bit)",
                        idx,
                        cchar_array_to_string(&dec_name),
                        m.width,
                        m.height,
                        m.fps,
                        if is_hw { "VideoToolbox" } else { "Software" },
                        m.bit_depth
                    ),
                );
            }
        } else if m.codec_type == 1
            && p.audio_stream_idx.load(Ordering::Relaxed) < 0
            && (preferred_audio_idx < 0 || idx == preferred_audio_idx)
        {
            let mut a_ctx: *mut c_void = ptr::null_mut();
            let mut swr_p: *mut c_void = ptr::null_mut();
            let mut s_fmt = -1;
            let mut s_rate = 0;
            let mut s_ch = 0;
            let mut dec_name = [0 as c_char; 32];
            if dk_shim_open_audio_decoder(
                fmt_ctx,
                idx,
                &mut a_ctx,
                &mut swr_p,
                &mut s_fmt,
                &mut s_rate,
                &mut s_ch,
                dec_name.as_mut_ptr(),
            ) == 0
                && !a_ctx.is_null()
            {
                p.audio_stream_idx.store(idx, Ordering::Release);
                if let Ok(mut ac) = p.audio_codec_mtx.lock() {
                    ac.codec_ctx = a_ctx as usize;
                    ac.swr_ctx = swr_p as usize;
                    ac.swr_fmt = s_fmt;
                    ac.swr_rate = s_rate;
                    ac.swr_ch = s_ch;
                }
                if let Ok(mut st) = p.stats_mtx.lock() {
                    st.audio_codec = dec_name;
                }
                emit_log(
                    0,
                    &format!(
                        "DKEngine: Audio Stream #{}: {} ({} channels, {}Hz)",
                        idx,
                        cchar_array_to_string(&dec_name),
                        m.channels,
                        m.sample_rate
                    ),
                );
            }
        } else if m.codec_type == 2
            && p.sub_stream_idx.load(Ordering::Relaxed) < 0
            && !disable_auto_sub
            && (preferred_sub_idx < 0 || idx == preferred_sub_idx)
        {
            p.sub_stream_idx.store(idx, Ordering::Release);
        }
    }

    let has_audio_swr = p
        .audio_codec_mtx
        .lock()
        .map(|ac| ac.codec_ctx != 0 && ac.swr_ctx != 0)
        .unwrap_or(false);
    if has_audio_swr {
        p.init_audio_queue();
    }

    if let Ok(mut sub) = p.sub_mtx.lock() {
        let sub_idx = p.sub_stream_idx.load(Ordering::Relaxed);
        if sub_idx >= 0 {
            sub.open_stream_decoder(fmt_ctx, sub_idx, false, opened_video_w, opened_video_h);
        } else {
            sub.ensure_default_primary_track();
        }
    }

    if start_sec > 0.5 {
        let _ = dk_shim_seek_format(fmt_ctx, start_sec, false);
        store_f64(&p.video_seek_drop_bits, -1.0);
        store_f64(&p.audio_seek_drop_bits, -1.0);
        p.force_present_next_frame.store(true, Ordering::Release);
        p.clock.reset_to(start_sec);
    } else {
        p.clock.reset_to(0.0);
    }

    if p.abort_requested.load(Ordering::SeqCst) || p.external_abort_requested.load(Ordering::SeqCst) {
        p.state.store(DKPlayerState::Error as i32, Ordering::Release);
        return -1;
    }

    let p_addr = player as usize;
    let has_video = p.video_codec_mtx.lock().map(|vc| vc.0 != 0).unwrap_or(false);
    let has_audio = p.audio_codec_mtx.lock().map(|ac| ac.codec_ctx != 0).unwrap_or(false);

    if let Ok(mut workers) = p.workers_mtx.lock() {
        workers.demux = Some(thread::spawn(move || unsafe {
            (*(p_addr as *const DKPlayer)).demux_worker();
        }));
        if has_video {
            workers.video = Some(thread::spawn(move || unsafe {
                (*(p_addr as *const DKPlayer)).video_decode_worker();
            }));
        }
        if has_audio {
            workers.audio = Some(thread::spawn(move || unsafe {
                (*(p_addr as *const DKPlayer)).audio_decode_worker();
            }));
        }
    }

    p.state.store(DKPlayerState::Playing as i32, Ordering::Release);
    0
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_close(player: *mut DKPlayer) {
    let Some(p) = player.as_ref() else { return };
    if p.is_closing
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return;
    }
    p.abort_requested.store(true, Ordering::Release);
    if let Ok(io) = p.custom_io.lock() {
        if let (Some(abort_cb), op) = (io.abort_cb, io.opaque as *mut c_void) {
            if !op.is_null() {
                abort_cb(op);
            }
        }
    }

    while p.in_flight_readers.load(Ordering::Acquire) > 0 {
        thread::sleep(Duration::from_micros(200));
    }

    p.demux_cv.notify_all();
    p.video_decode_cv.notify_all();
    p.audio_decode_cv.notify_all();
    p.video_frame_cv.notify_all();

    let (d_th, v_th, a_th) = if let Ok(mut w) = p.workers_mtx.lock() {
        (w.demux.take(), w.video.take(), w.audio.take())
    } else {
        (None, None, None)
    };
    if let Some(h) = d_th {
        let _ = h.join();
    }
    if let Some(h) = v_th {
        let _ = h.join();
    }
    if let Some(h) = a_th {
        let _ = h.join();
    }

    let mut aq = p.audio_queue_ptr.swap(ptr::null_mut(), Ordering::AcqRel);
    let mut tr = p.audio_trampoline_ptr.swap(ptr::null_mut(), Ordering::AcqRel);
    if !aq.is_null() || !tr.is_null() {
        while p.audio_queue_starting.load(Ordering::Acquire) {
            thread::sleep(Duration::from_millis(1));
        }
        dk_shim_aq_stop_dispose(&mut aq, &mut tr);
    }
    if let Ok(mut bufs) = p.audio_buffers.lock() {
        *bufs = [ptr::null_mut(); 4];
    }

    if let Ok(mut vpkts) = p.video_pkt_mtx.lock() {
        vpkts.clear();
    }
    if let Ok(mut apkts) = p.audio_pkt_mtx.lock() {
        apkts.clear();
    }
    p.queued_pkt_bytes.store(0, Ordering::Relaxed);
    p.clear_sub_pkt_history();

    if let Ok(mut vq) = p.video_queue_mtx.lock() {
        vq.frames.clear();
        vq.last_frame = None;
    }
    if let Ok(mut ach) = p.audio_chunks_mtx.lock() {
        ach.clear();
    }
    p.buffered_audio_samples.store(0, Ordering::Relaxed);
    if let Ok(mut vad) = p.vad_mtx.lock() {
        vad.clear();
    }

    if let Ok(mut ac) = p.audio_codec_mtx.lock() {
        let mut swr = ac.swr_ctx as *mut c_void;
        let mut actx = ac.codec_ctx as *mut c_void;
        dk_shim_close_swr(&mut swr);
        dk_shim_close_codec(&mut actx);
        *ac = AudioCodecState::default();
    }
    if let Ok(mut sw) = p.sw_video_mtx.lock() {
        let mut sws = sw.sws as *mut c_void;
        let mut pool = sw.pool as *mut c_void;
        dk_shim_release_sw_video_res(&mut sws, &mut pool);
        *sw = SwVideoState::default();
    }
    if let Ok(mut sub) = p.sub_mtx.lock() {
        sub.close_stream_state();
    }
    if let Ok(mut vc) = p.video_codec_mtx.lock() {
        let mut vctx = vc.0 as *mut c_void;
        let mut hw = vc.1 as *mut c_void;
        dk_shim_close_codec(&mut vctx);
        dk_shim_unref_hw_ctx(&mut hw);
        *vc = (0, 0);
    }

    let mut fmt = p.format_ctx.swap(ptr::null_mut(), Ordering::AcqRel);
    let mut custom_avio = p.custom_avio_ctx.swap(ptr::null_mut(), Ordering::AcqRel);
    dk_shim_close_format(&mut fmt, &mut custom_avio);

    if let Ok(mut io) = p.custom_io.lock() {
        if let (Some(close_cb), op) = (io.close_cb, io.opaque as *mut c_void) {
            if !op.is_null() {
                close_cb(op);
            }
        }
        *io = CustomIoSlot::default();
    }

    p.video_stream_idx.store(-1, Ordering::Release);
    p.audio_stream_idx.store(-1, Ordering::Release);
    p.sub_stream_idx.store(-1, Ordering::Release);
    p.secondary_sub_stream_idx.store(-1, Ordering::Release);
    store_f64(&p.atomic_video_bitrate_bits, 0.0);
    p.audio_queue_started.store(false, Ordering::Release);
    p.state.store(DKPlayerState::Idle as i32, Ordering::Release);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_play(player: *mut DKPlayer) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    let st = p.get_state();
    if matches!(st, DKPlayerState::Paused | DKPlayerState::Ended) {
        p.state.store(DKPlayerState::Playing as i32, Ordering::Release);
        let aq = p.audio_queue_ptr.load(Ordering::Acquire);
        if !aq.is_null() && p.audio_queue_started.load(Ordering::Acquire) {
            let _ = dk_shim_aq_start_only(aq);
        }
        let now_ns = steady_now_ns();
        p.clock.ext_clock_start_ns.store(now_ns, Ordering::Relaxed);
        p.clock.fallback_clock_ns.store(now_ns, Ordering::Relaxed);
        p.video_decode_cv.notify_all();
        p.audio_decode_cv.notify_all();
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_pause(player: *mut DKPlayer) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    if p.get_state() == DKPlayerState::Playing {
        let cur = p.get_master_clock();
        p.state.store(DKPlayerState::Paused as i32, Ordering::Release);
        let aq = p.audio_queue_ptr.load(Ordering::Acquire);
        if !aq.is_null() && p.audio_queue_started.load(Ordering::Acquire) {
            dk_shim_aq_pause(aq);
        }
        store_f64(&p.clock.ext_clock_base_pts_bits, cur);
        store_f64(&p.clock.fallback_audio_clock_bits, cur);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_seek(player: *mut DKPlayer, target_sec: f64, accurate: bool) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    p.signal_seek_request(target_sec, accurate);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_rate(player: *mut DKPlayer, rate: f32) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    let cur = p.get_master_clock();
    let clamped = rate.clamp(0.25, 4.0);
    p.rate_bits.store(clamped.to_bits(), Ordering::Release);
    let aq = p.audio_queue_ptr.load(Ordering::Acquire);
    if !aq.is_null() {
        dk_shim_aq_set_rate(aq, clamped);
    }
    let now_ns = steady_now_ns();
    store_f64(&p.clock.ext_clock_base_pts_bits, cur);
    p.clock.ext_clock_start_ns.store(now_ns, Ordering::Relaxed);
    store_f64(&p.clock.fallback_audio_clock_bits, cur);
    p.clock.fallback_clock_ns.store(now_ns, Ordering::Relaxed);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_volume(player: *mut DKPlayer, volume: f32, muted: bool) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    p.volume_bits.store(volume.clamp(0.0, 2.0).to_bits(), Ordering::Release);
    p.is_muted.store(muted, Ordering::Release);
    let aq = p.audio_queue_ptr.load(Ordering::Acquire);
    if !aq.is_null() {
        dk_shim_aq_set_volume(aq, p.effective_volume());
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_buffer_limit_mb(player: *mut DKPlayer, limit_mb: i32) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    let clamped = (limit_mb.clamp(32, 2048) as i64) * 1024 * 1024;
    p.max_buffer_bytes.store(clamped, Ordering::Relaxed);
    p.demux_cv.notify_one();
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_track_count(player: *mut DKPlayer, track_type: c_int) -> c_int {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return 0 };
    let fmt = p.format_ctx.load(Ordering::Acquire);
    if fmt.is_null() {
        return 0;
    }
    let target = match track_type {
        0 => 0,
        1 => 1,
        _ => 2,
    };
    let mut nb = 0u32;
    dk_shim_format_summary(fmt, &mut nb, ptr::null_mut(), ptr::null_mut(), ptr::null_mut());
    let mut count = 0;
    for i in 0..nb {
        let mut m = DKShimStreamMeta::default();
        if dk_shim_get_stream_meta(fmt, i, &mut m) && m.codec_type == target {
            count += 1;
        }
    }
    count
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_track_info(
    player: *mut DKPlayer,
    track_type: c_int,
    ordinal: c_int,
    out_info: *mut DKTrackInfo,
) -> bool {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return false };
    let fmt = p.format_ctx.load(Ordering::Acquire);
    if fmt.is_null() || out_info.is_null() || ordinal < 0 {
        return false;
    }
    *out_info = std::mem::zeroed();
    let target = match track_type {
        0 => 0,
        1 => 1,
        _ => 2,
    };
    let mut nb = 0u32;
    dk_shim_format_summary(fmt, &mut nb, ptr::null_mut(), ptr::null_mut(), ptr::null_mut());
    let mut seen = 0;
    for i in 0..nb {
        let mut m = DKShimStreamMeta::default();
        if !dk_shim_get_stream_meta(fmt, i, &mut m) || m.codec_type != target {
            continue;
        }
        if seen == ordinal {
            let idx = i as i32;
            (*out_info).stream_index = idx;
            (*out_info).channels = m.channels;
            (*out_info).is_default = m.disp_default;
            (*out_info).is_forced = m.disp_forced;
            (*out_info).is_selected = match track_type {
                0 => p.video_stream_idx.load(Ordering::Relaxed) == idx,
                1 => p.audio_stream_idx.load(Ordering::Relaxed) == idx,
                _ => p.sub_stream_idx.load(Ordering::Relaxed) == idx,
            };
            (*out_info).codec = m.codec_name;
            (*out_info).language = m.language;
            (*out_info).title = m.title;
            return true;
        }
        seen += 1;
    }
    false
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_chapter_count(player: *mut DKPlayer) -> c_int {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return 0 };
    let fmt = p.format_ctx.load(Ordering::Acquire);
    if fmt.is_null() {
        return 0;
    }
    let mut nb_ch = 0u32;
    dk_shim_format_summary(fmt, ptr::null_mut(), &mut nb_ch, ptr::null_mut(), ptr::null_mut());
    nb_ch as c_int
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_chapter_info(
    player: *mut DKPlayer,
    ordinal: c_int,
    out_info: *mut DKChapterInfo,
) -> bool {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return false };
    let fmt = p.format_ctx.load(Ordering::Acquire);
    if fmt.is_null() || out_info.is_null() || ordinal < 0 {
        return false;
    }
    dk_shim_get_chapter_info(fmt, ordinal as u32, out_info)
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_select_track(player: *mut DKPlayer, track_type: c_int, mut stream_index: c_int) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    let fmt = p.format_ctx.load(Ordering::Acquire);

    if track_type == 1 {
        if fmt.is_null() || stream_index < 0 {
            return;
        }
        let mut m = DKShimStreamMeta::default();
        if !dk_shim_get_stream_meta(fmt, stream_index as u32, &mut m) || m.codec_type != 1 {
            return;
        }
        if p.audio_stream_idx.load(Ordering::Acquire) == stream_index {
            return;
        }
        let cur_pts = p.get_master_clock().max(0.0);
        let Ok(mut ac) = p.audio_codec_mtx.lock() else { return };

        while p.audio_queue_starting.load(Ordering::Acquire) && !p.abort_requested.load(Ordering::Acquire) {
            thread::sleep(Duration::from_millis(1));
        }
        let aq = p.audio_queue_ptr.load(Ordering::Acquire);
        if !aq.is_null() {
            dk_shim_aq_stop_reset(aq);
            p.audio_queue_started.store(false, Ordering::Release);
        }
        if let Ok(mut apkts) = p.audio_pkt_mtx.lock() {
            for item in apkts.drain(..) {
                if let Some(pkt) = item {
                    p.queued_pkt_bytes.fetch_sub(pkt.size() as i64, Ordering::Relaxed);
                }
            }
        }
        if let Ok(mut ach) = p.audio_chunks_mtx.lock() {
            ach.clear();
        }
        p.buffered_audio_samples.store(0, Ordering::Release);
        p.clock.reset_to(cur_pts);
        if let Ok(mut vad) = p.vad_mtx.lock() {
            vad.clear();
        }

        let mut old_swr = ac.swr_ctx as *mut c_void;
        let mut old_ctx = ac.codec_ctx as *mut c_void;
        dk_shim_close_swr(&mut old_swr);
        dk_shim_close_codec(&mut old_ctx);
        *ac = AudioCodecState::default();

        let mut new_ctx: *mut c_void = ptr::null_mut();
        let mut new_swr: *mut c_void = ptr::null_mut();
        let mut s_fmt = -1;
        let mut s_rate = 0;
        let mut s_ch = 0;
        let mut dec_name = [0 as c_char; 32];
        if dk_shim_open_audio_decoder(
            fmt,
            stream_index,
            &mut new_ctx,
            &mut new_swr,
            &mut s_fmt,
            &mut s_rate,
            &mut s_ch,
            dec_name.as_mut_ptr(),
        ) == 0
            && !new_ctx.is_null()
        {
            p.audio_stream_idx.store(stream_index, Ordering::Release);
            ac.codec_ctx = new_ctx as usize;
            ac.swr_ctx = new_swr as usize;
            ac.swr_fmt = s_fmt;
            ac.swr_rate = s_rate;
            ac.swr_ch = s_ch;
            if p.audio_queue_ptr.load(Ordering::Acquire).is_null() {
                p.init_audio_queue();
            }
            if let Ok(mut st) = p.stats_mtx.lock() {
                st.audio_codec = dec_name;
            }
            let was_no_worker = p.workers_mtx.lock().map(|w| w.audio.is_none()).unwrap_or(false);
            if was_no_worker {
                let p_addr = player as usize;
                if let Ok(mut w) = p.workers_mtx.lock() {
                    w.audio = Some(thread::spawn(move || {
                        (*(p_addr as *const DKPlayer)).audio_decode_worker();
                    }));
                }
            }
        } else {
            p.audio_stream_idx.store(-1, Ordering::Release);
        }
        drop(ac);
        p.signal_seek_request(cur_pts, true);
    } else if track_type == 2 {
        if stream_index < 0 {
            stream_index = -1;
        }
        if stream_index >= 0 {
            if fmt.is_null() {
                return;
            }
            let mut m = DKShimStreamMeta::default();
            if !dk_shim_get_stream_meta(fmt, stream_index as u32, &mut m) || m.codec_type != 2 {
                emit_log(1, &format!("DKEngine: Ignored invalid subtitle stream index {stream_index}"));
                return;
            }
        }
        if stream_index >= 0 && p.sub_stream_idx.load(Ordering::Relaxed) == stream_index {
            return;
        }
        let cur_pts = p.get_master_clock().max(0.0);
        let (vw, vh) = p.stats_mtx.lock().map(|s| (s.width, s.height)).unwrap_or((0, 0));
        let mut is_bitmap = false;
        if let Ok(mut sub) = p.sub_mtx.lock() {
            p.sub_stream_idx.store(stream_index, Ordering::Release);
            sub.open_stream_decoder(fmt, stream_index, false, vw, vh);
            is_bitmap = sub.has_bitmap_subs;
        }
        if stream_index >= 0 {
            p.replay_sub_pkt_history(stream_index, false);
            let demux_ahead = load_f64(&p.last_demuxed_pts_bits) - cur_pts;
            if p.sub_hist_trimmed.load(Ordering::Relaxed) && (is_bitmap || demux_ahead > 2.0) {
                p.signal_seek_request(cur_pts, true);
            }
        } else {
            emit_log(0, "DKEngine: Subtitles disabled by user");
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_select_secondary_subtitle_track(player: *mut DKPlayer, mut stream_index: c_int) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    let fmt = p.format_ctx.load(Ordering::Acquire);
    if stream_index < 0 {
        stream_index = -1;
    }
    if stream_index >= 0 {
        if fmt.is_null() {
            return;
        }
        let mut m = DKShimStreamMeta::default();
        if !dk_shim_get_stream_meta(fmt, stream_index as u32, &mut m) || m.codec_type != 2 {
            emit_log(1, &format!("DKEngine: Ignored invalid secondary subtitle stream index {stream_index}"));
            return;
        }
        if p.secondary_sub_stream_idx.load(Ordering::Relaxed) == stream_index {
            return;
        }
    }
    let cur_pts = p.get_master_clock().max(0.0);
    let (vw, vh) = p.stats_mtx.lock().map(|s| (s.width, s.height)).unwrap_or((0, 0));
    if let Ok(mut sub) = p.sub_mtx.lock() {
        p.secondary_sub_stream_idx.store(stream_index, Ordering::Release);
        sub.secondary_time_scale = 1.0;
        sub.open_stream_decoder(fmt, stream_index, true, vw, vh);
    }
    if stream_index >= 0 {
        p.replay_sub_pkt_history(stream_index, true);
        let demux_ahead = load_f64(&p.last_demuxed_pts_bits) - cur_pts;
        if p.sub_hist_trimmed.load(Ordering::Relaxed) && demux_ahead > 2.0 {
            p.signal_seek_request(cur_pts, true);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_load_external_subtitle(
    player: *mut DKPlayer,
    content_utf8: *const c_char,
    is_ass: bool,
) {
    let guard = ReaderGuard::acquire(player);
    let (Some(p), false) = (guard.player, content_utf8.is_null()) else { return };
    let text = CStr::from_ptr(content_utf8).to_string_lossy();
    if let Ok(mut sub) = p.sub_mtx.lock() {
        p.sub_stream_idx.store(-1, Ordering::Release);
        sub.load_external_subtitle(&text, is_ass, false);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_load_secondary_external_subtitle(
    player: *mut DKPlayer,
    content_utf8: *const c_char,
    is_ass: bool,
) {
    let guard = ReaderGuard::acquire(player);
    let (Some(p), false) = (guard.player, content_utf8.is_null()) else { return };
    let text = CStr::from_ptr(content_utf8).to_string_lossy();
    if let Ok(mut sub) = p.sub_mtx.lock() {
        p.secondary_sub_stream_idx.store(-1, Ordering::Release);
        sub.load_external_subtitle(&text, is_ass, true);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_subtitle_style(
    player: *mut DKPlayer,
    config: *const DKSubtitleStyleConfig,
) {
    let guard = ReaderGuard::acquire(player);
    let (Some(p), Some(cfg)) = (guard.player, config.as_ref()) else { return };
    let has_pri = p.sub_stream_idx.load(Ordering::Relaxed) >= 0;
    let has_sec = p.secondary_sub_stream_idx.load(Ordering::Relaxed) >= 0;
    if let Ok(mut sub) = p.sub_mtx.lock() {
        sub.set_style(*cfg, has_pri, has_sec);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_subtitle_viewport(
    player: *mut DKPlayer,
    viewport_w: i32,
    viewport_h: i32,
    video_w: i32,
    video_h: i32,
    margin_top: i32,
    margin_bottom: i32,
    margin_left: i32,
    margin_right: i32,
) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    if let Ok(mut sub) = p.sub_mtx.lock() {
        sub.set_viewport(
            viewport_w,
            viewport_h,
            video_w,
            video_h,
            margin_top,
            margin_bottom,
            margin_left,
            margin_right,
        );
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_subtitle_vertical_bounds(
    player: *mut DKPlayer,
    out_y0: *mut i32,
    out_y1: *mut i32,
    out_canvas_h: *mut i32,
) -> bool {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return false };
    if out_y0.is_null() || out_y1.is_null() || out_canvas_h.is_null() {
        return false;
    }
    let Ok(sub) = p.sub_mtx.lock() else { return false };
    match sub.get_vertical_bounds() {
        Some((y0, y1, ch)) => {
            *out_y0 = y0;
            *out_y1 = y1;
            *out_canvas_h = ch;
            true
        }
        None => {
            *out_y0 = 0;
            *out_y1 = 0;
            *out_canvas_h = 0;
            false
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_copy_recent_audio_16k(
    player: *mut DKPlayer,
    out_pcm: *mut f32,
    max_samples: i32,
    out_start_pts: *mut f64,
) -> i32 {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return 0 };
    let Ok(vad) = p.vad_mtx.lock() else { return 0 };
    if out_pcm.is_null() || max_samples <= 0 {
        let (avail, start_pts) = vad.available_and_start_pts();
        if !out_start_pts.is_null() {
            *out_start_pts = start_pts;
        }
        return avail.min(i32::MAX as usize) as i32;
    }
    let buf = std::slice::from_raw_parts_mut(out_pcm, max_samples as usize);
    let (copied, start_pts) = vad.copy_recent(buf);
    if !out_start_pts.is_null() {
        *out_start_pts = start_pts;
    }
    copied as i32
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_subtitle_intervals(
    player: *mut DKPlayer,
    is_secondary: bool,
    out_intervals: *mut DKSubtitleInterval,
    max_count: i32,
) -> i32 {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return 0 };
    let Ok(sub) = p.sub_mtx.lock() else { return 0 };
    let items = sub.get_intervals(is_secondary);
    if out_intervals.is_null() || max_count <= 0 {
        return items.len().min(i32::MAX as usize) as i32;
    }
    let n = items.len().min(max_count as usize);
    if n > 0 {
        ptr::copy_nonoverlapping(items.as_ptr(), out_intervals, n);
    }
    n as i32
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_secondary_subtitle_time_scale(player: *mut DKPlayer, scale: f64) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    if let Ok(mut sub) = p.sub_mtx.lock() {
        sub.set_secondary_time_scale(scale);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_secondary_subtitle_time_scale(player: *mut DKPlayer) -> f64 {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return 1.0 };
    p.sub_mtx.lock().map(|s| s.secondary_time_scale).unwrap_or(1.0)
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_acquire_frame(
    player: *mut DKPlayer,
    out_pts: *mut f64,
    out_color: *mut DKGpuColorUniforms,
) -> CVPixelBufferRef {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return ptr::null_mut() };

    let aq = p.audio_queue_ptr.load(Ordering::Acquire);
    if p.get_state() == DKPlayerState::Playing
        && !p.is_seeking()
        && !p.demux_eof.load(Ordering::Relaxed)
        && !p.video_eof.load(Ordering::Relaxed)
        && !p.audio_eof.load(Ordering::Relaxed)
        && !p.audio_hal_disabled.load(Ordering::Relaxed)
        && p.buffered_audio_samples.load(Ordering::Relaxed) <= 0
        && p.clock.audio_consecutive_underrun_samples.load(Ordering::Relaxed) >= 4800
        && !aq.is_null()
        && !p.audio_queue_starting.load(Ordering::Acquire)
        && p.audio_queue_started.swap(false, Ordering::AcqRel)
    {
        let streak = p.audio_rebuffer_count.fetch_add(1, Ordering::Relaxed) + 1;
        if streak > 3 {
            p.audio_rebuffer_count.store(3, Ordering::Relaxed);
        }
        dk_shim_aq_stop_reset(aq);
        p.clock.audio_consecutive_underrun_samples.store(0, Ordering::Relaxed);
    }

    if p.get_state() == DKPlayerState::Playing
        && !p.is_seeking()
        && p.audio_stream_idx.load(Ordering::Relaxed) >= 0
        && !aq.is_null()
        && !p.audio_hal_disabled.load(Ordering::Acquire)
        && !p.audio_queue_started.load(Ordering::Acquire)
        && !p.audio_queue_starting.load(Ordering::Acquire)
        && p.buffered_audio_samples.load(Ordering::Relaxed) > 0
        && !p.audio_eof.load(Ordering::Relaxed)
    {
        p.audio_decode_cv.notify_one();
    }

    let master_pts = p.get_master_clock();

    let Ok(mut vq) = p.video_queue_mtx.lock() else { return ptr::null_mut() };
    if vq.frames.is_empty() {
        if p.video_eof.load(Ordering::Acquire)
            && p.demux_eof.load(Ordering::Acquire)
            && p.get_state() == DKPlayerState::Playing
        {
            let audio_done = p.audio_stream_idx.load(Ordering::Relaxed) < 0
                || (p.audio_eof.load(Ordering::Acquire) && p.buffered_audio_samples.load(Ordering::Relaxed) <= 0);
            if audio_done {
                p.state.store(DKPlayerState::Ended as i32, Ordering::Release);
            }
        }
        if let Some(ref lf) = vq.last_frame {
            if !out_pts.is_null() {
                *out_pts = vq.last_pts;
            }
            if !out_color.is_null() {
                *out_color = vq.last_color;
            }
            return lf.retain_raw();
        }
        return ptr::null_mut();
    }

    if p.audio_queue_started.load(Ordering::Relaxed) && p.audio_rebuffer_count.load(Ordering::Relaxed) > 0 {
        let steady_ns = p.audio_steady_start_ns.load(Ordering::Relaxed);
        if steady_ns > 0 && elapsed_since_ns(steady_ns) >= 15.0 {
            p.audio_rebuffer_count.store(0, Ordering::Relaxed);
        }
    }

    if vq.last_frame.is_none() && !vq.frames.is_empty() {
        let audio_expected = p.get_state() == DKPlayerState::Playing
            && p.audio_stream_idx.load(Ordering::Relaxed) >= 0
            && !aq.is_null()
            && !p.audio_hal_disabled.load(Ordering::Acquire)
            && !p.audio_queue_started.load(Ordering::Acquire)
            && !p.audio_eof.load(Ordering::Relaxed)
            && !p.demux_eof.load(Ordering::Relaxed);
        let silent_fallback = vq.frames.len() >= 10 && p.buffered_audio_samples.load(Ordering::Relaxed) <= 0;
        if audio_expected && !silent_fallback {
            return ptr::null_mut();
        }
        p.force_present_next_frame.store(false, Ordering::Release);
        let front = vq.frames.pop_front().unwrap();
        let ret_pb = front.pixbuf.retain_raw();
        vq.last_pts = front.pts;
        vq.last_color = front.color;
        vq.last_frame = Some(front.pixbuf);
        store_f64(&p.clock.current_pos_bits, vq.last_pts);
        p.video_frame_cv.notify_one();

        if !out_pts.is_null() {
            *out_pts = vq.last_pts;
        }
        if !out_color.is_null() {
            *out_color = vq.last_color;
        }
        emit_log(
            0,
            &format!(
                "DKEngine: First video frame presented smoothly (PTS: {:.3}s, audio_started={})",
                vq.last_pts,
                i32::from(p.audio_queue_started.load(Ordering::Relaxed))
            ),
        );
        return ret_pb;
    }

    if p.force_present_next_frame.load(Ordering::Acquire) && !vq.frames.is_empty() {
        let wait_audio = p.get_state() == DKPlayerState::Playing
            && p.audio_stream_idx.load(Ordering::Relaxed) >= 0
            && !aq.is_null()
            && !p.audio_hal_disabled.load(Ordering::Acquire)
            && !p.audio_queue_started.load(Ordering::Acquire)
            && !p.audio_eof.load(Ordering::Relaxed)
            && !p.demux_eof.load(Ordering::Relaxed);
        if !wait_audio && p.force_present_next_frame.swap(false, Ordering::AcqRel) {
            let front = vq.frames.pop_front().unwrap();
            let ret_pb = front.pixbuf.retain_raw();
            vq.last_pts = front.pts;
            vq.last_color = front.color;
            vq.last_frame = Some(front.pixbuf);
            let now_ns = steady_now_ns();
            store_f64(&p.clock.current_pos_bits, vq.last_pts);
            store_f64(&p.clock.ext_clock_base_pts_bits, vq.last_pts);
            p.clock.ext_clock_start_ns.store(now_ns, Ordering::Relaxed);
            if !p.audio_queue_started.load(Ordering::Acquire) {
                store_f64(&p.clock.audio_clock_base_pts_bits, vq.last_pts);
                store_f64(&p.clock.fallback_audio_clock_bits, vq.last_pts);
                p.clock.fallback_clock_ns.store(now_ns, Ordering::Relaxed);
            }
            p.video_frame_cv.notify_one();

            if !out_pts.is_null() {
                *out_pts = vq.last_pts;
            }
            if !out_color.is_null() {
                *out_color = vq.last_color;
            }
            return ret_pb;
        }
    }

    if p.audio_stream_idx.load(Ordering::Relaxed) >= 0
        && !aq.is_null()
        && !p.audio_hal_disabled.load(Ordering::Acquire)
        && !p.audio_queue_started.load(Ordering::Acquire)
        && !p.audio_eof.load(Ordering::Relaxed)
    {
        if let Some(ref lf) = vq.last_frame {
            if !out_pts.is_null() {
                *out_pts = vq.last_pts;
            }
            if !out_color.is_null() {
                *out_color = vq.last_color;
            }
            return lf.retain_raw();
        }
        return ptr::null_mut();
    }

    while !vq.frames.is_empty() {
        let diff = vq.frames[0].pts - master_pts;
        if diff < -0.08 && vq.frames.len() > 1 {
            vq.frames.pop_front();
            p.video_frame_cv.notify_one();
            continue;
        }
        if diff <= 0.015 {
            let front = vq.frames.pop_front().unwrap();
            vq.last_pts = front.pts;
            vq.last_color = front.color;
            vq.last_frame = Some(front.pixbuf);
            store_f64(&p.clock.current_pos_bits, vq.last_pts);
            p.video_frame_cv.notify_one();
            break;
        }
        break;
    }

    if let Some(ref lf) = vq.last_frame {
        if !out_pts.is_null() {
            *out_pts = vq.last_pts;
        }
        if !out_color.is_null() {
            *out_color = vq.last_color;
        }
        return lf.retain_raw();
    }
    ptr::null_mut()
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_sync_subtitle_rgba(
    player: *mut DKPlayer,
    pts: f64,
    canvas_w: i32,
    canvas_h: i32,
    last_serial: u64,
    callback: DKSubtitleRgbaCallback,
    context: *mut c_void,
) {
    let guard = ReaderGuard::acquire(player);
    let (Some(p), Some(cb)) = (guard.player, callback) else { return };
    if canvas_w <= 0 || canvas_h <= 0 {
        return;
    }
    let Ok(mut sub) = p.sub_mtx.lock() else { return };
    let (has_sub, rgba_ptr, w, h, serial) = sub.update_subtitle_rgba(pts, canvas_w, canvas_h);
    if serial != last_serial {
        cb(
            if has_sub { rgba_ptr } else { ptr::null() },
            if has_sub { w } else { 0 },
            if has_sub { h } else { 0 },
            serial,
            context,
        );
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_state(player: *mut DKPlayer) -> DKPlayerState {
    let guard = ReaderGuard::acquire(player);
    guard.player.map(|p| p.get_state()).unwrap_or(DKPlayerState::Idle)
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_position(player: *mut DKPlayer) -> f64 {
    let guard = ReaderGuard::acquire(player);
    guard.player.map(|p| p.get_master_clock()).unwrap_or(0.0)
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_duration(player: *mut DKPlayer) -> f64 {
    let guard = ReaderGuard::acquire(player);
    guard.player.map(|p| load_f64(&p.duration_bits)).unwrap_or(0.0)
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_buffered_duration(player: *mut DKPlayer) -> f64 {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return 0.0 };
    let cur_pts = p.get_master_clock().max(0.0);
    let dur = load_f64(&p.duration_bits);
    if p.demux_eof.load(Ordering::Relaxed) && dur > cur_pts {
        return dur - cur_pts;
    }
    let video_q_sec = p
        .video_queue_mtx
        .lock()
        .ok()
        .and_then(|vq| vq.frames.back().map(|f| (f.pts - cur_pts).max(0.0)))
        .unwrap_or(0.0);
    let demux_ahead_sec = (load_f64(&p.last_demuxed_pts_bits) - cur_pts).max(0.0);
    let queued_bytes = p.queued_pkt_bytes.load(Ordering::Relaxed).max(0) as f64;
    let measured_mbps = load_f64(&p.atomic_video_bitrate_bits);
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

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_stats(player: *mut DKPlayer, out_stats: *mut DKRuntimeStats) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    if out_stats.is_null() {
        return;
    }
    let total_bytes = p.get_total_bytes_read();
    let speed_mbs = p.speed_mtx.lock().map(|mut sp| sp.sample(total_bytes)).unwrap_or(0.0);
    let cached = p.queued_pkt_bytes.load(Ordering::Relaxed).max(0);
    if let Ok(st) = p.stats_mtx.lock() {
        *out_stats = *st;
        (*out_stats).cached_bytes = cached;
        (*out_stats).total_bytes_read = total_bytes;
        (*out_stats).download_speed_mbs = speed_mbs;
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_extract_video_thumbnail(
    file_path_or_url: *const c_char,
    target_sec: f64,
) -> CGImageRef {
    if file_path_or_url.is_null() {
        return ptr::null_mut();
    }
    let raw = CStr::from_ptr(file_path_or_url).to_string_lossy();
    let path = normalize_path_or_url(&raw);
    let Ok(cpath) = CString::new(path) else { return ptr::null_mut() };
    dk_shim_extract_thumbnail(cpath.as_ptr(), target_sec)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_redaction_strips_host_and_query_secrets() {
        assert_eq!(
            redact_url_for_log("https://secret.example.com:8443/emby/videos/123/stream.mkv?api_key=TOPSECRET"),
            "https://<HOST>/emby/videos/123/stream.mkv?<REDACTED>"
        );
        assert_eq!(
            normalize_path_or_url("file:///Users/don/%E6%B5%8B%E8%AF%95.mkv"),
            "/Users/don/测试.mkv"
        );
    }
}
