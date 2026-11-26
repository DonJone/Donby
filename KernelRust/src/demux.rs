use crate::abi::DKPlayerState;
use crate::clock::{load_f64, steady_now_ns, store_f64};
use crate::dovi::check_dovi_rpu_or_el;
use crate::emit_log;
use crate::ffi::{
    dk_shim_avio_bytes_read, dk_shim_avio_retry_reseek, dk_shim_clear_avio_error,
    dk_shim_flush_codec, dk_shim_get_stream_meta, dk_shim_is_eagain, dk_shim_is_eof,
    dk_shim_read_frame, dk_shim_seek_format, dk_shim_set_codec_skip_nonref, ffmpeg_err_string,
    AvPacket, DKShimStreamMeta,
};
use crate::player::{
    AudioHistPacket, DKPlayer, QueuedVideoPacket, SeekScopeGuard, MAX_CACHED_STREAM_TYPES,
};
use std::ffi::c_void;
use std::ptr;
use std::sync::atomic::Ordering;
use std::thread;
use std::time::Duration;

enum SeekOutcome {
    Completed,
    Superseded,
    Aborted,
}

impl DKPlayer {
    unsafe fn execute_pending_seek(&self, fmt: *mut c_void, my_seek_seq: u64) -> SeekOutcome {
        let target_sec = load_f64(&self.seek_target_bits);
        let accurate = self.seek_accurate.load(Ordering::Acquire);

        self.executing_seek_seq.store(my_seek_seq, Ordering::Release);
        self.seek_executing.store(true, Ordering::Release);
        self.seek_requested.store(false, Ordering::Release);
        let _seek_guard = SeekScopeGuard(&self.seek_executing);

        self.stop_reset_audio_queue();

        let mut seek_ret = dk_shim_seek_format(fmt, target_sec, false);
        if seek_ret < 0
            && !self.abort_requested.load(Ordering::Acquire)
            && self.latest_seek_seq.load(Ordering::Acquire) == my_seek_seq
        {
            seek_ret = dk_shim_seek_format(fmt, target_sec, true);
        }
        if self.abort_requested.load(Ordering::Acquire) {
            return SeekOutcome::Aborted;
        }
        if self.latest_seek_seq.load(Ordering::Acquire) != my_seek_seq {
            return SeekOutcome::Superseded;
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

        if let Ok(mut vq) = self.video_pkt_mtx.lock() {
            vq.clear();
        }
        self.video_pkt_count.store(0, Ordering::Relaxed);
        if let Ok(mut aq_pkts) = self.audio_pkt_mtx.lock() {
            aq_pkts.clear();
        }
        self.audio_pkt_count.store(0, Ordering::Relaxed);
        self.queued_pkt_bytes.store(0, Ordering::Relaxed);
        store_f64(&self.last_demuxed_pts_bits, target_sec);

        if let Ok(vc) = self.video_codec_mtx.lock() {
            if vc.0 != 0 {
                dk_shim_flush_codec(vc.0 as *mut c_void);
                dk_shim_set_codec_skip_nonref(vc.0 as *mut c_void, accurate);
                self.video_skip_nonref_active.store(accurate, Ordering::Release);
            }
        }
        if let Ok(ac) = self.audio_codec_mtx.lock() {
            if ac.codec_ctx != 0 {
                dk_shim_flush_codec(ac.codec_ctx as *mut c_void);
            }
        }
        if let Ok(mut sub) = self.sub_mtx.lock() {
            sub.flush_for_seek(
                self.sub_stream_idx.load(Ordering::Relaxed) >= 0,
                self.secondary_sub_stream_idx.load(Ordering::Relaxed) >= 0,
            );
        }
        self.clear_sub_pkt_history();
        self.clear_audio_pkt_history();

        store_f64(&self.last_decoded_pts_bits, target_sec);
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

        if let Ok(mut spd) = self.speed_mtx.lock() {
            spd.reset(self.get_total_bytes_read());
        }

        emit_log(
            0,
            &format!(
                "DKEngine: Seek completed to {:.2}s (accurate={})",
                target_sec,
                i32::from(accurate)
            ),
        );
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
        SeekOutcome::Completed
    }

    pub(crate) fn demux_worker(&self) {
        let Some(mut pkt) = AvPacket::alloc() else { return };
        let mut consecutive_io_errors = 0;
        let mut dovi_probe_packets = 0;

        while !self.abort_requested.load(Ordering::Acquire) {
            if self.initial_open_seek_pending.swap(false, Ordering::AcqRel) {
                if !self.seek_requested.load(Ordering::Acquire) {
                    let _demux_lk = self.demux_mtx.lock();
                    let my_seek_seq = self.latest_seek_seq.load(Ordering::Acquire);
                    let fmt = self.format_ctx.load(Ordering::Acquire);
                    let outcome = unsafe { self.execute_pending_seek(fmt, my_seek_seq) };
                    match outcome {
                        SeekOutcome::Aborted => break,
                        SeekOutcome::Superseded => continue,
                        SeekOutcome::Completed => {
                            consecutive_io_errors = 0;
                            pkt.unref();
                            continue;
                        }
                    }
                }
            }

            if self.seek_requested.load(Ordering::Acquire) {
                let _demux_lk = self.demux_mtx.lock();
                let my_seek_seq = self.latest_seek_seq.load(Ordering::Acquire);
                let fmt = self.format_ctx.load(Ordering::Acquire);
                let outcome = unsafe { self.execute_pending_seek(fmt, my_seek_seq) };
                match outcome {
                    SeekOutcome::Aborted => break,
                    SeekOutcome::Superseded => continue,
                    SeekOutcome::Completed => {
                        consecutive_io_errors = 0;
                        pkt.unref();
                        continue;
                    }
                }
            }

            let v_pkts = self.video_pkt_count.load(Ordering::Relaxed);
            let a_pkts = self.audio_pkt_count.load(Ordering::Relaxed);
            let drop_target = load_f64(&self.video_seek_drop_bits);
            let cur_pts = load_f64(&self.clock.current_pos_bits).max(0.0);
            let ref_pts = if drop_target > 0.0 { drop_target } else { cur_pts };
            let ahead_sec = (load_f64(&self.last_demuxed_pts_bits) - ref_pts).max(0.0);
            let total_pkt_bytes = self.queued_pkt_bytes.load(Ordering::Relaxed);

            let is_custom = self.has_custom_io.load(Ordering::Relaxed);
            let is_local = self.is_local_file.load(Ordering::Relaxed) && !is_custom;
            let user_cap = self.max_buffer_bytes.load(Ordering::Relaxed);
            let (max_ahead_sec, min_v_pkts, max_v_pkts, max_a_pkts, eff_mem_cap) = if is_local {
                (2.5, 16usize, 64usize, 300usize, user_cap.min(12 * 1024 * 1024))
            } else if is_custom {
                (16.0, 48usize, 480usize, 1200usize, user_cap.min(64 * 1024 * 1024))
            } else {
                (30.0, 60usize, 900usize, 1500usize, user_cap.min(96 * 1024 * 1024))
            };

            let time_enough = if self.video_stream_idx.load(Ordering::Relaxed) < 0 {
                a_pkts >= max_a_pkts
            } else {
                ahead_sec >= max_ahead_sec && v_pkts >= min_v_pkts
            };
            let pkts_enough = v_pkts >= max_v_pkts;
            let mem_enough = total_pkt_bytes >= eff_mem_cap;

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
                            self.video_pkt_count.fetch_add(1, Ordering::Relaxed);
                        }
                        self.video_decode_cv.notify_one();
                        if let Ok(mut aq_pkts) = self.audio_pkt_mtx.lock() {
                            aq_pkts.push_back(None);
                            self.audio_pkt_count.fetch_add(1, Ordering::Relaxed);
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
                        &format!(
                            "DKEngine Warning: av_read_frame failed ({}: {}), retrying",
                            ret,
                            ffmpeg_err_string(ret)
                        ),
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
            let has_custom_read = self.has_custom_io.load(Ordering::Relaxed);
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
                    && self.video_is_hevc.load(Ordering::Relaxed)
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
                    if self.startup_timing.first_vpkt_ms.load(Ordering::Relaxed) < 0 {
                        let base = self.startup_timing.workers_start_ns.load(Ordering::Acquire);
                        if base > 0 {
                            let ms = ((steady_now_ns() - base).max(0)) / 1_000_000;
                            let _ = self.startup_timing.first_vpkt_ms.compare_exchange(
                                -1,
                                ms,
                                Ordering::AcqRel,
                                Ordering::Relaxed,
                            );
                        }
                    }
                    if let Ok(mut vq) = self.video_pkt_mtx.lock() {
                        vq.push_back(Some(QueuedVideoPacket {
                            pkt: moved,
                            pts_sec: pkt_sec,
                            has_pts,
                        }));
                        self.video_pkt_count.fetch_add(1, Ordering::Relaxed);
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
                        self.audio_pkt_count.fetch_add(1, Ordering::Relaxed);
                        self.queued_pkt_bytes.fetch_add(sz, Ordering::Relaxed);
                    }
                    self.audio_decode_cv.notify_one();
                } else {
                    pkt.unref();
                }
            } else {
                let stype = if stream_idx >= 0 && (stream_idx as usize) < MAX_CACHED_STREAM_TYPES {
                    self.stream_types[stream_idx as usize].load(Ordering::Relaxed)
                } else if stream_idx >= 0 {
                    let mut smeta = DKShimStreamMeta::default();
                    if unsafe { dk_shim_get_stream_meta(fmt, stream_idx as u32, &mut smeta) } {
                        smeta.codec_type as i8
                    } else {
                        -1
                    }
                } else {
                    -1
                };

                if stype == 1 {
                    // Sliding ring buffer of unselected audio track packets for zero-seek instant switching
                    let keep_floor = cur_pts - 0.6;
                    if (!has_pts || pkt_sec >= keep_floor) && pkt_size > 0 {
                        const MAX_AUDIO_HIST_BYTES: usize = 4 * 1024 * 1024;
                        if let Some(moved) = pkt.move_out() {
                            let sz = moved.size().max(0) as usize;
                            if let Ok(mut hist) = self.audio_hist_mtx.lock() {
                                while let Some(front) = hist.pkts.front() {
                                    if front.pts_sec < keep_floor {
                                        let old = hist.pkts.pop_front().unwrap();
                                        hist.bytes = hist.bytes.saturating_sub(old.pkt.size().max(0) as usize);
                                    } else {
                                        break;
                                    }
                                }
                                hist.bytes += sz;
                                hist.pkts.push_back(AudioHistPacket {
                                    stream_idx,
                                    pts_sec: pkt_sec,
                                    pkt: moved,
                                });
                                while hist.bytes > MAX_AUDIO_HIST_BYTES {
                                    if let Some(old) = hist.pkts.pop_front() {
                                        hist.bytes = hist.bytes.saturating_sub(old.pkt.size().max(0) as usize);
                                        self.audio_hist_trimmed.store(true, Ordering::Relaxed);
                                    } else {
                                        break;
                                    }
                                }
                            }
                        } else {
                            pkt.unref();
                        }
                    } else {
                        pkt.unref();
                    }
                } else if stype == 2 {
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
                    pkt.unref();
                } else {
                    pkt.unref();
                }
            }
        }
    }
}
