use super::*;
use super::ass_text::{ass_text_is_vector_drawing, is_pale_yellow_rgb, style_looks_like_foreign_secondary};

impl SubtitleEngine {
    pub fn set_style(
        &mut self,
        cfg: DKSubtitleStyleConfig,
        has_pri_stream: bool,
        has_sec_stream: bool,
    ) {
        let transform_changed = self.sub_style.text_transform != cfg.text_transform;
        let forced_changed = self.sub_style.forced_only != cfg.forced_only;
        let override_changed = self.sub_style.override_ass_style != cfg.override_ass_style;
        let font_changed = self.sub_style.unify_pingfang_font != cfg.unify_pingfang_font;
        let yellow_changed = self.sub_style.enhance_secondary_yellow != cfg.enhance_secondary_yellow;
        self.sub_style = cfg;

        if transform_changed || forced_changed || override_changed || font_changed || yellow_changed {
            if !self.primary_ext_raw.is_empty() {
                let raw = self.primary_ext_raw.clone();
                let is_ass = self.primary_ext_is_ass;
                self.populate_external_track(&raw, is_ass, false);
            } else if has_pri_stream && !self.has_bitmap_subs {
                self.rebuild_embedded_ass_track(false);
            }
            if !self.secondary_ext_raw.is_empty() {
                let raw = self.secondary_ext_raw.clone();
                let is_ass = self.secondary_ext_is_ass;
                self.populate_external_track(&raw, is_ass, true);
            } else if has_sec_stream && !self.secondary_has_bitmap_subs {
                self.rebuild_embedded_ass_track(true);
            }
        }

        if !self.ass_track.is_null() {
            self.apply_style_to_ass_track(self.ass_track, false);
        }
        if !self.secondary_ass_track.is_null() {
            self.apply_style_to_ass_track(self.secondary_ass_track, true);
        }
        self.sync_ass_renderer_params(self.ass_renderer);
        self.sync_ass_renderer_params(self.secondary_ass_renderer);
        self.sub_last_non_empty = false;
        self.sub_style_dirty = true;
        self.paired_layout_hash = 0;
        self.rendered_pgs_gen = 0;
        self.rendered_secondary_pgs_gen = 0;
        self.sub_serial += 1;
    }

    pub fn set_viewport(
        &mut self,
        viewport_w: i32,
        viewport_h: i32,
        video_w: i32,
        video_h: i32,
        margin_top: i32,
        margin_bottom: i32,
        margin_left: i32,
        margin_right: i32,
    ) {
        if viewport_w <= 0 || viewport_h <= 0 {
            return;
        }
        let safe_vw = if video_w > 0 { video_w } else { viewport_w };
        let safe_vh = if video_h > 0 { video_h } else { viewport_h };
        let mt = margin_top.max(0);
        let mb = margin_bottom.max(0);
        let ml = margin_left.max(0);
        let mr = margin_right.max(0);

        if self.ass_canvas_w == viewport_w
            && self.ass_canvas_h == viewport_h
            && self.sub_storage_w == safe_vw
            && self.sub_storage_h == safe_vh
            && self.sub_margin_t == mt
            && self.sub_margin_b == mb
            && self.sub_margin_l == ml
            && self.sub_margin_r == mr
        {
            return;
        }

        self.ass_canvas_w = viewport_w;
        self.ass_canvas_h = viewport_h;
        self.sub_storage_w = safe_vw;
        self.sub_storage_h = safe_vh;
        self.sub_margin_t = mt;
        self.sub_margin_b = mb;
        self.sub_margin_l = ml;
        self.sub_margin_r = mr;
        self.sync_ass_renderer_params(self.ass_renderer);
        self.sync_ass_renderer_params(self.secondary_ass_renderer);
        self.sub_style_dirty = true;
        self.paired_layout_hash = 0;
        self.rendered_pgs_gen = 0;
        self.rendered_secondary_pgs_gen = 0;
        self.sub_serial += 1;
    }

    pub fn set_secondary_time_scale(&mut self, scale: f64) {
        let safe_scale = if scale.is_finite() && (0.80..=1.25).contains(&scale) {
            scale
        } else {
            1.0
        };
        if (self.secondary_time_scale - safe_scale).abs() < 1e-9 {
            return;
        }
        self.secondary_time_scale = safe_scale;
        self.sub_last_non_empty = false;
        self.sub_style_dirty = true;
        self.paired_layout_hash = 0;
        self.rendered_secondary_pgs_gen = 0;
        self.sub_serial += 1;
    }

