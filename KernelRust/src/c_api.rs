#[path = "subtitle/async_worker.rs"]
mod sub_async_worker;

use crate::abi::{
    CGImageRef, CVPixelBufferRef, DKChapterInfo, DKCustomIOAbortCallback, DKCustomIOCloseCallback,
    DKCustomIOReadCallback, DKCustomIOSeekCallback, DKGpuColorUniforms, DKLogCallback,
    DKPlayerState, DKRuntimeStats, DKSubtitleInterval, DKSubtitleRgbaCallback,
    DKSubtitleStyleConfig, DKTrackInfo,
};
use crate::clock::load_f64;
use crate::ffi::dk_shim_install_ffmpeg_log_bridge;
use crate::lifecycle::{create_raw, destroy_raw, request_abort_raw};
use crate::player::DKPlayer;
use crate::video::extract_video_thumbnail;
use crate::{set_log_callback_ptr, ReaderGuard};
use std::ffi::{c_char, c_int, c_void, CStr};
use std::ptr;
use std::sync::atomic::Ordering;

#[no_mangle]
pub unsafe extern "C" fn dk_set_log_callback(callback: DKLogCallback) {
    let p = callback.map(|f| f as *mut c_void).unwrap_or(ptr::null_mut());
    set_log_callback_ptr(p);
    dk_shim_install_ffmpeg_log_bridge();
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_create() -> *mut DKPlayer {
    create_raw()
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_destroy(player: *mut DKPlayer) {
    sub_async_worker::shutdown(player);
    destroy_raw(player);
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
    p.set_custom_io(opaque, read_cb, seek_cb, abort_cb, close_cb);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_request_abort(player: *mut DKPlayer) {
    request_abort_raw(player);
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
    let raw_url = CStr::from_ptr(url).to_string_lossy();
    let rc = p.open_with_tracks(
        &raw_url,
        headers_crlf,
        start_sec,
        hw_decode,
        preferred_audio_hint,
        preferred_sub_hint,
    );
    if rc == 0 {
        sub_async_worker::start_and_prewarm(player);
    }
    rc
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_close(player: *mut DKPlayer) {
    sub_async_worker::shutdown(player);
    let Some(p) = player.as_ref() else { return };
    p.close_session();
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_play(player: *mut DKPlayer) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    p.play();
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_pause(player: *mut DKPlayer) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    p.pause();
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_seek(player: *mut DKPlayer, target_sec: f64, accurate: bool) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    p.signal_seek_request(target_sec, accurate);
    sub_async_worker::nudge(player);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_rate(player: *mut DKPlayer, rate: f32) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    p.set_rate(rate);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_volume(player: *mut DKPlayer, volume: f32, muted: bool) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    p.set_volume(volume, muted);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_set_buffer_limit_mb(player: *mut DKPlayer, limit_mb: i32) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    p.set_buffer_limit_mb(limit_mb);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_track_count(player: *mut DKPlayer, track_type: c_int) -> c_int {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return 0 };
    p.get_track_count(track_type)
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
    p.get_track_info(track_type, ordinal, out_info)
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_chapter_count(player: *mut DKPlayer) -> c_int {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return 0 };
    p.get_chapter_count()
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_chapter_info(
    player: *mut DKPlayer,
    ordinal: c_int,
    out_info: *mut DKChapterInfo,
) -> bool {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return false };
    p.get_chapter_info(ordinal, out_info)
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_select_track(
    player: *mut DKPlayer,
    track_type: c_int,
    stream_index: c_int,
) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    p.select_track(track_type, stream_index);
    if track_type == 2 {
        sub_async_worker::nudge(player);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_select_secondary_subtitle_track(
    player: *mut DKPlayer,
    stream_index: c_int,
) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    p.select_secondary_subtitle_track(stream_index);
    sub_async_worker::nudge(player);
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
    sub_async_worker::nudge(player);
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
    sub_async_worker::nudge(player);
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
    sub_async_worker::nudge(player);
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
    sub_async_worker::nudge(player);
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
    let bounds = if let Some(ready_bounds) = sub_async_worker::get_vertical_bounds(player) {
        ready_bounds
    } else {
        let Ok(sub) = p.sub_mtx.lock() else { return false };
        sub.get_vertical_bounds()
    };
    match bounds {
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
pub unsafe extern "C" fn dk_player_set_secondary_subtitle_time_scale(
    player: *mut DKPlayer,
    scale: f64,
) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    if let Ok(mut sub) = p.sub_mtx.lock() {
        sub.set_secondary_time_scale(scale);
    }
    sub_async_worker::nudge(player);
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
    p.acquire_frame(out_pts, out_color)
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_notify_metal_first_frame(player: *mut DKPlayer) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    if p.startup_timing
        .metal_first_frame_reported
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_ok()
    {
        let open_start = p.startup_timing.open_start_ns.load(Ordering::Acquire);
        let metal_ms = if open_start > 0 {
            ((crate::clock::steady_now_ns() - open_start).max(0)) / 1_000_000
        } else {
            -1
        };
        crate::emit_log(0, &p.startup_timing.format_summary(metal_ms));
    }
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
    let (Some(_p), Some(cb)) = (guard.player, callback) else { return };
    if canvas_w <= 0 || canvas_h <= 0 {
        return;
    }
    sub_async_worker::sync_subtitle_rgba(player, pts, canvas_w, canvas_h, last_serial, Some(cb), context);
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_state(player: *mut DKPlayer) -> DKPlayerState {
    let guard = ReaderGuard::acquire(player);
    guard.player.map(|p| p.get_state()).unwrap_or(DKPlayerState::Idle)
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_is_seeking(player: *const DKPlayer) -> bool {
    let guard = ReaderGuard::acquire(player as *mut DKPlayer);
    guard.player.is_some_and(|p| p.is_seeking())
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
    guard.player.map(|p| p.get_buffered_duration()).unwrap_or(0.0)
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_get_stats(
    player: *mut DKPlayer,
    out_stats: *mut DKRuntimeStats,
) {
    let guard = ReaderGuard::acquire(player);
    let Some(p) = guard.player else { return };
    if let Some(st) = out_stats.as_mut() {
        p.get_stats(st);
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
    extract_video_thumbnail(&raw, target_sec)
}
