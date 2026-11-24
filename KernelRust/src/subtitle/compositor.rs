use super::*;
use super::pgs::render_pgs_cue_to_layer;

impl SubtitleEngine {
    pub(super) fn clear_subtitle_canvas(&mut self, target_w: i32, target_h: i32) {
        let expected = (target_w as usize) * (target_h as usize) * 4;
        if self.sub_rgba_buf.len() != expected {
            self.sub_rgba_buf.clear();
            self.sub_rgba_buf.resize(expected, 0);
            self.sub_dirty_y0 = 0;
            self.sub_dirty_y1 = 0;
            return;
        }
        let y0 = (self.sub_dirty_y0 - 2).clamp(0, target_h);
        let y1 = (self.sub_dirty_y1 + 2).clamp(y0, target_h);
        if y1 > y0 {
            let row_bytes = (target_w as usize) * 4;
            let off = (y0 as usize) * row_bytes;
            let end = (y1 as usize) * row_bytes;
            self.sub_rgba_buf[off..end].fill(0);
        }
        self.sub_dirty_y0 = 0;
        self.sub_dirty_y1 = 0;
    }

    pub fn update_subtitle_rgba(
        &mut self,
        pts: f64,
        mut canvas_w: i32,
        mut canvas_h: i32,
    ) -> (bool, *const u8, i32, i32, u64) {
        if canvas_w > 1920 {
            canvas_h = ((canvas_h * 1920) / canvas_w).max(1);
            canvas_w = 1920;
        }
        if !self.has_bitmap_subs
            && !self.secondary_has_bitmap_subs
            && self.primary_ass_events.is_empty()
            && self.secondary_ass_events.is_empty()
            && self.primary_ext_raw.is_empty()
            && self.secondary_ext_raw.is_empty()
            && !self.sub_last_non_empty
        {
            return (false, ptr::null(), 0, 0, self.sub_serial);
        }
        let pri_pts = pts - self.sub_style.primary_delay_sec;
        let sec_scale = if (0.80..=1.25).contains(&self.secondary_time_scale) {
            self.secondary_time_scale
        } else {
            1.0
        };
        let sec_pts = (pts - self.sub_style.secondary_delay_sec) / sec_scale;

        let canvas_resized = self.ass_canvas_w != canvas_w || self.ass_canvas_h != canvas_h;
        if canvas_resized {
            self.ass_canvas_w = canvas_w;
            self.ass_canvas_h = canvas_h;
            self.sub_dirty_y0 = 0;
            self.sub_dirty_y1 = 0;
        }
        if canvas_resized || self.sub_style_dirty {
            self.sync_ass_renderer_params(self.ass_renderer);
            self.sync_ass_renderer_params(self.secondary_ass_renderer);
        }

        let paired_rc = self.try_render_paired_bilingual(pts, pri_pts, sec_pts, sec_scale, canvas_w, canvas_h, canvas_resized);
        if paired_rc == 1 {
            return (true, self.sub_rgba_buf.as_ptr(), canvas_w, canvas_h, self.sub_serial);
        } else if paired_rc == 0 {
            return (false, ptr::null(), 0, 0, self.sub_serial);
        }
        if self.paired_layout_active {
            self.paired_layout_active = false;
            self.paired_layout_hash = 0;
            self.sub_style_dirty = true;
        }

        let mut pri_pgs: Option<PgsCue> = None;
        if self.has_bitmap_subs {
            while let Some(front) = self.pgs_cues.front() {
                if front.end_sec < pri_pts - 2.0 {
                    self.pgs_cues.pop_front();
                } else {
                    break;
                }
            }
            for cue in &self.pgs_cues {
                if pri_pts >= cue.start_sec && pri_pts < cue.end_sec && !cue.rects.is_empty() {
                    pri_pgs = Some(cue.clone());
                    break;
                }
            }
        }

        let mut sec_pgs: Option<PgsCue> = None;
        if self.secondary_has_bitmap_subs {
            while let Some(front) = self.secondary_pgs_cues.front() {
                if front.end_sec < sec_pts - 2.0 {
                    self.secondary_pgs_cues.pop_front();
                } else {
                    break;
                }
            }
            for cue in &self.secondary_pgs_cues {
                if sec_pts >= cue.start_sec && sec_pts < cue.end_sec && !cue.rects.is_empty() {
                    sec_pgs = Some(cue.clone());
                    break;
                }
            }
        }

        let mut change_pri: c_int = 0;
        let mut change_sec: c_int = 0;
        let img_pri = if !self.has_bitmap_subs && !self.ass_renderer.is_null() && !self.ass_track.is_null() {
            unsafe {
                ass_render_frame(
                    self.ass_renderer,
                    self.ass_track,
                    (pri_pts.max(0.0) * 1000.0) as c_longlong,
                    &mut change_pri,
                )
            }
        } else {
            ptr::null()
        };
        let sec_rend = if !self.secondary_ass_renderer.is_null() {
            self.secondary_ass_renderer
        } else {
            self.ass_renderer
        };
        let img_sec = if !self.secondary_has_bitmap_subs && !sec_rend.is_null() && !self.secondary_ass_track.is_null() {
            unsafe {
                ass_render_frame(
                    sec_rend,
                    self.secondary_ass_track,
                    (sec_pts.max(0.0) * 1000.0) as c_longlong,
                    &mut change_sec,
                )
            }
        } else {
            ptr::null()
        };

        let has_pri = pri_pgs.is_some() || !img_pri.is_null();
        let has_sec = sec_pgs.is_some() || !img_sec.is_null();
        if !has_pri && !has_sec {
            if self.sub_last_non_empty {
                self.clear_subtitle_canvas(canvas_w, canvas_h);
                self.sub_last_non_empty = false;
                self.rendered_pgs_gen = 0;
                self.rendered_secondary_pgs_gen = 0;
                self.sub_serial += 1;
            }
            return (false, ptr::null(), 0, 0, self.sub_serial);
        }

        let cur_pri_pgs_id = pri_pgs.as_ref().map(|c| c.id).unwrap_or(0);
        let cur_sec_pgs_id = sec_pgs.as_ref().map(|c| c.id).unwrap_or(0);
        let pri_pgs_changed = cur_pri_pgs_id != self.rendered_pgs_gen;
        let sec_pgs_changed = cur_sec_pgs_id != self.rendered_secondary_pgs_gen;
        let buf_mismatch = self.sub_rgba_buf.len() != (canvas_w as usize) * (canvas_h as usize) * 4;

        if pri_pgs_changed
            || sec_pgs_changed
            || change_pri != 0
            || change_sec != 0
            || !self.sub_last_non_empty
            || self.sub_style_dirty
            || canvas_resized
            || buf_mismatch
        {
            self.sub_style_dirty = false;
            self.clear_subtitle_canvas(canvas_w, canvas_h);

            // Fast single-layer direct path: avoids allocating/zeroing an extra 8.3 MB
            // scratch layer and pixel-by-pixel alpha blit when only primary ASS is active.
            if !has_sec && pri_pgs.is_none() && !img_pri.is_null() {
                let mut new_y0 = canvas_h;
                let mut new_y1 = 0;
                composite_ass_images_to_rgba(
                    img_pri,
                    &mut self.sub_rgba_buf,
                    canvas_w,
                    canvas_h,
                    0,
                    &mut new_y0,
                    &mut new_y1,
                );
                if new_y1 > new_y0 {
                    self.sub_dirty_y0 = new_y0;
                    self.sub_dirty_y1 = new_y1;
                }
            } else {
                let style_copy = self.sub_style;
                let margin_l = self.sub_margin_l;
                let margin_r = self.sub_margin_r;
                let margin_t = self.sub_margin_t;

                let pri_layer = if let Some(ref cue) = pri_pgs {
                    render_pgs_cue_to_layer(
                        &style_copy, margin_l, margin_r, cue, false, canvas_w, canvas_h, &mut self.sub_layer_pri_buf,
                    )
                } else if !img_pri.is_null() {
                    render_ass_images_to_layer(img_pri, canvas_w, canvas_h, &mut self.sub_layer_pri_buf)
                } else {
                    RenderedSubLayer { active: false, y0: canvas_h, y1: 0 }
                };

                let sec_layer = if let Some(ref cue) = sec_pgs {
                    render_pgs_cue_to_layer(
                        &style_copy, margin_l, margin_r, cue, true, canvas_w, canvas_h, &mut self.sub_layer_sec_buf,
                    )
                } else if !img_sec.is_null() {
                    render_ass_images_to_layer(img_sec, canvas_w, canvas_h, &mut self.sub_layer_sec_buf)
                } else {
                    RenderedSubLayer { active: false, y0: canvas_h, y1: 0 }
                };

                let (new_y0, new_y1) = composite_dual_layers(
                    &style_copy,
                    margin_t,
                    &pri_layer,
                    &self.sub_layer_pri_buf,
                    &sec_layer,
                    &self.sub_layer_sec_buf,
                    &mut self.sub_rgba_buf,
                    canvas_w,
                    canvas_h,
                );
                if new_y1 > new_y0 {
                    self.sub_dirty_y0 = new_y0;
                    self.sub_dirty_y1 = new_y1;
                }
            }
            self.rendered_pgs_gen = cur_pri_pgs_id;
            self.rendered_secondary_pgs_gen = cur_sec_pgs_id;
            self.sub_last_non_empty = true;
            self.sub_serial += 1;
        }

        (true, self.sub_rgba_buf.as_ptr(), canvas_w, canvas_h, self.sub_serial)
    }