    pub fn get_vertical_bounds(&self) -> Option<(i32, i32, i32)> {
        if !self.sub_last_non_empty || self.ass_canvas_h <= 0 || self.sub_dirty_y1 <= self.sub_dirty_y0 {
            return None;
        }
        Some((self.sub_dirty_y0, self.sub_dirty_y1, self.ass_canvas_h))
    }

    pub fn get_intervals(&self, is_secondary: bool) -> Vec<DKSubtitleInterval> {
        let mut items = Vec::new();
        let is_bmp = if is_secondary { self.secondary_has_bitmap_subs } else { self.has_bitmap_subs };
        if is_bmp {
            let cues = if is_secondary { &self.secondary_pgs_cues } else { &self.pgs_cues };
            for cue in cues {
                if !cue.rects.is_empty() && cue.end_sec > cue.start_sec {
                    items.push(DKSubtitleInterval {
                        start_sec: cue.start_sec,
                        end_sec: cue.end_sec,
                    });
                }
            }
        } else {
            let tr = if is_secondary { self.secondary_ass_track } else { self.ass_track };
            if !tr.is_null() {
                let mut n_styles = 0;
                let mut n_events = 0;
                let mut play_res_y = 0;
                let mut has_fmt = false;
                unsafe { dk_shim_ass_track_meta(tr, &mut n_styles, &mut n_events, &mut play_res_y, &mut has_fmt) };
                for i in 0..n_events {
                    let mut s_ms = 0i64;
                    let mut d_ms = 0i64;
                    let mut st_idx = 0i32;
                    let mut mv = 0i32;
                    let mut txt_ptr: *const c_char = ptr::null();
                    if unsafe { dk_shim_ass_event_read(tr, i, &mut s_ms, &mut d_ms, &mut st_idx, &mut mv, &mut txt_ptr) } {
                        if d_ms <= 0 {
                            continue;
                        }
                        if !txt_ptr.is_null() {
                            let s = unsafe { CStr::from_ptr(txt_ptr) }.to_string_lossy();
                            if ass_text_is_vector_drawing(&s) {
                                continue;
                            }
                        }
                        let start_sec = (s_ms as f64) * 0.001;
                        let end_sec = ((s_ms + d_ms) as f64) * 0.001;
                        if end_sec > start_sec && start_sec >= 0.0 {
                            items.push(DKSubtitleInterval { start_sec, end_sec });
                        }
                    }
                }
            }
        }
        items.sort_by(|a, b| a.start_sec.partial_cmp(&b.start_sec).unwrap_or(std::cmp::Ordering::Equal));
        items
    }

    pub(super) fn sync_ass_renderer_params(&self, ren: *mut c_void) {
        if ren.is_null() {
            return;
        }
        let user_scale = if self.sub_style.scale > 0.1 {
            self.sub_style.scale.clamp(0.5, 2.5)
        } else {
            1.0
        };
        let pos_pct = if self.sub_style.vertical_pos_percent > 10.0 {
            self.sub_style.vertical_pos_percent.clamp(50.0, 100.0)
        } else {
            92.0
        };
        let line_pos = ((100.0 - pos_pct) as f64).clamp(0.0, 50.0);
        unsafe {
            if self.ass_canvas_w > 0 && self.ass_canvas_h > 0 {
                ass_set_frame_size(ren, self.ass_canvas_w, self.ass_canvas_h);
            }
            if self.sub_storage_w > 0 && self.sub_storage_h > 0 {
                ass_set_storage_size(ren, self.sub_storage_w, self.sub_storage_h);
            }
            ass_set_margins(ren, self.sub_margin_t, self.sub_margin_b, self.sub_margin_l, self.sub_margin_r);
            ass_set_use_margins(ren, 1);
            ass_set_font_scale(ren, user_scale as f64);
            ass_set_line_position(ren, line_pos);
        }
    }

