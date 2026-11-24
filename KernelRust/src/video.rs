use crate::abi::{CGImageRef, CVPixelBufferRef, DKGpuColorUniforms, DKPlayerState};
use crate::clock::{elapsed_since_ns, load_f64, steady_now_ns, store_f64};
use crate::ffi::{
    dk_shim_aq_stop_reset, dk_shim_close_codec, dk_shim_extract_thumbnail, dk_shim_is_eagain,
    dk_shim_is_eof, dk_shim_open_video_decoder, dk_shim_process_video_frame,
    dk_shim_receive_frame, dk_shim_send_packet, dk_shim_unref_hw_ctx, AvFrame, OwnedPixelBuffer,
};
use crate::player::{DKPlayer, VideoFrameEntry};
use crate::{emit_log, normalize_path_or_url};
use std::ffi::{c_char, c_void, CString};
use std::ptr;
use std::sync::atomic::Ordering;
use std::thread;
use std::time::Duration;

pub(crate) unsafe extern "C" fn is_vt_failed_thunk(opaque: *mut c_void) -> bool {
    if opaque.is_null() {
        return false;
    }
    let p = &*(opaque as *const DKPlayer);
    p.vt_failed.load(Ordering::Relaxed)
}

pub(crate) unsafe extern "C" fn on_sw_format_selected_thunk(opaque: *mut c_void) {
    if opaque.is_null() {
        return;
    }
    let p = &*(opaque as *const DKPlayer);
    if let Ok(mut st) = p.stats_mtx.lock() {
        st.is_hw_accelerated = false;
    }
}

pub(crate) unsafe fn extract_video_thumbnail(raw_url: &str, target_sec: f64) -> CGImageRef {
    let path = normalize_path_or_url(raw_url);
    let Ok(cpath) = CString::new(path) else { return ptr::null_mut() };
    dk_shim_extract_thumbnail(cpath.as_ptr(), target_sec)
}

impl DKPlayer {
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