    pub(super) fn raster_paired_line(
        &mut self,
        canvas_w: i32,
        canvas_h: i32,
        font_size: f64,
        spacing: f64,
        color_ass: &str,
        outline: f64,
        shadow: f64,
        margin_lr: i32,
        text: &str,
    ) -> PairedLineRaster {
        let mut out = PairedLineRaster {
            buf: Vec::new(),
            x0: canvas_w,
            x1: 0,
            y0: canvas_h,
            y1: 0,
        };
        if self.ass_lib.is_null() || text.is_empty() || canvas_w <= 0 || canvas_h <= 0 {
            return out;
        }
        if self.paired_ass_renderer.is_null() {
            self.paired_ass_renderer = unsafe { ass_renderer_init(self.ass_lib) };
            if !self.paired_ass_renderer.is_null() {
                unsafe {
                    ass_set_fonts(
                        self.paired_ass_renderer,
                        ptr::null(),
                        PINGFANG_CSTR.as_ptr() as *const c_char,
                        1,
                        ptr::null(),
                        1,
                    );
                }
            }
        }
        let ren = self.paired_ass_renderer;
        if ren.is_null() {
            return out;
        }

        unsafe {
            ass_set_frame_size(ren, canvas_w, canvas_h);
            ass_set_storage_size(ren, canvas_w, canvas_h);
            ass_set_margins(ren, 0, 0, 0, 0);
            ass_set_use_margins(ren, 1);
            ass_set_font_scale(ren, 1.0);
            ass_set_line_position(ren, 0.0);
        }

        let doc = format!(
            concat!(
                "[Script Info]\r\nScriptType: v4.00+\r\nPlayResX: {cw}\r\nPlayResY: {ch}\r\n",
                "ScaledBorderAndShadow: yes\r\nWrapStyle: 0\r\n",
                "[V4+ Styles]\r\n",
                "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\r\n",
                "Style: Default,PingFang SC,{fs:.2},{col},&H0000FFFF,&H10000000,&H80000000,-1,0,0,0,100,100,{sp:.2},0,1,{ol:.2},{sh:.2},2,{mlr},{mlr},16,1\r\n",
                "[Events]\r\n",
                "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n",
                "Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,{txt}\r\n"
            ),
            cw = canvas_w,
            ch = canvas_h,
            fs = font_size,
            col = color_ass,
            sp = spacing,
            ol = outline,
            sh = shadow,
            mlr = margin_lr,
            txt = text
        );

        let tr = unsafe { ass_read_memory(self.ass_lib, doc.as_ptr() as *const c_char, doc.len(), ptr::null()) };
        if tr.is_null() {
            return out;
        }
        let mut ch_flag: c_int = 0;
        let img = unsafe { ass_render_frame(ren, tr, 1000, &mut ch_flag) };

        let mut cur = img;
        while !cur.is_null() {
            let mut w = 0;
            let mut h = 0;
            let mut stride = 0;
            let mut bmp: *const u8 = ptr::null();
            let mut color = 0u32;
            let mut dst_x = 0;
            let mut dst_y = 0;
            let next = unsafe {
                dk_shim_ass_image_read(cur, &mut w, &mut h, &mut stride, &mut bmp, &mut color, &mut dst_x, &mut dst_y)
            };
            if w > 0 && h > 0 && !bmp.is_null() {
                out.x0 = out.x0.min(dst_x);
                out.x1 = out.x1.max(dst_x + w);
                out.y0 = out.y0.min(dst_y);
                out.y1 = out.y1.max(dst_y + h);
            }
            cur = next;
        }

        if out.x1 > out.x0 && out.y1 > out.y0 {
            let bw = out.w();
            let bh = out.h();
            out.buf.resize((bw as usize) * (bh as usize) * 4, 0);
            let mut cur2 = img;
            while !cur2.is_null() {
                let mut w = 0;
                let mut h = 0;
                let mut stride = 0;
                let mut bmp: *const u8 = ptr::null();
                let mut color = 0u32;
                let mut dst_x = 0;
                let mut dst_y = 0;
                let next = unsafe {
                    dk_shim_ass_image_read(
                        cur2, &mut w, &mut h, &mut stride, &mut bmp, &mut color, &mut dst_x, &mut dst_y,
                    )
                };
                let op = 255u32.saturating_sub(color & 0xFF);
                if w > 0 && h > 0 && !bmp.is_null() && op > 0 {
                    let r = (color >> 24) & 0xFF;
                    let g = (color >> 16) & 0xFF;
                    let b = (color >> 8) & 0xFF;
                    for y in 0..h {
                        let dy = dst_y + y - out.y0;
                        if dy < 0 || dy >= bh {
                            continue;
                        }
                        let src_row = unsafe { bmp.offset((y as isize) * (stride as isize)) };
                        let dst_row = &mut out.buf[(dy as usize) * (bw as usize) * 4..(dy as usize + 1) * (bw as usize) * 4];
                        for x in 0..w {
                            let dx = dst_x + x - out.x0;
                            if dx < 0 || dx >= bw {
                                continue;
                            }
                            let m = unsafe { *src_row.add(x as usize) } as u32;
                            let k = (m * op + 127) / 255;
                            if k == 0 {
                                continue;
                            }
                            let p = &mut dst_row[(dx as usize) * 4..(dx as usize) * 4 + 4];
                            let inv = 255 - k;
                            p[0] = ((r * k + 127) / 255 + (p[0] as u32 * inv + 127) / 255).min(255) as u8;
                            p[1] = ((g * k + 127) / 255 + (p[1] as u32 * inv + 127) / 255).min(255) as u8;
                            p[2] = ((b * k + 127) / 255 + (p[2] as u32 * inv + 127) / 255).min(255) as u8;
                            p[3] = (k + (p[3] as u32 * inv + 127) / 255).min(255) as u8;
                        }
                    }
                }
                cur2 = next;
            }
        }
        unsafe { ass_free_track(tr) };
        out
    }
}

