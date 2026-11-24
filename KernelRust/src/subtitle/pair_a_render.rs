use super::*;
use super::ass_text::style_looks_like_foreign_secondary;
use super::compositor::blit_paired_raster;
use super::pair_a_parse::{build_paired_turns, event_has_special_ass_effects, extract_clean_lines_from_ass_text, track_looks_predominantly_latin};

impl SubtitleEngine {
    pub(super) fn try_render_paired_bilingual(
        &mut self,
        video_pts: f64,
        pri_pts: f64,
        sec_pts: f64,
        sec_scale: f64,
        canvas_w: i32,
        canvas_h: i32,
        canvas_resized: bool,
    ) -> i32 {
        if self.ass_lib.is_null() || !self.sub_style.unify_pingfang_font {
            return -1;
        }
        if self.has_bitmap_subs || self.secondary_has_bitmap_subs {
            return -1;
        }
        if self.ass_track.is_null() && self.secondary_ass_track.is_null() {
            return -1;
        }

        let now_ms = (video_pts.max(0.0) * 1000.0).round() as i64;
        let pri_ms = (pri_pts.max(0.0) * 1000.0) as i64;
        let sec_ms = (sec_pts.max(0.0) * 1000.0) as i64;
        let pri_delay_ms = (self.sub_style.primary_delay_sec * 1000.0).round() as i64;
        let sec_delay_ms = (self.sub_style.secondary_delay_sec * 1000.0).round() as i64;

        let event_display_span = |s_ms: i64, d_ms: i64, is_sec: bool| -> (i64, i64) {
            if is_sec {
                let s = ((s_ms as f64) * sec_scale).round() as i64 + sec_delay_ms;
                let e = (((s_ms + d_ms) as f64) * sec_scale).round() as i64 + sec_delay_ms;
                (s, e)
            } else {
                (s_ms + pri_delay_ms, s_ms + d_ms + pri_delay_ms)
            }
        };

        let dual_tracks_loaded = !self.ass_track.is_null() && !self.secondary_ass_track.is_null();
        let anchor_is_secondary = if dual_tracks_loaded {
            match self.sub_style.dual_anchor_mode {
                2 => true,
                1 => false,
                _ => {
                    let sec_lat = track_looks_predominantly_latin(self.secondary_ass_track);
                    let pri_lat = track_looks_predominantly_latin(self.ass_track);
                    sec_lat && !pri_lat
                }
            }
        } else {
            !self.secondary_ass_track.is_null()
        };

        let mut pri_tagged: Vec<(String, bool)> = Vec::new();
        let mut sec_lines: Vec<String> = Vec::new();
        let override_ass = self.sub_style.override_ass_style;

        let mut append_event = |tr: *const c_void, ev_idx: i32, is_sec: bool| -> bool {
            let mut s_ms = 0i64;
            let mut d_ms = 0i64;
            let mut st_idx = -1i32;
            let mut mv = 0i32;
            let mut txt_p: *const c_char = ptr::null();
            if !unsafe { dk_shim_ass_event_read(tr, ev_idx, &mut s_ms, &mut d_ms, &mut st_idx, &mut mv, &mut txt_p) } {
                return true;
            }
            let txt = if txt_p.is_null() {
                String::new()
            } else {
                unsafe { CStr::from_ptr(txt_p) }.to_string_lossy().into_owned()
            };

            let mut st_align = 2i32;
            let mut st_name_p: *const c_char = ptr::null();
            let mut n_styles = 0;
            unsafe { dk_shim_ass_track_meta(tr, &mut n_styles, ptr::null_mut(), ptr::null_mut(), ptr::null_mut()) };
            if st_idx >= 0 && st_idx < n_styles {
                unsafe {
                    dk_shim_ass_style_read(
                        tr, st_idx, &mut st_name_p, ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut(),
                        ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), &mut st_align, ptr::null_mut(),
                    );
                }
            }
            if !override_ass && event_has_special_ass_effects(st_align, &txt) {
                return false;
            }
            let mut style_foreign = is_sec;
            if !is_sec && !st_name_p.is_null() {
                let sname = unsafe { CStr::from_ptr(st_name_p) }.to_string_lossy();
                if style_looks_like_foreign_secondary(&sname) {
                    style_foreign = true;
                }
            }
            if is_sec {
                let mut tmp = Vec::new();
                extract_clean_lines_from_ass_text(&txt, true, &mut tmp);
                for (line, _) in tmp {
                    sec_lines.push(line);
                }
            } else {
                extract_clean_lines_from_ass_text(&txt, style_foreign, &mut pri_tagged);
            }
            true
        };

