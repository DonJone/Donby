use crate::abi::DKPlayerState;
use crate::clock::{elapsed_since_ns, load_f64, steady_now_ns, store_f64};
use crate::emit_log;
use crate::ffi::{
    dk_shim_aq_commit_and_enqueue, dk_shim_aq_create, dk_shim_aq_fill_and_enqueue,
    dk_shim_aq_get_sample_time, dk_shim_aq_pause, dk_shim_aq_prime_and_start,
    dk_shim_aq_reset_only, dk_shim_aq_set_rate, dk_shim_aq_set_volume, dk_shim_aq_start_only,
    dk_shim_aq_stop_dispose, dk_shim_aq_stop_reset, dk_shim_audio_frame_convert,
    dk_shim_audio_frame_prepare, dk_shim_is_eagain, dk_shim_is_eof, dk_shim_receive_frame,
    dk_shim_send_packet, AvFrame,
};
use crate::player::{AudioChunk, AudioStartingGuard, DKPlayer};
use std::ffi::c_void;
use std::ptr;
use std::sync::atomic::Ordering;
use std::time::Duration;

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

impl DKPlayer {
    pub(crate) unsafe fn stop_reset_audio_queue(&self) {
        while self.audio_queue_starting.load(Ordering::Acquire) {
            std::thread::yield_now();
        }
        if self.audio_queue_started.swap(false, Ordering::AcqRel) {
            let aq = self.audio_queue_ptr.load(Ordering::Acquire);
            if !aq.is_null() {
                dk_shim_aq_stop_reset(aq);
            }
        }
    }

    pub(crate) unsafe fn stop_dispose_audio_queue(&self) {
        let mut aq = self.audio_queue_ptr.swap(ptr::null_mut(), Ordering::AcqRel);
        let mut tr = self.audio_trampoline_ptr.swap(ptr::null_mut(), Ordering::AcqRel);
        if !aq.is_null() || !tr.is_null() {
            while self.audio_queue_starting.load(Ordering::Acquire) {
                std::thread::yield_now();
            }
            dk_shim_aq_stop_dispose(&mut aq, &mut tr);
        }
        if let Ok(mut bufs) = self.audio_buffers.lock() {
            *bufs = [ptr::null_mut(); 4];
        }
    }