    pub(crate) fn video_decode_worker(&self) {
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

    // CRITICAL (CVDisplayLink thread purity): Only acquire leaf `video_queue_mtx`, check
    // `audio_queue_starting` non-blockingly, and nudge `audio_decode_cv.notify_one()`.
    // NEVER call `try_start_audio_queue_if_ready` or `AudioQueueStart` on this thread.
    pub(crate) unsafe fn acquire_frame(
        &self,
        out_pts: *mut f64,
        out_color: *mut DKGpuColorUniforms,
    ) -> CVPixelBufferRef {
        let aq = self.audio_queue_ptr.load(Ordering::Acquire);
        if self.get_state() == DKPlayerState::Playing
            && !self.is_seeking()
            && !self.demux_eof.load(Ordering::Relaxed)
            && !self.video_eof.load(Ordering::Relaxed)
            && !self.audio_eof.load(Ordering::Relaxed)
            && !self.audio_hal_disabled.load(Ordering::Relaxed)
            && self.buffered_audio_samples.load(Ordering::Relaxed) <= 0
            && self.clock.audio_consecutive_underrun_samples.load(Ordering::Relaxed) >= 4800
            && !aq.is_null()
            && !self.audio_queue_starting.load(Ordering::Acquire)
            && self.audio_queue_started.swap(false, Ordering::AcqRel)
        {
            let streak = self.audio_rebuffer_count.fetch_add(1, Ordering::Relaxed) + 1;
            if streak > 3 {
                self.audio_rebuffer_count.store(3, Ordering::Relaxed);
            }
            dk_shim_aq_stop_reset(aq);
            self.clock.audio_consecutive_underrun_samples.store(0, Ordering::Relaxed);
        }

        if self.get_state() == DKPlayerState::Playing
            && !self.is_seeking()
            && self.audio_stream_idx.load(Ordering::Relaxed) >= 0
            && !aq.is_null()
            && !self.audio_hal_disabled.load(Ordering::Acquire)
            && !self.audio_queue_started.load(Ordering::Acquire)
            && !self.audio_queue_starting.load(Ordering::Acquire)
            && self.buffered_audio_samples.load(Ordering::Relaxed) > 0
            && !self.audio_eof.load(Ordering::Relaxed)
        {
            self.audio_decode_cv.notify_one();
        }

        let master_pts = self.get_master_clock();

        let Ok(mut vq) = self.video_queue_mtx.lock() else { return ptr::null_mut() };
        if vq.frames.is_empty() {
            if self.video_eof.load(Ordering::Acquire)
                && self.demux_eof.load(Ordering::Acquire)
                && self.get_state() == DKPlayerState::Playing
            {
                let audio_done = self.audio_stream_idx.load(Ordering::Relaxed) < 0
                    || (self.audio_eof.load(Ordering::Acquire) && self.buffered_audio_samples.load(Ordering::Relaxed) <= 0);
                if audio_done {
                    self.state.store(DKPlayerState::Ended as i32, Ordering::Release);
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

        if self.audio_queue_started.load(Ordering::Relaxed) && self.audio_rebuffer_count.load(Ordering::Relaxed) > 0 {
            let steady_ns = self.audio_steady_start_ns.load(Ordering::Relaxed);
            if steady_ns > 0 && elapsed_since_ns(steady_ns) >= 15.0 {
                self.audio_rebuffer_count.store(0, Ordering::Relaxed);
            }
        }

        if vq.last_frame.is_none() && !vq.frames.is_empty() {
            let audio_expected = self.get_state() == DKPlayerState::Playing
                && self.audio_stream_idx.load(Ordering::Relaxed) >= 0
                && !aq.is_null()
                && !self.audio_hal_disabled.load(Ordering::Acquire)
                && !self.audio_queue_started.load(Ordering::Acquire)
                && !self.audio_eof.load(Ordering::Relaxed)
                && !self.demux_eof.load(Ordering::Relaxed);
            let silent_fallback = vq.frames.len() >= 10 && self.buffered_audio_samples.load(Ordering::Relaxed) <= 0;
            if audio_expected && !silent_fallback {
                return ptr::null_mut();
            }
            self.force_present_next_frame.store(false, Ordering::Release);
            let front = vq.frames.pop_front().unwrap();
            let ret_pb = front.pixbuf.retain_raw();
            vq.last_pts = front.pts;
            vq.last_color = front.color;
            vq.last_frame = Some(front.pixbuf);
            store_f64(&self.clock.current_pos_bits, vq.last_pts);
            self.video_frame_cv.notify_one();

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
                    i32::from(self.audio_queue_started.load(Ordering::Relaxed))
                ),
            );
            return ret_pb;
        }

        if self.force_present_next_frame.load(Ordering::Acquire) && !vq.frames.is_empty() {
            let wait_audio = self.get_state() == DKPlayerState::Playing
                && self.audio_stream_idx.load(Ordering::Relaxed) >= 0
                && !aq.is_null()
                && !self.audio_hal_disabled.load(Ordering::Acquire)
                && !self.audio_queue_started.load(Ordering::Acquire)
                && !self.audio_eof.load(Ordering::Relaxed)
                && !self.demux_eof.load(Ordering::Relaxed);
            if !wait_audio && self.force_present_next_frame.swap(false, Ordering::AcqRel) {
                let front = vq.frames.pop_front().unwrap();
                let ret_pb = front.pixbuf.retain_raw();
                vq.last_pts = front.pts;
                vq.last_color = front.color;
                vq.last_frame = Some(front.pixbuf);
                let now_ns = steady_now_ns();
                store_f64(&self.clock.current_pos_bits, vq.last_pts);
                store_f64(&self.clock.ext_clock_base_pts_bits, vq.last_pts);
                self.clock.ext_clock_start_ns.store(now_ns, Ordering::Relaxed);
                if !self.audio_queue_started.load(Ordering::Acquire) {
                    store_f64(&self.clock.audio_clock_base_pts_bits, vq.last_pts);
                    store_f64(&self.clock.fallback_audio_clock_bits, vq.last_pts);
                    self.clock.fallback_clock_ns.store(now_ns, Ordering::Relaxed);
                }
                self.video_frame_cv.notify_one();

                if !out_pts.is_null() {
                    *out_pts = vq.last_pts;
                }
                if !out_color.is_null() {
                    *out_color = vq.last_color;
                }
                return ret_pb;
            }
        }

        if self.audio_stream_idx.load(Ordering::Relaxed) >= 0
            && !aq.is_null()
            && !self.audio_hal_disabled.load(Ordering::Acquire)
            && !self.audio_queue_started.load(Ordering::Acquire)
            && !self.audio_eof.load(Ordering::Relaxed)
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
                self.video_frame_cv.notify_one();
                continue;
            }
            if diff <= 0.015 {
                let front = vq.frames.pop_front().unwrap();
                vq.last_pts = front.pts;
                vq.last_color = front.color;
                vq.last_frame = Some(front.pixbuf);
                store_f64(&self.clock.current_pos_bits, vq.last_pts);
                self.video_frame_cv.notify_one();
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
}