        if dual_tracks_loaded {
            const SNAP_MS: i64 = 450;
            const BRIDGE_GAP_MS: i64 = 900;
            const TAIL_HOLD_MS: i64 = 1800;
            const LOCAL_WIN_MS: i64 = 12_000;

            #[derive(Copy, Clone)]
            struct DispEv {
                idx: i32,
                ds: i64,
                de: i64,
                eff_s: i64,
                eff_e: i64,
            }
            impl DispEv {
                fn dur(&self) -> i64 {
                    (self.de - self.ds).max(1)
                }
            }

            let collect_nearby = |tr: *const c_void, is_sec: bool| -> Vec<DispEv> {
                let mut out = Vec::new();
                if tr.is_null() {
                    return out;
                }
                let mut n_events = 0;
                unsafe { dk_shim_ass_track_meta(tr, ptr::null_mut(), &mut n_events, ptr::null_mut(), ptr::null_mut()) };
                for i in 0..n_events {
                    let mut s_ms = 0i64;
                    let mut d_ms = 0i64;
                    if unsafe {
                        dk_shim_ass_event_read(tr, i, &mut s_ms, &mut d_ms, ptr::null_mut(), ptr::null_mut(), ptr::null_mut())
                    } {
                        if d_ms <= 0 {
                            continue;
                        }
                        let (ds, de) = event_display_span(s_ms, d_ms, is_sec);
                        if de < now_ms - LOCAL_WIN_MS || ds > now_ms + LOCAL_WIN_MS {
                            continue;
                        }
                        out.push(DispEv { idx: i, ds, de, eff_s: ds, eff_e: de });
                    }
                }
                out.sort_by(|a, b| a.ds.cmp(&b.ds).then(a.de.cmp(&b.de)));
                out
            };

            let find_next_idx = |evs: &[DispEv], cur_pos: usize| -> Option<usize> {
                let cur_de = evs[cur_pos].de;
                (cur_pos + 1..evs.len()).find(|&m| evs[m].ds >= cur_de - 120)
            };

            let cues_pair_overlap = |a: &DispEv, b: &DispEv| -> bool {
                let ov = a.de.min(b.de) - a.ds.max(b.ds);
                if ov <= 0 {
                    return false;
                }
                let min_dur = a.dur().min(b.dur());
                let req_ov = (min_dur * 35 / 100).max(1);
                ov >= req_ov
            };

            let anchor_tr = if anchor_is_secondary { self.secondary_ass_track } else { self.ass_track };
            let other_tr = if anchor_is_secondary { self.ass_track } else { self.secondary_ass_track };
            let other_is_sec = !anchor_is_secondary;

            let mut anchor_evs = collect_nearby(anchor_tr, anchor_is_secondary);
            let mut other_evs = collect_nearby(other_tr, other_is_sec);

            let mut other_pair_a_e = vec![i64::MIN; other_evs.len()];
            let mut other_has_pair = vec![false; other_evs.len()];

            for oi in 0..other_evs.len() {
                let oe = other_evs[oi];
                let mut pa_s = i64::MAX;
                let mut pa_e = i64::MIN;
                for ae in &anchor_evs {
                    if cues_pair_overlap(&oe, ae) {
                        pa_s = pa_s.min(ae.ds);
                        pa_e = pa_e.max(ae.de);
                    }
                }
                if pa_s < i64::MAX {
                    other_has_pair[oi] = true;
                    other_pair_a_e[oi] = pa_e;
                    let mut has_prior_in_anchor = false;
                    if oe.ds > pa_s && (oe.ds - pa_s) <= SNAP_MS {
                        for pi in 0..oi {
                            if other_evs[pi].de > pa_s && other_evs[pi].ds < oe.ds {
                                has_prior_in_anchor = true;
                                break;
                            }
                        }
                    }
                    if !has_prior_in_anchor && (oe.ds - pa_s).abs() <= SNAP_MS {
                        other_evs[oi].eff_s = pa_s;
                    }
                }
            }

            let partner_covers_gap = |partner: &[DispEv], g_s: i64, g_e: i64| -> bool {
                if g_e <= g_s {
                    return false;
                }
                let mid = g_s + (g_e - g_s) / 2;
                partner.iter().any(|pe| pe.eff_s <= mid && pe.eff_e >= mid)
            };

            for oi in 0..other_evs.len() {
                let next_eff_s = find_next_idx(&other_evs, oi)
                    .map(|ni| other_evs[ni].eff_s)
                    .unwrap_or(i64::MAX);
                let oe_de = other_evs[oi].de;
                let oe_eff_s = other_evs[oi].eff_s;

                if other_has_pair[oi] {
                    let pa_e = other_pair_a_e[oi];
                    if oe_de > pa_e {
                        other_evs[oi].eff_e = if (oe_de - pa_e) <= SNAP_MS { pa_e } else { oe_de };
                    } else if oe_de < pa_e {
                        let gap_to_next = if next_eff_s < i64::MAX { next_eff_s - oe_de } else { i64::MAX };
                        let gap_to_pair_end = pa_e - oe_de;
                        if next_eff_s < pa_e && (0..=BRIDGE_GAP_MS).contains(&gap_to_next) {
                            other_evs[oi].eff_e = next_eff_s;
                        } else if gap_to_pair_end <= TAIL_HOLD_MS {
                            other_evs[oi].eff_e = pa_e.min(next_eff_s);
                        }
                    }
                }
                if next_eff_s < i64::MAX
                    && next_eff_s > other_evs[oi].eff_e
                    && (next_eff_s - other_evs[oi].eff_e) <= BRIDGE_GAP_MS
                    && partner_covers_gap(&anchor_evs, other_evs[oi].eff_e, next_eff_s)
                {
                    other_evs[oi].eff_e = next_eff_s;
                }
                if next_eff_s < i64::MAX && other_evs[oi].eff_e > next_eff_s && oe_eff_s < next_eff_s {
                    other_evs[oi].eff_e = next_eff_s;
                }
            }

            for ai in 0..anchor_evs.len() {
                let next_a_s = find_next_idx(&anchor_evs, ai)
                    .map(|ni| anchor_evs[ni].eff_s)
                    .unwrap_or(i64::MAX);
                let mut paired_other_max_e = anchor_evs[ai].eff_e;
                for oe in &other_evs {
                    if cues_pair_overlap(oe, &anchor_evs[ai]) {
                        paired_other_max_e = paired_other_max_e.max(oe.eff_e);
                    }
                }
                if paired_other_max_e > anchor_evs[ai].eff_e {
                    let gap_to_next = if next_a_s < i64::MAX {
                        next_a_s - anchor_evs[ai].eff_e
                    } else {
                        i64::MAX
                    };
                    let gap_to_other_end = paired_other_max_e - anchor_evs[ai].eff_e;
                    if next_a_s < paired_other_max_e && (0..=BRIDGE_GAP_MS).contains(&gap_to_next) {
                        anchor_evs[ai].eff_e = next_a_s;
                    } else if gap_to_other_end <= TAIL_HOLD_MS {
                        anchor_evs[ai].eff_e = paired_other_max_e.min(next_a_s);
                    }
                }
                if next_a_s < i64::MAX
                    && next_a_s > anchor_evs[ai].eff_e
                    && (next_a_s - anchor_evs[ai].eff_e) <= BRIDGE_GAP_MS
                    && partner_covers_gap(&other_evs, anchor_evs[ai].eff_e, next_a_s)
                {
                    anchor_evs[ai].eff_e = next_a_s;
                }
                if next_a_s < i64::MAX && anchor_evs[ai].eff_e > next_a_s && anchor_evs[ai].eff_s < next_a_s {
                    anchor_evs[ai].eff_e = next_a_s;
                }
            }

            for ae in &anchor_evs {
                if now_ms >= ae.eff_s && now_ms < ae.eff_e {
                    if !append_event(anchor_tr, ae.idx, anchor_is_secondary) {
                        return -1;
                    }
                }
            }
            for oe in &other_evs {
                if now_ms >= oe.eff_s && now_ms < oe.eff_e {
                    if !append_event(other_tr, oe.idx, other_is_sec) {
                        return -1;
                    }
                }
            }
        } else {
            let mut collect_single = |tr: *const c_void, track_now_ms: i64, is_sec: bool| -> bool {
                if tr.is_null() {
                    return true;
                }
                let mut n_events = 0;
                unsafe { dk_shim_ass_track_meta(tr, ptr::null_mut(), &mut n_events, ptr::null_mut(), ptr::null_mut()) };
                for i in 0..n_events {
                    let mut s_ms = 0i64;
                    let mut d_ms = 0i64;
                    if unsafe {
                        dk_shim_ass_event_read(tr, i, &mut s_ms, &mut d_ms, ptr::null_mut(), ptr::null_mut(), ptr::null_mut())
                    } {
                        if d_ms <= 0 || track_now_ms < s_ms || track_now_ms >= s_ms + d_ms {
                            continue;
                        }
                        if !append_event(tr, i, is_sec) {
                            return false;
                        }
                    }
                }
                true
            };
            if !collect_single(self.ass_track, pri_ms, false) {
                return -1;
            }
            if !collect_single(self.secondary_ass_track, sec_ms, true) {
                return -1;
            }
        }