    pub(crate) fn get_audio_clock(&self) -> f64 {
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

    pub(crate) fn get_master_clock(&self) -> f64 {
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

    pub(crate) fn init_audio_queue(&self) -> bool {
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
        let is_local = self.is_local_file.load(Ordering::Relaxed) && !self.has_custom_io.load(Ordering::Relaxed);
        match self.audio_rebuffer_count.load(Ordering::Relaxed) {
            0 => if is_local { 6_144 } else { 12_000 },
            1 => 84_000,
            _ => 120_000,
        }
    }

    pub(crate) fn try_start_audio_queue_if_ready(&self) {
        if self.abort_requested.load(Ordering::Acquire)
            || self.is_closing.load(Ordering::Acquire)
            || self.audio_queue_ptr.load(Ordering::Acquire).is_null()
            || self.audio_hal_disabled.load(Ordering::Acquire)
            || self.audio_queue_started.load(Ordering::Acquire)
            || self.is_seeking()
        {
            return;
        }
        // During an accurate seek, let video finish fast-forwarding to target_sec before starting audio.
        if load_f64(&self.video_seek_drop_bits) > 0.0 && !self.video_eof.load(Ordering::Relaxed) {
            return;
        }
        let buffered = self.buffered_audio_samples.load(Ordering::Relaxed);
        let eof_reached = self.audio_eof.load(Ordering::Relaxed) || self.demux_eof.load(Ordering::Relaxed);
        let rebuf = self.audio_rebuffer_count.load(Ordering::Relaxed);
        if buffered < self.required_audio_preroll_samples() && !eof_reached {
            return;
        }
        let is_local = self.is_local_file.load(Ordering::Relaxed) && !self.has_custom_io.load(Ordering::Relaxed);
        let solo_samples = match rebuf {
            0 => if is_local { 18_000 } else { 24_000 },
            1 => 96_000,
            _ => 144_000,
        };
        let mut video_ready = self.video_stream_idx.load(Ordering::Relaxed) < 0
            || self.video_eof.load(Ordering::Relaxed)
            || eof_reached
            || buffered >= solo_samples;
        if !video_ready {
            let max_vf = self.max_video_frames();
            if let Ok(vq) = self.video_queue_mtx.lock() {
                let min_frames = if rebuf >= 2 {
                    max_vf
                } else if rebuf == 1 {
                    4.min(max_vf)
                } else if self.force_present_next_frame.load(Ordering::Relaxed) {
                    1
                } else {
                    2.min(max_vf)
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
                    emit_log(
                        2,
                        &format!("DKEngine Error: AudioQueueStart returned OSStatus {status} (attempt {fails})"),
                    );
                }
                if fails >= 6 {
                    self.audio_hal_disabled.store(true, Ordering::Release);
                    let fb_pts = load_f64(&self.clock.current_pos_bits).max(0.0);
                    store_f64(&self.clock.ext_clock_base_pts_bits, fb_pts);
                    self.clock.ext_clock_start_ns.store(steady_now_ns(), Ordering::Relaxed);
                    emit_log(
                        1,
                        "DKEngine: Falling back to system presentation clock after repeated AudioQueueStart errors",
                    );
                }
            }
        } else {
            unsafe { dk_shim_aq_reset_only(aq) };
            self.audio_queue_started.store(false, Ordering::Release);
        }
    }

    pub(crate) fn audio_decode_worker(&self) {
        let Some(mut frame) = AvFrame::alloc() else { return };

        // Initialize AudioQueue asynchronously here (off open_with_tracks critical path)
        // so CoreAudio HAL setup overlaps with demux and VideoToolbox cold init.
        if self.audio_queue_ptr.load(Ordering::Acquire).is_null()
            && !self.abort_requested.load(Ordering::Acquire)
            && !self.is_closing.load(Ordering::Acquire)
        {
            let has_audio_swr = self
                .audio_codec_mtx
                .lock()
                .map(|ac| ac.codec_ctx != 0 && ac.swr_ctx != 0)
                .unwrap_or(false);
            if has_audio_swr {
                self.init_audio_queue();
            }
        }

        // Reusable scratch buffers & small-frame coalescer (avoids 1,200 allocs/sec on TrueHD 7.1)
        let mut scratch_pcm: Vec<f32> = Vec::with_capacity(4096);
        let mut scratch_vad: Vec<f32> = Vec::with_capacity(2048);
        let mut coal_pcm: Vec<f32> = Vec::with_capacity(4096);
        let mut coal_vad: Vec<f32> = Vec::with_capacity(2048);
        let mut coal_pts: f64 = 0.0;
        let mut coal_has_pts: bool = false;

        let flush_coalesced = |this: &Self,
                               c_pcm: &mut Vec<f32>,
                               c_vad: &mut Vec<f32>,
                               c_pts: f64,
                               c_has_pts: bool| {
            if c_pcm.is_empty() {
                return;
            }
            let samples = (c_pcm.len() / 2) as i64;
            if let Ok(mut vad) = this.vad_mtx.lock() {
                vad.push_mono_48k(c_vad, c_pts, c_has_pts);
            }
            let out_pcm = std::mem::replace(c_pcm, Vec::with_capacity(4096));
            c_vad.clear();
            if let Ok(mut ach) = this.audio_chunks_mtx.lock() {
                ach.push_back(AudioChunk {
                    pcm: out_pcm,
                    pts: c_pts,
                    read_offset: 0,
                });
                this.buffered_audio_samples.fetch_add(samples, Ordering::Relaxed);
            }
            if !this.audio_queue_started.load(Ordering::Relaxed) {
                this.try_start_audio_queue_if_ready();
            }
        };

        while !self.abort_requested.load(Ordering::Acquire) {
            if self.is_seeking() {
                coal_pcm.clear();
                coal_vad.clear();
                if let Ok(lk) = self.audio_pkt_mtx.lock() {
                    let _ = self.audio_decode_cv.wait_timeout_while(lk, Duration::from_millis(15), |_| {
                        !self.abort_requested.load(Ordering::Acquire) && self.is_seeking()
                    });
                }
                continue;
            }

            if self.get_state() == DKPlayerState::Paused {
                flush_coalesced(self, &mut coal_pcm, &mut coal_vad, coal_pts, coal_has_pts);
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
                coal_pcm.clear();
                coal_vad.clear();
                if let Ok(mut ach) = self.audio_chunks_mtx.lock() {
                    ach.clear();
                }
                self.buffered_audio_samples.store(0, Ordering::Relaxed);
            }

            if self.buffered_audio_samples.load(Ordering::Relaxed) > 160_000 {
                flush_coalesced(self, &mut coal_pcm, &mut coal_vad, coal_pts, coal_has_pts);
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
                    drop(lk);
                    flush_coalesced(self, &mut coal_pcm, &mut coal_vad, coal_pts, coal_has_pts);
                    let Ok(lk2) = self.audio_pkt_mtx.lock() else { continue };
                    let mut lk = lk2;
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
                    self.audio_pkt_count.store(lk.len(), Ordering::Relaxed);
                    if let Some(ref p) = item {
                        self.queued_pkt_bytes.fetch_sub(p.size() as i64, Ordering::Relaxed);
                    }
                    item
                } else {
                    let item = lk.pop_front().unwrap();
                    self.audio_pkt_count.store(lk.len(), Ordering::Relaxed);
                    if let Some(ref p) = item {
                        self.queued_pkt_bytes.fetch_sub(p.size() as i64, Ordering::Relaxed);
                    }
                    item
                }
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
                    flush_coalesced(self, &mut coal_pcm, &mut coal_vad, coal_pts, coal_has_pts);
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
                    coal_pcm.clear();
                    coal_vad.clear();
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

                let need_stereo = (max_out as usize) * 2;
                if scratch_pcm.len() < need_stereo {
                    scratch_pcm.resize(need_stereo, 0.0);
                }
                if scratch_vad.len() < max_out as usize {
                    scratch_vad.resize(max_out as usize, 0.0);
                }
                let converted = unsafe {
                    dk_shim_audio_frame_convert(
                        frame.0,
                        swr_p,
                        scratch_pcm.as_mut_ptr(),
                        max_out,
                        scratch_vad.as_mut_ptr(),
                    )
                };
                if converted > 0 {
                    let conv = converted as usize;
                    if coal_pcm.is_empty() {
                        coal_pts = pts;
                        coal_has_pts = has_pts;
                    }
                    coal_pcm.extend_from_slice(&scratch_pcm[..conv * 2]);
                    coal_vad.extend_from_slice(&scratch_vad[..conv]);
                    let should_flush = coal_pcm.len() >= 2048
                        || !self.audio_queue_started.load(Ordering::Relaxed)
                        || self.audio_pkt_count.load(Ordering::Relaxed) == 0;
                    if should_flush {
                        flush_coalesced(self, &mut coal_pcm, &mut coal_vad, coal_pts, coal_has_pts);
                    }
                }
                frame.unref();
            }
        }
    }

    pub(crate) unsafe fn play(&self) {
        let st = self.get_state();
        if matches!(st, DKPlayerState::Paused | DKPlayerState::Ended) {
            self.state.store(DKPlayerState::Playing as i32, Ordering::Release);
            let aq = self.audio_queue_ptr.load(Ordering::Acquire);
            if !aq.is_null() && self.audio_queue_started.load(Ordering::Acquire) {
                let _ = dk_shim_aq_start_only(aq);
            }
            let now_ns = steady_now_ns();
            self.clock.ext_clock_start_ns.store(now_ns, Ordering::Relaxed);
            self.clock.fallback_clock_ns.store(now_ns, Ordering::Relaxed);
            self.video_decode_cv.notify_all();
            self.audio_decode_cv.notify_all();
        }
    }

    pub(crate) unsafe fn pause(&self) {
        if self.get_state() == DKPlayerState::Playing {
            let cur = self.get_master_clock();
            self.state.store(DKPlayerState::Paused as i32, Ordering::Release);
            let aq = self.audio_queue_ptr.load(Ordering::Acquire);
            if !aq.is_null() && self.audio_queue_started.load(Ordering::Acquire) {
                dk_shim_aq_pause(aq);
            }
            store_f64(&self.clock.ext_clock_base_pts_bits, cur);
            store_f64(&self.clock.fallback_audio_clock_bits, cur);
        }
    }

    pub(crate) unsafe fn set_rate(&self, rate: f32) {
        let cur = self.get_master_clock();
        let clamped = rate.clamp(0.25, 4.0);
        self.rate_bits.store(clamped.to_bits(), Ordering::Release);
        let aq = self.audio_queue_ptr.load(Ordering::Acquire);
        if !aq.is_null() {
            dk_shim_aq_set_rate(aq, clamped);
        }
        let now_ns = steady_now_ns();
        store_f64(&self.clock.ext_clock_base_pts_bits, cur);
        self.clock.ext_clock_start_ns.store(now_ns, Ordering::Relaxed);
        store_f64(&self.clock.fallback_audio_clock_bits, cur);
        self.clock.fallback_clock_ns.store(now_ns, Ordering::Relaxed);
    }

    pub(crate) unsafe fn set_volume(&self, volume: f32, muted: bool) {
        self.volume_bits.store(volume.clamp(0.0, 2.0).to_bits(), Ordering::Release);
        self.is_muted.store(muted, Ordering::Release);
        let aq = self.audio_queue_ptr.load(Ordering::Acquire);
        if !aq.is_null() {
            dk_shim_aq_set_volume(aq, self.effective_volume());
        }
    }
}