    pub(super) fn ensure_ass_track_header_for(&mut self, track: *mut c_void, is_secondary: bool) {
        if self.ass_lib.is_null() || track.is_null() {
            return;
        }
        if is_secondary && self.secondary_ass_renderer.is_null() {
            self.secondary_ass_renderer = unsafe { ass_renderer_init(self.ass_lib) };
            if !self.secondary_ass_renderer.is_null() {
                unsafe {
                    ass_set_fonts(
                        self.secondary_ass_renderer,
                        ptr::null(),
                        PINGFANG_CSTR.as_ptr() as *const c_char,
                        1,
                        ptr::null(),
                        1,
                    );
                    if self.ass_canvas_w > 0 && self.ass_canvas_h > 0 {
                        ass_set_frame_size(self.secondary_ass_renderer, self.ass_canvas_w, self.ass_canvas_h);
                        ass_set_storage_size(self.secondary_ass_renderer, self.ass_canvas_w, self.ass_canvas_h);
                    }
                }
            }
        }

        let mut n_styles = 0;
        let mut n_events = 0;
        let mut play_res_y = 0;
        let mut has_event_fmt = false;
        unsafe { dk_shim_ass_track_meta(track, &mut n_styles, &mut n_events, &mut play_res_y, &mut has_event_fmt) };
        if has_event_fmt {
            self.apply_style_to_ass_track(track, is_secondary);
            return;
        }
        if n_styles > 1 {
            let events_hdr = "[Events]\r\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n";
            unsafe { ass_process_codec_private(track, events_hdr.as_ptr() as *const c_char, events_hdr.len() as c_int) };
            self.apply_style_to_ass_track(track, is_secondary);
            return;
        }
        let default_hdr = concat!(
            "[Script Info]\r\n",
            "ScriptType: v4.00+\r\n",
            "PlayResX: 1920\r\n",
            "PlayResY: 1080\r\n",
            "ScaledBorderAndShadow: yes\r\n\r\n",
            "[V4+ Styles]\r\n",
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\r\n",
            "Style: Default,PingFang SC,56,&H00F5F5F5,&H0000FFFF,&H24000000,&H80000000,-1,0,0,0,100,100,0,0,1,2.8,1.2,2,40,40,46,1\r\n\r\n",
            "[Events]\r\n",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n"
        );
        unsafe { ass_process_codec_private(track, default_hdr.as_ptr() as *const c_char, default_hdr.len() as c_int) };
        self.apply_style_to_ass_track(track, is_secondary);
    }