fn composite_ass_images_to_rgba(
    img: *const c_void,
    rgba_buf: &mut [u8],
    canvas_w: i32,
    canvas_h: i32,
    y_offset: i32,
    inout_y0: &mut i32,
    inout_y1: &mut i32,
) {
    let mut cur = img;
    while !cur.is_null() {
        let mut w = 0;
        let mut h = 0;
        let mut stride = 0;
        let mut bmp: *const u8 = ptr::null();
        let mut color = 0u32;
        let mut dst_x = 0;
        let mut dst_y = 0;
        let next = unsafe {
            dk_shim_ass_image_read(cur, &mut w, &mut h, &mut stride, &mut bmp, &mut color, &mut dst_x, &mut dst_y)
        };
        let ca = 255u32.saturating_sub(color & 0xFF);
        if w > 0 && h > 0 && !bmp.is_null() && ca > 0 {
            let mut cr = ((color >> 24) & 0xFF) as i32;
            let mut cg = ((color >> 16) & 0xFF) as i32;
            let mut cb = ((color >> 8) & 0xFF) as i32;
            let max_c = cr.max(cg).max(cb);
            let min_c = cr.min(cg).min(cb);
            if max_c >= 140 && (max_c - min_c) <= 18 {
                let scale = 245.0f32 / (max_c as f32);
                cr = ((cr as f32 * scale).round() as i32).clamp(0, 255);
                cg = ((cg as f32 * scale).round() as i32).clamp(0, 255);
                cb = ((cb as f32 * scale).round() as i32).clamp(0, 255);
            }
            for y in 0..h {
                let dy = dst_y + y + y_offset;
                if dy < 0 || dy >= canvas_h {
                    continue;
                }
                *inout_y0 = (*inout_y0).min(dy);
                *inout_y1 = (*inout_y1).max(dy + 1);
                let mask_row = unsafe { bmp.offset((y as isize) * (stride as isize)) };
                let dst_row = &mut rgba_buf[(dy as usize) * (canvas_w as usize) * 4..(dy as usize + 1) * (canvas_w as usize) * 4];
                for x in 0..w {
                    let dx = dst_x + x;
                    if dx < 0 || dx >= canvas_w {
                        continue;
                    }
                    let m = unsafe { *mask_row.add(x as usize) } as u32;
                    if m == 0 {
                        continue;
                    }
                    let a = (m * ca + 127) / 255;
                    let sr = (cr as u32 * a + 127) / 255;
                    let sg = (cg as u32 * a + 127) / 255;
                    let sb = (cb as u32 * a + 127) / 255;
                    let dp = &mut dst_row[(dx as usize) * 4..(dx as usize) * 4 + 4];
                    let inv_a = 255 - a;
                    dp[0] = (sr + (dp[0] as u32 * inv_a + 127) / 255).min(255) as u8;
                    dp[1] = (sg + (dp[1] as u32 * inv_a + 127) / 255).min(255) as u8;
                    dp[2] = (sb + (dp[2] as u32 * inv_a + 127) / 255).min(255) as u8;
                    dp[3] = (a + (dp[3] as u32 * inv_a + 127) / 255).min(255) as u8;
                }
            }
        }
        cur = next;
    }
}