        if pri_tagged.is_empty() && sec_lines.is_empty() {
            if self.sub_last_non_empty {
                self.clear_subtitle_canvas(canvas_w, canvas_h);
                self.sub_last_non_empty = false;
                self.paired_layout_active = false;
                self.paired_layout_hash = 0;
                self.sub_serial += 1;
            }
            return 0;
        }

        let turns = build_paired_turns(&pri_tagged, &sec_lines, anchor_is_secondary);
        if turns.is_empty() {
            if self.sub_last_non_empty {
                self.clear_subtitle_canvas(canvas_w, canvas_h);
                self.sub_last_non_empty = false;
                self.paired_layout_active = false;
                self.paired_layout_hash = 0;
                self.sub_serial += 1;
            }
            return 0;
        }

        let mut h: u64 = 14695981039346656037;
        hash_mix(&mut h, canvas_w as u64);
        hash_mix(&mut h, canvas_h as u64);
        hash_mix(&mut h, self.sub_margin_b as u64);
        hash_mix(&mut h, self.sub_margin_t as u64);
        hash_mix(&mut h, (self.sub_style.scale * 1000.0).round() as u64);
        hash_mix(&mut h, (self.sub_style.secondary_scale * 1000.0).round() as u64);
        hash_mix(&mut h, (self.sub_style.vertical_pos_percent * 100.0).round() as u64);
        hash_mix(&mut h, (self.sub_style.border_width * 100.0).round() as u64);
        hash_mix(&mut h, (self.sub_style.dual_gap_px * 10.0).round() as u64);
        hash_mix(&mut h, u64::from(self.sub_style.enhance_secondary_yellow));
        hash_mix(&mut h, u64::from(self.sub_style.primary_on_top));
        hash_mix(&mut h, self.sub_style.dual_layout_mode as u64);
        hash_mix(&mut h, self.sub_style.dual_anchor_mode as u64);
        for t in &turns {
            hash_mix(&mut h, 0xAAAA);
            for l in &t.pri_lines {
                hash_str(&mut h, l);
            }
            hash_mix(&mut h, 0xBBBB);
            for l in &t.sec_lines {
                hash_str(&mut h, l);
            }
        }