    fn apply_style_to_ass_track(&mut self, track: *mut c_void, is_secondary: bool) {
        if track.is_null() {
            return;
        }
        let mut n_styles = 0;
        let mut n_events = 0;
        let mut play_res_y = 0;
        let mut has_event_fmt = false;
        unsafe { dk_shim_ass_track_meta(track, &mut n_styles, &mut n_events, &mut play_res_y, &mut has_event_fmt) };

        let (orig_ptr, orig_styles) = if is_secondary {
            (&mut self.secondary_orig_track_ptr, &mut self.secondary_orig_styles)
        } else {
            (&mut self.primary_orig_track_ptr, &mut self.primary_orig_styles)
        };
        if *orig_ptr != (track as usize) || (orig_styles.len() as i32) != n_styles {
            *orig_ptr = track as usize;
            orig_styles.clear();
            for i in 0..n_styles {
                let mut name_p: *const c_char = ptr::null();
                let mut font_p: *const c_char = ptr::null();
                let mut fs = 56.0;
                let mut ol = 2.8;
                let mut mv = 46;
                let mut col = 0xF5F5F500u32;
                let mut sx = 1.0;
                let mut sy = 1.0;
                let mut align = 2;
                let mut bstyle = 1;
                unsafe {
                    dk_shim_ass_style_read(
                        track, i, &mut name_p, &mut font_p, &mut fs, &mut ol, &mut mv, &mut col, &mut sx, &mut sy,
                        &mut align, &mut bstyle,
                    );
                }
                let fname = if !font_p.is_null() {
                    unsafe { CStr::from_ptr(font_p) }.to_string_lossy().into_owned()
                } else {
                    "PingFang SC".to_owned()
                };
                orig_styles.push(OriginalAssStyle {
                    font_name: fname,
                    font_size: fs,
                    outline: ol,
                    margin_v: mv,
                    primary_colour: col,
                    scale_x: sx,
                    scale_y: sy,
                    alignment: align,
                    border_style: bstyle,
                });
            }
        }

        let border = if self.sub_style.border_width >= 0.0 {
            self.sub_style.border_width.clamp(0.0, 8.0) as f64
        } else {
            2.8
        };
        let res_y = if play_res_y > 0 { play_res_y } else { 1080 };
        let res_ratio = (res_y as f64) / 1080.0;
        let compact_margin_v = ((14.0 * res_ratio).round() as i32).max(4);
        let unify_pf = self.sub_style.unify_pingfang_font;
        let enhance_yellow = self.sub_style.enhance_secondary_yellow;
        let override_all = self.sub_style.override_ass_style;
        let sec_rel_scale = if self.sub_style.secondary_scale > 0.2 {
            (self.sub_style.secondary_scale as f64).clamp(0.45, 1.40)
        } else {
            0.60
        };
        let role_rel = if is_secondary { sec_rel_scale } else { 1.0 };

        let snap_styles = if is_secondary {
            self.secondary_orig_styles.clone()
        } else {
            self.primary_orig_styles.clone()
        };

        for (i, orig) in snap_styles.iter().enumerate() {
            let mut name_p: *const c_char = ptr::null();
            unsafe {
                dk_shim_ass_style_read(
                    track, i as i32, &mut name_p, ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut(),
                    ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut(),
                );
            }
            let st_name = if !name_p.is_null() {
                unsafe { CStr::from_ptr(name_p) }.to_string_lossy().into_owned()
            } else {
                String::new()
            };
            let is_default = st_name == "Default" || n_styles == 1;
            let is_bottom_style = (orig.alignment & 0x0C) == 0;

            let desired_font = if unify_pf || override_all {
                "PingFang SC"
            } else {
                orig.font_name.as_str()
            };
            let font_c = CString::new(desired_font).unwrap_or_else(|_| CString::new("PingFang SC").unwrap());

            let r = ((orig.primary_colour >> 24) & 0xFF) as u8;
            let g = ((orig.primary_colour >> 16) & 0xFF) as u8;
            let b = ((orig.primary_colour >> 8) & 0xFF) as u8;
            let should_gold = enhance_yellow
                && (is_secondary || style_looks_like_foreign_secondary(&st_name) || is_pale_yellow_rgb(r, g, b));
            let pri_col = if should_gold { CLASSIC_GOLD_YELLOW_RGBA } else { orig.primary_colour };

            if override_all || is_default {
                let base_fs = if is_default && orig.font_size > 10.0 && !override_all && n_styles > 1 {
                    orig.font_size
                } else {
                    56.0 * res_ratio
                };
                let fs = base_fs * role_rel;
                let ol = border * (if is_secondary { 0.88 } else { 1.0 }) * res_ratio;
                let (sx, sy, al, bs) = if override_all {
                    (1.0, 1.0, 2, 1)
                } else {
                    (orig.scale_x, orig.scale_y, orig.alignment, orig.border_style)
                };
                unsafe {
                    dk_shim_ass_style_write(
                        track, i as i32, font_c.as_ptr(), pri_col, fs, ol, compact_margin_v, sx, sy, al, bs, true,
                    );
                }
            } else if is_bottom_style {
                let fs = if orig.font_size > 4.0 {
                    orig.font_size * role_rel
                } else {
                    48.0 * res_ratio * role_rel
                };
                let ol = orig.outline.max(border * 0.85 * res_ratio);
                let mv = orig.margin_v.min(compact_margin_v + ((24.0 * res_ratio).round() as i32));
                unsafe {
                    dk_shim_ass_style_write(
                        track, i as i32, font_c.as_ptr(), pri_col, fs, ol, mv, orig.scale_x, orig.scale_y,
                        orig.alignment, orig.border_style, true,
                    );
                }
            } else {
                unsafe {
                    dk_shim_ass_style_write(
                        track, i as i32, font_c.as_ptr(), pri_col, 0.0, 0.0, 0, 1.0, 1.0, 2, 1, false,
                    );
                }
            }
        }

        for i in 0..n_events {
            let mut s_ms = 0;
            let mut d_ms = 0;
            let mut st_idx = -1;
            let mut ev_mv = 0;
            unsafe {
                if dk_shim_ass_event_read(track, i, &mut s_ms, &mut d_ms, &mut st_idx, &mut ev_mv, ptr::null_mut()) {
                    if st_idx >= 0 && (st_idx as usize) < snap_styles.len() {
                        let mut align = 2;
                        dk_shim_ass_style_read(
                            track, st_idx, ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut(),
                            ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), &mut align, ptr::null_mut(),
                        );
                        if (align & 0x0C) == 0 && ev_mv > compact_margin_v {
                            dk_shim_ass_event_zero_margin_v(track, i);
                        }
                    }
                }
            }
        }

        self.sync_ass_renderer_params(self.ass_renderer);
        self.sync_ass_renderer_params(self.secondary_ass_renderer);
    }
}
