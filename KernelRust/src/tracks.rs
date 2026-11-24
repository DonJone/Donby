use crate::abi::{cchar_array_to_string, DKChapterInfo, DKTrackInfo};
use crate::clock::load_f64;
use crate::emit_log;
use crate::ffi::{
    dk_shim_close_codec, dk_shim_close_swr, dk_shim_format_summary, dk_shim_get_chapter_info,
    dk_shim_get_stream_meta, dk_shim_open_audio_decoder, AvPacket, DKShimStreamMeta,
};
use crate::player::{AudioCodecState, DKPlayer};
use std::collections::VecDeque;
use std::ffi::{c_char, c_int, c_void};
use std::ptr;
use std::sync::atomic::Ordering;
use std::thread;

pub(crate) fn score_auto_subtitle_stream(meta: &DKShimStreamMeta) -> i32 {
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

impl DKPlayer {
    pub(crate) fn clear_sub_pkt_history(&self) {
        if let Ok(mut hist) = self.sub_hist_mtx.lock() {
            hist.pkts.clear();
            hist.bytes = 0;
        }
        self.sub_hist_trimmed.store(false, Ordering::Relaxed);
    }

    pub(crate) fn record_sub_pkt_history(&self, pkt: &AvPacket) {
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

    pub(crate) fn replay_sub_pkt_history(&self, target_stream_idx: i32, is_secondary: bool) {
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
            sub.mark_replayed();
        }
    }

    pub(crate) unsafe fn get_track_count(&self, track_type: c_int) -> c_int {
        let fmt = self.format_ctx.load(Ordering::Acquire);
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

    pub(crate) unsafe fn get_track_info(
        &self,
        track_type: c_int,
        ordinal: c_int,
        out_info: *mut DKTrackInfo,
    ) -> bool {
        let fmt = self.format_ctx.load(Ordering::Acquire);
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
                    0 => self.video_stream_idx.load(Ordering::Relaxed) == idx,
                    1 => self.audio_stream_idx.load(Ordering::Relaxed) == idx,
                    _ => self.sub_stream_idx.load(Ordering::Relaxed) == idx,
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

    pub(crate) unsafe fn get_chapter_count(&self) -> c_int {
        let fmt = self.format_ctx.load(Ordering::Acquire);
        if fmt.is_null() {
            return 0;
        }
        let mut nb_ch = 0u32;
        dk_shim_format_summary(fmt, ptr::null_mut(), &mut nb_ch, ptr::null_mut(), ptr::null_mut());
        nb_ch as c_int
    }

    pub(crate) unsafe fn get_chapter_info(
        &self,
        ordinal: c_int,
        out_info: *mut DKChapterInfo,
    ) -> bool {
        let fmt = self.format_ctx.load(Ordering::Acquire);
        if fmt.is_null() || out_info.is_null() || ordinal < 0 {
            return false;
        }
        dk_shim_get_chapter_info(fmt, ordinal as u32, out_info)
    }

    pub(crate) unsafe fn select_track(&self, track_type: c_int, mut stream_index: c_int) {
        let fmt = self.format_ctx.load(Ordering::Acquire);

        if track_type == 1 {
            if fmt.is_null() || stream_index < 0 {
                return;
            }
            let mut m = DKShimStreamMeta::default();
            if !dk_shim_get_stream_meta(fmt, stream_index as u32, &mut m) || m.codec_type != 1 {
                return;
            }
            if self.audio_stream_idx.load(Ordering::Acquire) == stream_index {
                return;
            }
            let cur_pts = self.get_master_clock().max(0.0);
            let Ok(mut ac) = self.audio_codec_mtx.lock() else { return };

            self.stop_reset_audio_queue();
            if let Ok(mut apkts) = self.audio_pkt_mtx.lock() {
                for item in VecDeque::drain(&mut *apkts, ..) {
                    if let Some(pkt) = item {
                        self.queued_pkt_bytes.fetch_sub(pkt.size() as i64, Ordering::Relaxed);
                    }
                }
            }
            if let Ok(mut ach) = self.audio_chunks_mtx.lock() {
                ach.clear();
            }
            self.buffered_audio_samples.store(0, Ordering::Release);
            self.clock.reset_to(cur_pts);
            if let Ok(mut vad) = self.vad_mtx.lock() {
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
                self.audio_stream_idx.store(stream_index, Ordering::Release);
                ac.codec_ctx = new_ctx as usize;
                ac.swr_ctx = new_swr as usize;
                ac.swr_fmt = s_fmt;
                ac.swr_rate = s_rate;
                ac.swr_ch = s_ch;
                if self.audio_queue_ptr.load(Ordering::Acquire).is_null() {
                    self.init_audio_queue();
                }
                if let Ok(mut st) = self.stats_mtx.lock() {
                    st.audio_codec = dec_name;
                }
                let was_no_worker = self.workers_mtx.lock().map(|w| w.audio.is_none()).unwrap_or(false);
                if was_no_worker {
                    let p_addr = self as *const Self as usize;
                    if let Ok(mut w) = self.workers_mtx.lock() {
                        w.audio = Some(thread::spawn(move || {
                            (*(p_addr as *const DKPlayer)).audio_decode_worker();
                        }));
                    }
                }
            } else {
                self.audio_stream_idx.store(-1, Ordering::Release);
            }
            drop(ac);
            self.signal_seek_request(cur_pts, true);
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
            if stream_index >= 0 && self.sub_stream_idx.load(Ordering::Relaxed) == stream_index {
                return;
            }
            let cur_pts = self.get_master_clock().max(0.0);
            let (vw, vh) = self.stats_mtx.lock().map(|s| (s.width, s.height)).unwrap_or((0, 0));
            let mut is_bitmap = false;
            if let Ok(mut sub) = self.sub_mtx.lock() {
                self.sub_stream_idx.store(stream_index, Ordering::Release);
                sub.open_stream_decoder(fmt, stream_index, false, vw, vh);
                is_bitmap = sub.has_bitmap_subs;
            }
            if stream_index >= 0 {
                self.replay_sub_pkt_history(stream_index, false);
                let demux_ahead = load_f64(&self.last_demuxed_pts_bits) - cur_pts;
                if self.sub_hist_trimmed.load(Ordering::Relaxed) && (is_bitmap || demux_ahead > 2.0) {
                    self.signal_seek_request(cur_pts, true);
                }
            } else {
                emit_log(0, "DKEngine: Subtitles disabled by user");
            }
        }
    }

    pub(crate) unsafe fn select_secondary_subtitle_track(&self, mut stream_index: c_int) {
        let fmt = self.format_ctx.load(Ordering::Acquire);
        if stream_index < 0 {
            stream_index = -1;
        }
        if stream_index >= 0 {
            if fmt.is_null() {
                return;
            }
            let mut m = DKShimStreamMeta::default();
            if !dk_shim_get_stream_meta(fmt, stream_index as u32, &mut m) || m.codec_type != 2 {
                emit_log(
                    1,
                    &format!("DKEngine: Ignored invalid secondary subtitle stream index {stream_index}"),
                );
                return;
            }
            if self.secondary_sub_stream_idx.load(Ordering::Relaxed) == stream_index {
                return;
            }
        }
        let cur_pts = self.get_master_clock().max(0.0);
        let (vw, vh) = self.stats_mtx.lock().map(|s| (s.width, s.height)).unwrap_or((0, 0));
        if let Ok(mut sub) = self.sub_mtx.lock() {
            self.secondary_sub_stream_idx.store(stream_index, Ordering::Release);
            sub.secondary_time_scale = 1.0;
            sub.open_stream_decoder(fmt, stream_index, true, vw, vh);
        }
        if stream_index >= 0 {
            self.replay_sub_pkt_history(stream_index, true);
            let demux_ahead = load_f64(&self.last_demuxed_pts_bits) - cur_pts;
            if self.sub_hist_trimmed.load(Ordering::Relaxed) && demux_ahead > 2.0 {
                self.signal_seek_request(cur_pts, true);
            }
        }
    }
}
