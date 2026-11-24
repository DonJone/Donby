pub mod abi;
pub mod dovi;
pub mod vad;

use abi::*;
use std::ffi::{c_char, c_int, c_void, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicPtr, AtomicU64, Ordering};
use std::sync::Mutex;
use vad::VadAudioRing;

extern "C" {
    fn dk_shim_install_ffmpeg_log_bridge();
}

static LOG_CALLBACK: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());

pub(crate) fn emit_log(level: c_int, msg: &str) {
    let raw = LOG_CALLBACK.load(Ordering::Acquire);
    if raw.is_null() {
        return;
    }
    if let Ok(cstr) = CString::new(msg) {
        // SAFETY: `raw` was stored from a valid `unsafe extern "C" fn(c_int, *const c_char)`.
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

#[repr(C)]
pub struct DKPlayer {
    state: AtomicI32,
    abort_requested: AtomicBool,
    seeking: AtomicBool,
    duration_bits: AtomicU64,
    position_bits: AtomicU64,
    buffered_bits: AtomicU64,
    rate_bits: AtomicI32,
    volume_bits: AtomicI32,
    muted: AtomicBool,
    max_buffer_bytes: AtomicI64,
    secondary_time_scale_bits: AtomicU64,
    custom_io: Mutex<CustomIoSlot>,
    sub_style: Mutex<DKSubtitleStyleConfig>,
    sub_viewport: Mutex<SubtitleViewport>,
    vad_ring: Mutex<VadAudioRing>,
    stats: Mutex<DKRuntimeStats>,
}

#[derive(Copy, Clone, Default)]
struct CustomIoSlot {
    opaque: usize,
    read_cb: DKCustomIOReadCallback,
    seek_cb: DKCustomIOSeekCallback,
    abort_cb: DKCustomIOAbortCallback,
    close_cb: DKCustomIOCloseCallback,
}

#[allow(dead_code)]
#[derive(Copy, Clone, Default)]
struct SubtitleViewport {
    viewport_w: i32,
    viewport_h: i32,
    video_w: i32,
    video_h: i32,
    margin_top: i32,
    margin_bottom: i32,
    margin_left: i32,
    margin_right: i32,
}

impl Default for DKPlayer {
    fn default() -> Self {
        Self {
            state: AtomicI32::new(DKPlayerState::Idle as i32),
            abort_requested: AtomicBool::new(false),
            seeking: AtomicBool::new(false),
            duration_bits: AtomicU64::new(0.0f64.to_bits()),
            position_bits: AtomicU64::new(0.0f64.to_bits()),
            buffered_bits: AtomicU64::new(0.0f64.to_bits()),
            rate_bits: AtomicI32::new(1.0f32.to_bits() as i32),
            volume_bits: AtomicI32::new(1.0f32.to_bits() as i32),
            muted: AtomicBool::new(false),
            max_buffer_bytes: AtomicI64::new(256 * 1024 * 1024),
            secondary_time_scale_bits: AtomicU64::new(1.0f64.to_bits()),
            custom_io: Mutex::new(CustomIoSlot::default()),
            sub_style: Mutex::new(DKSubtitleStyleConfig::default()),
            sub_viewport: Mutex::new(SubtitleViewport::default()),
            vad_ring: Mutex::new(VadAudioRing::default()),
            stats: Mutex::new(DKRuntimeStats::default()),
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_set_log_callback(callback: DKLogCallback) {
    let ptr = callback.map(|f| f as *mut c_void).unwrap_or(ptr::null_mut());
    LOG_CALLBACK.store(ptr, Ordering::Release);
    dk_shim_install_ffmpeg_log_bridge();
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_create() -> *mut DKPlayer {
    Box::into_raw(Box::new(DKPlayer::default()))
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_destroy(player: *mut DKPlayer) {
    if player.is_null() {
        return;
    }
    dk_player_close(player);
    drop(Box::from_raw(player));
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_open_with_tracks(
    player: *mut DKPlayer,
    _url: *const c_char,
    _headers_crlf: *const c_char,
    start_sec: f64,
    _hw_decode: bool,
    _preferred_audio_idx: i32,
    _preferred_sub_idx: i32,
) -> c_int {
    let Some(p) = player.as_ref() else { return -1 };
    p.abort_requested.store(false, Ordering::Release);
    p.position_bits.store(start_sec.max(0.0).to_bits(), Ordering::Release);
    p.state.store(DKPlayerState::Error as i32, Ordering::Release);
    // shortcut: Phase-0 scaffold stub; Phase 1 implements FFmpeg demux + VideoToolbox open (see ADR-003).
    emit_log(1, "[KernelRust] Phase-0 scaffold active: dk_player_open_with_tracks pending Phase 1");
    -38
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
    let Some(p) = player.as_ref() else { return };
    p.abort_requested.store(true, Ordering::Release);
    if let Ok(io) = p.custom_io.lock() {
        if let (Some(abort_cb), op) = (io.abort_cb, io.opaque as *mut c_void) {
            if !op.is_null() {
                abort_cb(op);
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_close(player: *mut DKPlayer) {
    let Some(p) = player.as_ref() else { return };
    p.abort_requested.store(true, Ordering::Release);
    if let Ok(mut io) = p.custom_io.lock() {
        if let (Some(close_cb), op) = (io.close_cb, io.opaque as *mut c_void) {
            if !op.is_null() {
                close_cb(op);
            }
        }
        *io = CustomIoSlot::default();
    }
    if let Ok(mut ring) = p.vad_ring.lock() {
        ring.clear();
    }
    p.state.store(DKPlayerState::Idle as i32, Ordering::Release);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_play(player: *mut DKPlayer) {
    let Some(p) = player.as_ref() else { return };
    if p.state.load(Ordering::Acquire) == DKPlayerState::Paused as i32 {
        p.state.store(DKPlayerState::Playing as i32, Ordering::Release);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_pause(player: *mut DKPlayer) {
    let Some(p) = player.as_ref() else { return };
    if p.state.load(Ordering::Acquire) == DKPlayerState::Playing as i32 {
        p.state.store(DKPlayerState::Paused as i32, Ordering::Release);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_seek(player: *mut DKPlayer, target_sec: f64, _accurate: bool) {
    let Some(p) = player.as_ref() else { return };
    p.position_bits.store(target_sec.max(0.0).to_bits(), Ordering::Release);
    if let Ok(mut ring) = p.vad_ring.lock() {
        ring.clear();
    }
    // shortcut: Phase-0 scaffold stub; Phase 2 implements seek epoch + AudioQueue/FFmpeg flush.
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_should_yield_read(player: *mut DKPlayer) -> bool {
    let Some(p) = player.as_ref() else { return false };
    p.abort_requested.load(Ordering::Acquire) || p.seeking.load(Ordering::Acquire)
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_rate(player: *mut DKPlayer, rate: f32) {
    let Some(p) = player.as_ref() else { return };
    p.rate_bits.store(rate.clamp(0.25, 4.0).to_bits() as i32, Ordering::Release);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_volume(player: *mut DKPlayer, volume: f32, muted: bool) {
    let Some(p) = player.as_ref() else { return };
    p.volume_bits.store(volume.clamp(0.0, 2.0).to_bits() as i32, Ordering::Release);
    p.muted.store(muted, Ordering::Release);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_buffer_limit_mb(player: *mut DKPlayer, limit_mb: i32) {
    let Some(p) = player.as_ref() else { return };
    let clamped = (limit_mb.clamp(32, 4096) as i64) * 1024 * 1024;
    p.max_buffer_bytes.store(clamped, Ordering::Release);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_track_count(_player: *mut DKPlayer, _track_type: c_int) -> c_int {
    0
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_track_info(
    _player: *mut DKPlayer,
    _track_type: c_int,
    _ordinal: c_int,
    _out_info: *mut DKTrackInfo,
) -> bool {
    false
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_select_track(
    _player: *mut DKPlayer,
    _track_type: c_int,
    _stream_index: c_int,
) {
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_load_external_subtitle(
    _player: *mut DKPlayer,
    _content_utf8: *const c_char,
    _is_ass: bool,
) {
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_subtitle_style(
    player: *mut DKPlayer,
    config: *const DKSubtitleStyleConfig,
) {
    let (Some(p), Some(cfg)) = (player.as_ref(), config.as_ref()) else { return };
    if let Ok(mut guard) = p.sub_style.lock() {
        *guard = *cfg;
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
    let Some(p) = player.as_ref() else { return };
    if let Ok(mut vp) = p.sub_viewport.lock() {
        *vp = SubtitleViewport {
            viewport_w,
            viewport_h,
            video_w,
            video_h,
            margin_top,
            margin_bottom,
            margin_left,
            margin_right,
        };
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_select_secondary_subtitle_track(
    _player: *mut DKPlayer,
    _stream_index: c_int,
) {
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_load_secondary_external_subtitle(
    _player: *mut DKPlayer,
    _content_utf8: *const c_char,
    _is_ass: bool,
) {
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_subtitle_vertical_bounds(
    _player: *mut DKPlayer,
    _out_y0: *mut i32,
    _out_y1: *mut i32,
    _out_canvas_h: *mut i32,
) -> bool {
    false
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_copy_recent_audio_16k(
    player: *mut DKPlayer,
    out_pcm: *mut f32,
    max_samples: i32,
    out_start_pts: *mut f64,
) -> i32 {
    let Some(p) = player.as_ref() else { return 0 };
    if out_pcm.is_null() || max_samples <= 0 {
        return 0;
    }
    let Ok(ring) = p.vad_ring.lock() else { return 0 };
    let buf = std::slice::from_raw_parts_mut(out_pcm, max_samples as usize);
    let (copied, start_pts) = ring.copy_recent(buf);
    if !out_start_pts.is_null() {
        *out_start_pts = start_pts;
    }
    copied as i32
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_subtitle_intervals(
    _player: *mut DKPlayer,
    _is_secondary: bool,
    _out_intervals: *mut DKSubtitleInterval,
    _max_count: i32,
) -> i32 {
    0
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_secondary_subtitle_time_scale(player: *mut DKPlayer, scale: f64) {
    let Some(p) = player.as_ref() else { return };
    let clamped = if scale.is_finite() { scale.clamp(0.5, 2.0) } else { 1.0 };
    p.secondary_time_scale_bits.store(clamped.to_bits(), Ordering::Release);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_secondary_subtitle_time_scale(player: *mut DKPlayer) -> f64 {
    let Some(p) = player.as_ref() else { return 1.0 };
    f64::from_bits(p.secondary_time_scale_bits.load(Ordering::Acquire))
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_chapter_count(_player: *mut DKPlayer) -> c_int {
    0
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_chapter_info(
    _player: *mut DKPlayer,
    _ordinal: c_int,
    _out_info: *mut DKChapterInfo,
) -> bool {
    false
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_acquire_frame(
    _player: *mut DKPlayer,
    _out_pts: *mut f64,
    out_color: *mut DKGpuColorUniforms,
) -> CVPixelBufferRef {
    if !out_color.is_null() {
        *out_color = DKGpuColorUniforms::default_sdr();
    }
    ptr::null_mut()
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_sync_subtitle_rgba(
    _player: *mut DKPlayer,
    _pts: f64,
    _canvas_w: i32,
    _canvas_h: i32,
    _last_serial: u64,
    _callback: DKSubtitleRgbaCallback,
    _context: *mut c_void,
) {
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_state(player: *mut DKPlayer) -> DKPlayerState {
    let Some(p) = player.as_ref() else { return DKPlayerState::Idle };
    match p.state.load(Ordering::Acquire) {
        1 => DKPlayerState::Opening,
        2 => DKPlayerState::Buffering,
        3 => DKPlayerState::Playing,
        4 => DKPlayerState::Paused,
        5 => DKPlayerState::Ended,
        6 => DKPlayerState::Error,
        _ => DKPlayerState::Idle,
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_position(player: *mut DKPlayer) -> f64 {
    let Some(p) = player.as_ref() else { return 0.0 };
    f64::from_bits(p.position_bits.load(Ordering::Acquire))
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_duration(player: *mut DKPlayer) -> f64 {
    let Some(p) = player.as_ref() else { return 0.0 };
    f64::from_bits(p.duration_bits.load(Ordering::Acquire))
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_buffered_duration(player: *mut DKPlayer) -> f64 {
    let Some(p) = player.as_ref() else { return 0.0 };
    f64::from_bits(p.buffered_bits.load(Ordering::Acquire))
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_stats(player: *mut DKPlayer, out_stats: *mut DKRuntimeStats) {
    if out_stats.is_null() {
        return;
    }
    if let Some(p) = player.as_ref() {
        if let Ok(st) = p.stats.lock() {
            *out_stats = *st;
            return;
        }
    }
    *out_stats = DKRuntimeStats::default();
}

#[no_mangle]
pub unsafe extern "C" fn dk_extract_video_thumbnail(
    _file_path_or_url: *const c_char,
    _target_sec: f64,
) -> CGImageRef {
    // shortcut: Phase-0 scaffold stub; Phase 1 implements FFmpeg keyframe seek + CGImage extraction.
    ptr::null_mut()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn player_lifecycle_and_secondary_scale_round_trip() {
        unsafe {
            let p = dk_player_create();
            assert!(!p.is_null());
            assert_eq!(dk_player_get_state(p), DKPlayerState::Idle);
            assert_eq!(dk_player_get_secondary_subtitle_time_scale(p), 1.0);
            dk_player_set_secondary_subtitle_time_scale(p, 25.0 / 23.976);
            assert!((dk_player_get_secondary_subtitle_time_scale(p) - (25.0 / 23.976)).abs() < 1e-9);
            dk_player_destroy(p);
        }
    }
}
