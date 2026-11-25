use crate::abi::{
    cchar_array_to_string, write_str_to_cchar, DKCustomIOAbortCallback, DKCustomIOCloseCallback,
    DKCustomIOReadCallback, DKCustomIOSeekCallback, DKPlayerState, DKRuntimeStats,
};
use crate::clock::{steady_now_ns, store_f64};
use crate::ffi::{
    dk_shim_alloc_hw_fmt_ctx, dk_shim_averror_eio, dk_shim_averror_enosys, dk_shim_averror_eof,
    dk_shim_averror_exit, dk_shim_close_codec, dk_shim_close_format, dk_shim_close_swr,
    dk_shim_format_summary, dk_shim_free_hw_fmt_ctx, dk_shim_get_stream_meta,
    dk_shim_install_ffmpeg_log_bridge, dk_shim_is_hevc_stream, dk_shim_open_audio_decoder,
    dk_shim_open_format, dk_shim_open_video_decoder, dk_shim_reclaim_memory,
    dk_shim_release_sw_video_res, dk_shim_seek_format, dk_shim_unref_hw_ctx, ffmpeg_err_string,
    DKShimStreamMeta,
};
use crate::player::{AudioCodecState, CustomIoSlot, DKPlayer, SwVideoState, MAX_CACHED_STREAM_TYPES};
use crate::tracks::score_auto_subtitle_stream;
use crate::video::{is_vt_failed_thunk, on_sw_format_selected_thunk};
use crate::{emit_log, live_players, normalize_path_or_url, redact_url_for_log};
use std::ffi::{c_char, c_int, c_void, CString};
use std::ptr;
use std::sync::atomic::Ordering;
use std::thread;
use std::time::Duration;

pub(crate) unsafe extern "C" fn interrupt_callback_thunk(opaque: *mut c_void) -> c_int {
    if opaque.is_null() {
        return 0;
    }
    let p = &*(opaque as *const DKPlayer);
    i32::from(p.abort_requested.load(Ordering::Acquire) || p.is_closing.load(Ordering::Acquire))
}