        let buf_mismatch = self.sub_rgba_buf.len() != (canvas_w as usize) * (canvas_h as usize) * 4;
        if self.paired_layout_active
            && self.sub_last_non_empty
            && !self.sub_style_dirty
            && !canvas_resized
            && !buf_mismatch
            && h == self.paired_layout_hash
        {
            return 1;
        }

        self.sub_style_dirty = false;
        self.clear_subtitle_canvas(canvas_w, canvas_h);

        let vh_ratio = (canvas_h as f64) / 1200.0;
        let user_scale = if self.sub_style.scale > 0.1 {
            (self.sub_style.scale as f64).clamp(0.5, 2.5)
        } else {
            1.0
        };
        let sec_rel = if self.sub_style.secondary_scale > 0.2 {
            (self.sub_style.secondary_scale as f64).clamp(0.45, 1.40)
        } else {
            0.60
        };
        let k_scale = vh_ratio * user_scale;
        let cn_size = 58.0 * k_scale;
        let en_size = 58.0 * sec_rel * k_scale;
        let base_border = if self.sub_style.border_width >= 0.0 {
            (self.sub_style.border_width as f64).clamp(0.0, 8.0)
        } else {
            2.2
        };
        let cn_outline = base_border * k_scale;
        let en_outline = base_border * 0.82 * k_scale;
        let cn_shadow = 1.0 * k_scale;
        let en_shadow = 0.9 * k_scale;
        let cn_spacing = 1.0 * k_scale;
        let en_spacing = 0.2 * k_scale;
        let cn_color = "&H00FFFFFF";
        let en_color = if self.sub_style.enhance_secondary_yellow {
            "&H002EB2FF"
        } else {
            "&H00EAEAEF"
        };
        let margin_lr = (((canvas_w as f64) * 0.05).round() as i32).max(48);