fn render_ass_images_to_layer(
    img: *const c_void,
    dst_w: i32,
    dst_h: i32,
    layer_buf: &mut Vec<u8>,
) -> RenderedSubLayer {
    let mut out = RenderedSubLayer { active: false, y0: dst_h, y1: 0 };
    if img.is_null() || dst_w <= 0 || dst_h <= 0 {
        return out;
    }
    let needed = (dst_w as usize) * (dst_h as usize) * 4;
    if layer_buf.len() != needed {
        layer_buf.clear();
        layer_buf.resize(needed, 0);
    } else {
        layer_buf.fill(0);
    }
    let mut y0 = dst_h;
    let mut y1 = 0;
    composite_ass_images_to_rgba(img, layer_buf, dst_w, dst_h, 0, &mut y0, &mut y1);
    if y1 > y0 {
        out.active = true;
        out.y0 = y0;
        out.y1 = y1;
    }
    out
}

fn blit_sub_layer_shifted(
    layer: &RenderedSubLayer,
    src_buf: &[u8],
    dst_rgba: &mut [u8],
    dst_w: i32,
    dst_h: i32,
    y_shift: i32,
    out_y0: &mut i32,
    out_y1: &mut i32,
) {
    if !layer.active || layer.y1 <= layer.y0 {
        return;
    }
    let row_bytes = (dst_w as usize) * 4;
    for sy in layer.y0..layer.y1 {
        let dy = sy + y_shift;
        if dy < 0 || dy >= dst_h {
            continue;
        }
        *out_y0 = (*out_y0).min(dy);
        *out_y1 = (*out_y1).max(dy + 1);
        let srow = &src_buf[(sy as usize) * row_bytes..(sy as usize + 1) * row_bytes];
        let drow = &mut dst_rgba[(dy as usize) * row_bytes..(dy as usize + 1) * row_bytes];
        for x in 0..(dst_w as usize) {
            let sa = srow[x * 4 + 3] as u32;
            if sa == 0 {
                continue;
            }
            let inv_a = 255 - sa;
            drow[x * 4] = (srow[x * 4] as u32 + (drow[x * 4] as u32 * inv_a + 127) / 255).min(255) as u8;
            drow[x * 4 + 1] = (srow[x * 4 + 1] as u32 + (drow[x * 4 + 1] as u32 * inv_a + 127) / 255).min(255) as u8;
            drow[x * 4 + 2] = (srow[x * 4 + 2] as u32 + (drow[x * 4 + 2] as u32 * inv_a + 127) / 255).min(255) as u8;
            drow[x * 4 + 3] = (sa + (drow[x * 4 + 3] as u32 * inv_a + 127) / 255).min(255) as u8;
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn composite_dual_layers(
    sub_style: &DKSubtitleStyleConfig,
    margin_t: i32,
    pri: &RenderedSubLayer,
    pri_buf: &[u8],
    sec: &RenderedSubLayer,
    sec_buf: &[u8],
    dst_rgba: &mut [u8],
    dst_w: i32,
    dst_h: i32,
) -> (i32, i32) {
    let mut out_y0 = dst_h;
    let mut out_y1 = 0;
    if !pri.active && !sec.active {
        return (out_y0, out_y1);
    }
    let gap = ((if sub_style.dual_gap_px >= 0.0 { sub_style.dual_gap_px } else { 10.0 }).round() as i32).clamp(0, 80);
    let primary_on_top = sub_style.primary_on_top;
    let layout_mode = sub_style.dual_layout_mode;

    if pri.active && !sec.active {
        blit_sub_layer_shifted(pri, pri_buf, dst_rgba, dst_w, dst_h, 0, &mut out_y0, &mut out_y1);
        return (out_y0, out_y1);
    }
    if !pri.active && sec.active {
        let sec_shift = if layout_mode == 1 {
            (margin_t / 4 + 14).max(14) - sec.y0
        } else {
            0
        };
        blit_sub_layer_shifted(sec, sec_buf, dst_rgba, dst_w, dst_h, sec_shift, &mut out_y0, &mut out_y1);
        return (out_y0, out_y1);
    }

    if layout_mode == 1 {
        blit_sub_layer_shifted(pri, pri_buf, dst_rgba, dst_w, dst_h, 0, &mut out_y0, &mut out_y1);
        let top_pad = (margin_t / 4 + 14).max(14);
        blit_sub_layer_shifted(sec, sec_buf, dst_rgba, dst_w, dst_h, top_pad - sec.y0, &mut out_y0, &mut out_y1);
        return (out_y0, out_y1);
    }

    let anchor_bottom = pri.y1.max(sec.y1);
    if primary_on_top {
        let sec_shift = anchor_bottom - sec.y1;
        let sec_placed_y0 = sec.y0 + sec_shift;
        let mut pri_shift = (sec_placed_y0 - gap) - pri.y1;
        if pri.y0 + pri_shift < 6 {
            pri_shift = 6 - pri.y0;
        }
        blit_sub_layer_shifted(sec, sec_buf, dst_rgba, dst_w, dst_h, sec_shift, &mut out_y0, &mut out_y1);
        blit_sub_layer_shifted(pri, pri_buf, dst_rgba, dst_w, dst_h, pri_shift, &mut out_y0, &mut out_y1);
    } else {
        let pri_shift = anchor_bottom - pri.y1;
        let pri_placed_y0 = pri.y0 + pri_shift;
        let mut sec_shift = (pri_placed_y0 - gap) - sec.y1;
        if sec.y0 + sec_shift < 6 {
            sec_shift = 6 - sec.y0;
        }
        blit_sub_layer_shifted(pri, pri_buf, dst_rgba, dst_w, dst_h, pri_shift, &mut out_y0, &mut out_y1);
        blit_sub_layer_shifted(sec, sec_buf, dst_rgba, dst_w, dst_h, sec_shift, &mut out_y0, &mut out_y1);
    }
    (out_y0, out_y1)
}

pub(super) fn blit_paired_raster(
    rl: &PairedLineRaster,
    dst_rgba: &mut [u8],
    dst_w: i32,
    dst_h: i32,
    dst_x: i32,
    dst_y: i32,
    out_y0: &mut i32,
    out_y1: &mut i32,
) {
    let bw = rl.w();
    let bh = rl.h();
    if bw <= 0 || bh <= 0 {
        return;
    }
    let dst_row_bytes = (dst_w as usize) * 4;
    let src_row_bytes = (bw as usize) * 4;
    for y in 0..bh {
        let dy = dst_y + y;
        if dy < 0 || dy >= dst_h {
            continue;
        }
        *out_y0 = (*out_y0).min(dy);
        *out_y1 = (*out_y1).max(dy + 1);
        let srow = &rl.buf[(y as usize) * src_row_bytes..(y as usize + 1) * src_row_bytes];
        let drow = &mut dst_rgba[(dy as usize) * dst_row_bytes..(dy as usize + 1) * dst_row_bytes];
        for x in 0..bw {
            let dx = dst_x + x;
            if dx < 0 || dx >= dst_w {
                continue;
            }
            let sx = (x as usize) * 4;
            let sa = srow[sx + 3] as u32;
            if sa == 0 {
                continue;
            }
            let inv = 255 - sa;
            let dp = &mut drow[(dx as usize) * 4..(dx as usize) * 4 + 4];
            dp[0] = (srow[sx] as u32 + (dp[0] as u32 * inv + 127) / 255).min(255) as u8;
            dp[1] = (srow[sx + 1] as u32 + (dp[1] as u32 * inv + 127) / 255).min(255) as u8;
            dp[2] = (srow[sx + 2] as u32 + (dp[2] as u32 * inv + 127) / 255).min(255) as u8;
            dp[3] = (sa + (dp[3] as u32 * inv + 127) / 255).min(255) as u8;
        }
    }
}