pub(crate) unsafe extern "C" fn avio_read_thunk(
    opaque: *mut c_void,
    buf: *mut u8,
    buf_size: c_int,
) -> c_int {
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

pub(crate) unsafe extern "C" fn avio_seek_thunk(
    opaque: *mut c_void,
    offset: i64,
    whence: c_int,
) -> i64 {
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

pub(crate) unsafe fn create_raw() -> *mut DKPlayer {
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

pub(crate) unsafe fn destroy_raw(player: *mut DKPlayer) {
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
    (*player).abort_custom_io();
    while (*player).in_flight_readers.load(Ordering::Acquire) > 0 {
        thread::sleep(Duration::from_micros(200));
    }
    (*player).close_session();

    let mut hw_opaque = (*player).hw_fmt_ctx_opaque.swap(ptr::null_mut(), Ordering::AcqRel);
    dk_shim_free_hw_fmt_ctx(&mut hw_opaque);

    drop(Box::from_raw(player));
    dk_shim_reclaim_memory();
}

pub(crate) unsafe fn request_abort_raw(player: *mut DKPlayer) {
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
    p.abort_custom_io();
    p.demux_cv.notify_all();
    p.video_decode_cv.notify_all();
    p.audio_decode_cv.notify_all();
    p.video_frame_cv.notify_all();
}

impl DKPlayer {
    pub(crate) unsafe fn abort_custom_io(&self) {
        if let Ok(io) = self.custom_io.lock() {
            if let (Some(abort_cb), op) = (io.abort_cb, io.opaque as *mut c_void) {
                if !op.is_null() {
                    abort_cb(op);
                }
            }
        }
    }

    pub(crate) unsafe fn close_custom_io(&self) {
        if let Ok(mut io) = self.custom_io.lock() {
            if let (Some(close_cb), op) = (io.close_cb, io.opaque as *mut c_void) {
                if !op.is_null() {
                    close_cb(op);
                }
            }
            *io = CustomIoSlot::default();
        }
    }

    pub(crate) fn set_custom_io(
        &self,
        opaque: *mut c_void,
        read_cb: DKCustomIOReadCallback,
        seek_cb: DKCustomIOSeekCallback,
        abort_cb: DKCustomIOAbortCallback,
        close_cb: DKCustomIOCloseCallback,
    ) {
        if let Ok(mut io) = self.custom_io.lock() {
            io.opaque = opaque as usize;
            io.read_cb = read_cb;
            io.seek_cb = seek_cb;
            io.abort_cb = abort_cb;
            io.close_cb = close_cb;
        }
    }

    pub(crate) unsafe fn open_with_tracks(
        &self,
        raw_url: &str,
        headers_crlf: *const c_char,
        start_sec: f64,
        hw_decode: bool,
        preferred_audio_hint: i32,
        preferred_sub_hint: i32,
    ) -> i32 {
        if self.external_abort_requested.load(Ordering::SeqCst) {
            self.state.store(DKPlayerState::Error as i32, Ordering::Release);
            return -1;
        }

        // Preserve any pending custom IO registered prior to open across close_session
        let saved_io = self.custom_io.lock().map(|mut g| std::mem::take(&mut *g)).unwrap_or_default();
        self.close_session();
        if let Ok(mut g) = self.custom_io.lock() {
            *g = saved_io;
        }

        if self.external_abort_requested.load(Ordering::SeqCst) {
            self.close_custom_io();
            self.state.store(DKPlayerState::Error as i32, Ordering::Release);
            return -1;
        }

        let normalized_url = normalize_path_or_url(raw_url);
        let Ok(open_target_c) = CString::new(normalized_url.as_str()) else { return -1 };
        let is_local_file = normalized_url.starts_with('/');
        let (use_custom_io, has_seek_cb) = self
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
        self.startup_timing.reset(steady_now_ns());

        self.state.store(DKPlayerState::Opening as i32, Ordering::Release);
        self.is_closing.store(false, Ordering::Release);
        self.hw_decode_enabled.store(hw_decode, Ordering::Release);
        self.is_local_file.store(is_local_file, Ordering::Release);
        self.has_custom_io.store(use_custom_io, Ordering::Release);
        self.video_is_hevc.store(false, Ordering::Release);
        self.video_width.store(0, Ordering::Release);
        self.video_height.store(0, Ordering::Release);
        store_f64(&self.atomic_video_fps_bits, 24.0);
        for slot in &self.stream_types {
            slot.store(-1, Ordering::Relaxed);
        }
        self.vt_failed.store(false, Ordering::Release);
        self.dovi_detected.store(false, Ordering::Release);
        self.stream_dovi_profile.store(0, Ordering::Release);
        self.demux_eof.store(false, Ordering::Release);
        self.video_eof.store(false, Ordering::Release);
        self.audio_eof.store(false, Ordering::Release);
        store_f64(&self.video_seek_drop_bits, -1.0);
        store_f64(&self.audio_seek_drop_bits, -1.0);
        self.video_skip_nonref_active.store(false, Ordering::Release);
        self.queued_pkt_bytes.store(0, Ordering::Release);
        self.video_pkt_count.store(0, Ordering::Release);
        self.audio_pkt_count.store(0, Ordering::Release);
        self.total_bytes_read.store(0, Ordering::Release);
        self.clear_sub_pkt_history();
        self.clear_audio_pkt_history();
        self.audio_rebuffer_count.store(0, Ordering::Release);
        self.audio_start_fail_count.store(0, Ordering::Release);
        self.last_audio_start_attempt_ns.store(0, Ordering::Release);
        self.audio_steady_start_ns.store(0, Ordering::Release);
        self.audio_hal_disabled.store(false, Ordering::Release);
        store_f64(&self.last_demuxed_pts_bits, start_sec.max(0.0));
        store_f64(&self.last_decoded_pts_bits, -1.0);
        if let Ok(mut vq) = self.video_queue_mtx.lock() {
            vq.last_decoded_pts = -1.0;
        }
        self.abort_requested.store(false, Ordering::SeqCst);
        if self.external_abort_requested.load(Ordering::SeqCst) {
            self.abort_requested.store(true, Ordering::SeqCst);
            self.close_custom_io();
            self.state.store(DKPlayerState::Error as i32, Ordering::Release);
            return -1;
        }
        self.seek_requested.store(false, Ordering::Release);
        self.seek_preview_pending.store(false, Ordering::Release);
        self.force_present_next_frame.store(false, Ordering::Release);
        self.video_stream_idx.store(-1, Ordering::Release);
        self.audio_stream_idx.store(-1, Ordering::Release);
        self.sub_stream_idx.store(-1, Ordering::Release);
        self.secondary_sub_stream_idx.store(-1, Ordering::Release);
        if let Ok(mut st) = self.stats_mtx.lock() {
            *st = DKRuntimeStats::default();
        }

        let is_mpeg_ts = normalized_url.contains(".ts") || normalized_url.contains(".m2ts");
        let mut fmt_ctx: *mut c_void = ptr::null_mut();
        let mut custom_avio: *mut c_void = ptr::null_mut();
        let mut open_ms = -1.0f64;
        let mut probe_ms = -1.0f64;
        let open_ret = dk_shim_open_format(
            open_target_c.as_ptr(),
            headers_crlf,
            is_local_file,
            start_sec > 0.5,
            is_mpeg_ts,
            use_custom_io,
            has_seek_cb,
            self as *const Self as *mut c_void,
            interrupt_callback_thunk,
            avio_read_thunk,
            avio_seek_thunk,
            &mut fmt_ctx,
            &mut custom_avio,
            &mut open_ms,
            &mut probe_ms,
        );
        if open_ms >= 0.0 {
            self.startup_timing.open_ms.store(open_ms.round() as i64, Ordering::Release);
        }
        if probe_ms >= 0.0 {
            self.startup_timing.probe_ms.store(probe_ms.round() as i64, Ordering::Release);
        }

        if open_ret < 0
            || fmt_ctx.is_null()
            || self.abort_requested.load(Ordering::SeqCst)
            || self.external_abort_requested.load(Ordering::SeqCst)
        {
            emit_log(
                2,
                &format!("DKEngine Error: open/probe failed ({}: {})", open_ret, ffmpeg_err_string(open_ret)),
            );
            dk_shim_close_format(&mut fmt_ctx, &mut custom_avio);
            self.close_custom_io();
            self.state.store(DKPlayerState::Error as i32, Ordering::Release);
            return -1;
        }

        self.format_ctx.store(fmt_ctx, Ordering::Release);
        self.custom_avio_ctx.store(custom_avio, Ordering::Release);

        let mut nb_streams = 0u32;
        let mut nb_chapters = 0u32;
        let mut duration_sec = 0.0f64;
        let mut fmt_bitrate = 0i64;
        dk_shim_format_summary(fmt_ctx, &mut nb_streams, &mut nb_chapters, &mut duration_sec, &mut fmt_bitrate);
        store_f64(&self.duration_bits, duration_sec);

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
            if (i as usize) < MAX_CACHED_STREAM_TYPES {
                self.stream_types[i as usize].store(m.codec_type as i8, Ordering::Relaxed);
            }
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
            if m.codec_type == 0 && self.video_stream_idx.load(Ordering::Relaxed) < 0 && !m.disp_attached_pic {
                if m.dovi_profile > 0 {
                    self.stream_dovi_profile.store(m.dovi_profile, Ordering::Release);
                    self.dovi_detected.store(true, Ordering::Release);
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
                    self.hw_fmt_ctx_opaque.load(Ordering::Acquire),
                    &mut v_ctx,
                    &mut hw_ctx,
                    &mut is_hw,
                    dec_name.as_mut_ptr(),
                );
                if vrc < 0 && hw_decode {
                    self.vt_failed.store(true, Ordering::Release);
                    vrc = dk_shim_open_video_decoder(
                        fmt_ctx,
                        idx,
                        false,
                        sw_threads,
                        self.hw_fmt_ctx_opaque.load(Ordering::Acquire),
                        &mut v_ctx,
                        &mut hw_ctx,
                        &mut is_hw,
                        dec_name.as_mut_ptr(),
                    );
                }
                if vrc == 0 && !v_ctx.is_null() {
                    self.video_stream_idx.store(idx, Ordering::Release);
                    if let Ok(mut vc) = self.video_codec_mtx.lock() {
                        vc.0 = v_ctx as usize;
                        vc.1 = hw_ctx as usize;
                    }
                    opened_video_w = m.width;
                    opened_video_h = m.height;
                    self.video_width.store(m.width, Ordering::Release);
                    self.video_height.store(m.height, Ordering::Release);
                    store_f64(&self.atomic_video_fps_bits, if m.fps > 1.0 { m.fps } else { 24.0 });
                    self.video_is_hevc.store(dk_shim_is_hevc_stream(fmt_ctx, idx), Ordering::Release);
                    let br_mbps = if m.bit_rate > 0 {
                        (m.bit_rate as f64) / 1_000_000.0
                    } else if fmt_bitrate > 0 {
                        (fmt_bitrate as f64) / 1_000_000.0
                    } else {
                        0.0
                    };
                    store_f64(&self.atomic_video_bitrate_bits, br_mbps);

                    if let Ok(mut st) = self.stats_mtx.lock() {
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
                && self.audio_stream_idx.load(Ordering::Relaxed) < 0
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
                    self.audio_stream_idx.store(idx, Ordering::Release);
                    if let Ok(mut ac) = self.audio_codec_mtx.lock() {
                        ac.codec_ctx = a_ctx as usize;
                        ac.swr_ctx = swr_p as usize;
                        ac.swr_fmt = s_fmt;
                        ac.swr_rate = s_rate;
                        ac.swr_ch = s_ch;
                    }
                    if let Ok(mut st) = self.stats_mtx.lock() {
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
                && self.sub_stream_idx.load(Ordering::Relaxed) < 0
                && !disable_auto_sub
                && (preferred_sub_idx < 0 || idx == preferred_sub_idx)
            {
                self.sub_stream_idx.store(idx, Ordering::Release);
            }
        }

        // AudioQueue initialization (CoreAudio HAL IPC, ~60-90ms cold) runs asynchronously
        // at the top of `audio_decode_worker` in parallel with demux & VideoToolbox cold init.
        if let Ok(mut sub) = self.sub_mtx.lock() {
            let sub_idx = self.sub_stream_idx.load(Ordering::Relaxed);
            if sub_idx >= 0 {
                sub.open_stream_decoder(fmt_ctx, sub_idx, false, opened_video_w, opened_video_h);
            } else {
                sub.ensure_default_primary_track();
            }
        }

        if start_sec > 0.5 {
            let _ = dk_shim_seek_format(fmt_ctx, start_sec, false);
            store_f64(&self.video_seek_drop_bits, -1.0);
            store_f64(&self.audio_seek_drop_bits, -1.0);
            self.force_present_next_frame.store(true, Ordering::Release);
            self.clock.reset_to(start_sec);
        } else {
            self.clock.reset_to(0.0);
        }

        if self.abort_requested.load(Ordering::SeqCst) || self.external_abort_requested.load(Ordering::SeqCst) {
            self.state.store(DKPlayerState::Error as i32, Ordering::Release);
            return -1;
        }

        let p_addr = self as *const Self as usize;
        let has_video = self.video_codec_mtx.lock().map(|vc| vc.0 != 0).unwrap_or(false);
        let has_audio = self.audio_codec_mtx.lock().map(|ac| ac.codec_ctx != 0).unwrap_or(false);

        self.startup_timing
            .workers_start_ns
            .store(steady_now_ns(), Ordering::Release);
        if let Ok(mut workers) = self.workers_mtx.lock() {
            workers.demux = Some(thread::spawn(move || {
                (*(p_addr as *const DKPlayer)).demux_worker();
            }));
            if has_video {
                workers.video = Some(thread::spawn(move || {
                    (*(p_addr as *const DKPlayer)).video_decode_worker();
                }));
            }
            if has_audio {
                workers.audio = Some(thread::spawn(move || {
                    (*(p_addr as *const DKPlayer)).audio_decode_worker();
                }));
            }
        }

        self.state.store(DKPlayerState::Playing as i32, Ordering::Release);
        0
    }

    pub(crate) unsafe fn close_session(&self) {
        // 1. Atomic is_closing CAS
        if self
            .is_closing
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }
        // 2. Signal abort + custom_io abort_cb
        self.abort_requested.store(true, Ordering::Release);
        self.abort_custom_io();

        // 3. Drain in_flight_readers
        while self.in_flight_readers.load(Ordering::Acquire) > 0 {
            thread::sleep(Duration::from_micros(200));
        }

        // 4. Wake condvars + join demux/video/audio workers
        self.demux_cv.notify_all();
        self.video_decode_cv.notify_all();
        self.audio_decode_cv.notify_all();
        self.video_frame_cv.notify_all();

        let (d_th, v_th, a_th) = if let Ok(mut w) = self.workers_mtx.lock() {
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

        // 5. Stop/dispose AudioQueue (after audio_queue_starting clears)
        self.stop_dispose_audio_queue();

        // 6. Clear packet/frame/audio/vad queues and release backing capacities
        if let Ok(mut vpkts) = self.video_pkt_mtx.lock() {
            vpkts.clear();
            vpkts.shrink_to_fit();
        }
        self.video_pkt_count.store(0, Ordering::Relaxed);
        if let Ok(mut apkts) = self.audio_pkt_mtx.lock() {
            apkts.clear();
            apkts.shrink_to_fit();
        }
        self.audio_pkt_count.store(0, Ordering::Relaxed);
        self.queued_pkt_bytes.store(0, Ordering::Relaxed);
        self.clear_sub_pkt_history();
        self.clear_audio_pkt_history();

        if let Ok(mut vq) = self.video_queue_mtx.lock() {
            vq.frames.clear();
            vq.frames.shrink_to_fit();
            vq.last_frame = None;
        }
        if let Ok(mut ach) = self.audio_chunks_mtx.lock() {
            ach.clear();
            ach.shrink_to_fit();
        }
        self.buffered_audio_samples.store(0, Ordering::Relaxed);
        if let Ok(mut vad) = self.vad_mtx.lock() {
            vad.clear();
        }

        // 7. Close codecs/swr/sws/pool/subtitle
        if let Ok(mut ac) = self.audio_codec_mtx.lock() {
            let mut swr = ac.swr_ctx as *mut c_void;
            let mut actx = ac.codec_ctx as *mut c_void;
            dk_shim_close_swr(&mut swr);
            dk_shim_close_codec(&mut actx);
            *ac = AudioCodecState::default();
        }
        if let Ok(mut sw) = self.sw_video_mtx.lock() {
            let mut sws = sw.sws as *mut c_void;
            let mut pool = sw.pool as *mut c_void;
            dk_shim_release_sw_video_res(&mut sws, &mut pool);
            *sw = SwVideoState::default();
        }
        if let Ok(mut sub) = self.sub_mtx.lock() {
            sub.close_stream_state();
        }
        if let Ok(mut vc) = self.video_codec_mtx.lock() {
            let mut vctx = vc.0 as *mut c_void;
            let mut hw = vc.1 as *mut c_void;
            dk_shim_close_codec(&mut vctx);
            dk_shim_unref_hw_ctx(&mut hw);
            *vc = (0, 0);
        }

        // 8. Close format_ctx/custom_avio + custom_io close_cb
        let mut fmt = self.format_ctx.swap(ptr::null_mut(), Ordering::AcqRel);
        let mut custom_avio = self.custom_avio_ctx.swap(ptr::null_mut(), Ordering::AcqRel);
        dk_shim_close_format(&mut fmt, &mut custom_avio);
        self.close_custom_io();

        // 9. Reset stream indices, reclaim freed malloc pages, and set state to Idle
        self.video_stream_idx.store(-1, Ordering::Release);
        self.audio_stream_idx.store(-1, Ordering::Release);
        self.sub_stream_idx.store(-1, Ordering::Release);
        self.secondary_sub_stream_idx.store(-1, Ordering::Release);
        self.video_width.store(0, Ordering::Relaxed);
        self.video_height.store(0, Ordering::Relaxed);
        store_f64(&self.atomic_video_bitrate_bits, 0.0);
        self.audio_queue_started.store(false, Ordering::Release);
        self.state.store(DKPlayerState::Idle as i32, Ordering::Release);
        dk_shim_reclaim_memory();
    }
}