        let cn_inner_gap = ((6.0 * k_scale).round() as i32).max(2);
        let en_inner_gap = ((4.0 * k_scale).round() as i32).max(2);
        let pair_gap_cfg = if self.sub_style.dual_gap_px >= 0.0 {
            self.sub_style.dual_gap_px as f64
        } else {
            7.0
        };
        let pair_gap = ((pair_gap_cfg * k_scale).round() as i32).max(1);
        let turn_gap = ((16.0 * k_scale).round() as i32).max(6);

        let primary_on_top = self.sub_style.primary_on_top;
        let layout_mode = self.sub_style.dual_layout_mode;

        struct RasterTurn {
            pri: Vec<PairedLineRaster>,
            sec: Vec<PairedLineRaster>,
            pri_h: i32,
            sec_h: i32,
            total_h: i32,
        }

        let mut r_turns = Vec::with_capacity(turns.len());
        let mut total_bottom_h = 0i32;

        for t in &turns {
            let mut rt = RasterTurn {
                pri: Vec::new(),
                sec: Vec::new(),
                pri_h: 0,
                sec_h: 0,
                total_h: 0,
            };
            for line in &t.pri_lines {
                let r = self.raster_paired_line(
                    canvas_w, canvas_h, cn_size, cn_spacing, cn_color, cn_outline, cn_shadow, margin_lr, line,
                );
                if r.h() > 0 {
                    rt.pri_h += r.h() + if rt.pri.is_empty() { 0 } else { cn_inner_gap };
                    rt.pri.push(r);
                }
            }
            for line in &t.sec_lines {
                let r = self.raster_paired_line(
                    canvas_w, canvas_h, en_size, en_spacing, en_color, en_outline, en_shadow, margin_lr, line,
                );
                if r.h() > 0 {
                    rt.sec_h += r.h() + if rt.sec.is_empty() { 0 } else { en_inner_gap };
                    rt.sec.push(r);
                }
            }
            if layout_mode == 1 {
                if rt.pri_h > 0 {
                    total_bottom_h += rt.pri_h + if total_bottom_h > 0 { turn_gap } else { 0 };
                }
            } else {
                let pg = if rt.pri_h > 0 && rt.sec_h > 0 { pair_gap } else { 0 };
                rt.total_h = rt.pri_h + pg + rt.sec_h;
                if rt.total_h > 0 {
                    total_bottom_h += rt.total_h + if total_bottom_h > 0 { turn_gap } else { 0 };
                }
            }
            r_turns.push(rt);
        }

        let mut new_y0 = canvas_h;
        let mut new_y1 = 0;
        let pos_pct = if self.sub_style.vertical_pos_percent > 10.0 {
            self.sub_style.vertical_pos_percent.clamp(50.0, 100.0)
        } else {
            92.0
        };
        let bar_h = self.sub_margin_b;
        let video_bottom_y = canvas_h - bar_h;

        let compute_bottom_block_top = |block_h: i32, is_single_turn: bool| -> i32 {
            if block_h <= 0 {
                return canvas_h;
            }
            if bar_h >= ((90.0 * vh_ratio).round() as i32) && pos_pct >= 88.0 {
                let t_bar = ((pos_pct - 88.0) / 12.0).clamp(0.0, 1.0);
                if is_single_turn && block_h <= bar_h - ((38.0 * vh_ratio).round() as i32) {
                    let min_top = video_bottom_y + ((14.0 * vh_ratio).round() as i32);
                    let max_top = canvas_h - block_h - ((26.0 * vh_ratio).round() as i32);
                    let safe_max = min_top.max(max_top);
                    let mapped = if t_bar <= 0.333 {
                        0.42 * (t_bar / 0.333)
                    } else {
                        0.42 + 0.58 * ((t_bar - 0.333) / 0.667)
                    };
                    let raw_top = min_top + (((safe_max - min_top) as f32 * mapped).round() as i32);
                    return raw_top.clamp(8, (canvas_h - block_h - 14).max(8));
                } else {
                    let min_margin = (20.0 * vh_ratio).round() as i32;
                    let anchor_margin =
                        min_margin.max((34.0 * vh_ratio - (t_bar as f64) * 14.0 * vh_ratio).round() as i32);
                    return ((canvas_h - anchor_margin) - block_h).clamp(8, (canvas_h - block_h - 14).max(8));
                }
            }
            let anchor_bottom =
                (((pos_pct as f64) * 0.01 * (canvas_h as f64)).round() as i32).clamp(block_h + 8, canvas_h - 8);
            (anchor_bottom - block_h).max(8)
        };

        if layout_mode == 1 {
            let mut cur_y = compute_bottom_block_top(total_bottom_h, r_turns.len() <= 1);
            for rt in &r_turns {
                for (i, rl) in rt.pri.iter().enumerate() {
                    let x = (canvas_w - rl.w()) / 2;
                    blit_paired_raster(rl, &mut self.sub_rgba_buf, canvas_w, canvas_h, x, cur_y, &mut new_y0, &mut new_y1);
                    cur_y += rl.h() + if i + 1 < rt.pri.len() { cn_inner_gap } else { 0 };
                }
                if rt.pri_h > 0 {
                    cur_y += turn_gap;
                }
            }
            let mut top_y = (self.sub_margin_t / 4 + 14).max(14);
            for rt in &r_turns {
                for (i, rl) in rt.sec.iter().enumerate() {
                    let x = (canvas_w - rl.w()) / 2;
                    blit_paired_raster(rl, &mut self.sub_rgba_buf, canvas_w, canvas_h, x, top_y, &mut new_y0, &mut new_y1);
                    top_y += rl.h() + if i + 1 < rt.sec.len() { en_inner_gap } else { 0 };
                }
                if rt.sec_h > 0 {
                    top_y += turn_gap;
                }
            }
        } else {
            let mut effective_bottom_h = total_bottom_h;
            if dual_tracks_loaded
                && primary_on_top
                && bar_h < ((90.0 * vh_ratio).round() as i32)
                && r_turns.len() == 1
                && !r_turns[0].pri.is_empty()
                && r_turns[0].sec.is_empty()
            {
                effective_bottom_h += pair_gap + ((en_size * 0.92).round() as i32).max(12);
            }
            let mut cur_y = compute_bottom_block_top(effective_bottom_h, r_turns.len() <= 1);
            for (ti, rt) in r_turns.iter().enumerate() {
                if rt.total_h <= 0 {
                    continue;
                }
                let (first_grp, second_grp, first_gap, second_gap) = if primary_on_top {
                    (&rt.pri, &rt.sec, cn_inner_gap, en_inner_gap)
                } else {
                    (&rt.sec, &rt.pri, en_inner_gap, cn_inner_gap)
                };
                for (i, rl) in first_grp.iter().enumerate() {
                    let x = (canvas_w - rl.w()) / 2;
                    blit_paired_raster(rl, &mut self.sub_rgba_buf, canvas_w, canvas_h, x, cur_y, &mut new_y0, &mut new_y1);
                    cur_y += rl.h() + if i + 1 < first_grp.len() { first_gap } else { 0 };
                }
                if !first_grp.is_empty() && !second_grp.is_empty() {
                    cur_y += pair_gap;
                }
                for (i, rl) in second_grp.iter().enumerate() {
                    let x = (canvas_w - rl.w()) / 2;
                    blit_paired_raster(rl, &mut self.sub_rgba_buf, canvas_w, canvas_h, x, cur_y, &mut new_y0, &mut new_y1);
                    cur_y += rl.h() + if i + 1 < second_grp.len() { second_gap } else { 0 };
                }
                if ti + 1 < r_turns.len() {
                    cur_y += turn_gap;
                }
            }
        }

        if new_y1 > new_y0 {
            self.sub_dirty_y0 = new_y0;
            self.sub_dirty_y1 = new_y1;
        }
        self.paired_layout_active = true;
        self.paired_layout_hash = h;
        self.sub_last_non_empty = true;
        self.sub_serial += 1;
        1
    }
}

#[inline]
fn hash_mix(h: &mut u64, v: u64) {
    *h ^= v
        .wrapping_add(0x9e3779b97f4a7c15)
        .wrapping_add(*h << 6)
        .wrapping_add(*h >> 2);
}

#[inline]
fn hash_str(h: &mut u64, s: &str) {
    for &b in s.as_bytes() {
        *h = (*h ^ (b as u64)).wrapping_mul(1099511628211);
    }
    hash_mix(h, s.len() as u64);
}
