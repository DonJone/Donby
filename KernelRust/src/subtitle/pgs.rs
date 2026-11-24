use super::*;
use super::ass_text::is_pale_yellow_rgb;

impl SubtitleEngine {
    pub fn decode_packet_for_slot(
        &mut self,
        fmt_ctx: *const c_void,
        pkt: *const c_void,
        stream_idx: i32,
        is_secondary: bool,
    ) {
        if fmt_ctx.is_null() || pkt.is_null() || stream_idx < 0 {
            return;
        }
        let codec_ctx = if is_secondary { self.secondary_sub_codec_ctx } else { self.sub_codec_ctx };
        struct DecodeCtx<'a> {
            eng: &'a mut SubtitleEngine,
            is_secondary: bool,
            pending_cue: Option<PgsCue>,
            raw_rects: Vec<(i32, i32, i32, i32, Vec<u8>, [u32; 256])>,
        }

        unsafe extern "C" fn on_text(
            ctx: *mut c_void,
            text: *const u8,
            len: usize,
            is_ass_rect: bool,
            evt_forced: bool,
            start_ms: i64,
            dur_ms: i64,
        ) {
            let d = &mut *(ctx as *mut DecodeCtx<'_>);
            if text.is_null() || len == 0 {
                return;
            }
            let raw = String::from_utf8_lossy(std::slice::from_raw_parts(text, len)).into_owned();
            let track = if d.is_secondary { d.eng.secondary_ass_track } else { d.eng.ass_track };
            if track.is_null() {
                return;
            }
            d.eng.ensure_ass_track_header_for(track, d.is_secondary);
            if is_ass_rect {
                let is_diag = raw.starts_with("Dialogue:");
                d.eng.feed_and_store_ass_event(d.is_secondary, raw, is_diag, evt_forced, start_ms, dur_ms);
            } else {
                let mut formatted = String::with_capacity(raw.len() + 8);
                for ch in raw.chars() {
                    if ch == '\r' {
                        continue;
                    } else if ch == '\n' {
                        formatted.push_str("\\N");
                    } else {
                        formatted.push(ch);
                    }
                }
                d.eng.sub_read_order += 1;
                let chunk = format!("{},0,Default,,0,0,0,,{}", d.eng.sub_read_order, formatted);
                d.eng.feed_and_store_ass_event(d.is_secondary, chunk, false, evt_forced, start_ms, dur_ms);
            }
        }

        unsafe extern "C" fn on_bmp_begin(
            ctx: *mut c_void,
            cue_start: f64,
            cue_end: f64,
            canvas_w: i32,
            canvas_h: i32,
            num_rects: u32,
        ) {
            let d = &mut *(ctx as *mut DecodeCtx<'_>);
            if d.is_secondary {
                d.eng.secondary_has_bitmap_subs = true;
                if let Some(back) = d.eng.secondary_pgs_cues.back_mut() {
                    if back.end_sec > cue_start {
                        back.end_sec = cue_start;
                    }
                }
            } else {
                d.eng.has_bitmap_subs = true;
                if let Some(back) = d.eng.pgs_cues.back_mut() {
                    if back.end_sec > cue_start {
                        back.end_sec = cue_start;
                    }
                }
            }
            if num_rects > 0 {
                let id = if d.is_secondary {
                    d.eng.secondary_pgs_generation += 1;
                    d.eng.secondary_pgs_generation
                } else {
                    d.eng.pgs_generation += 1;
                    d.eng.pgs_generation
                };
                d.pending_cue = Some(PgsCue {
                    id,
                    start_sec: cue_start,
                    end_sec: cue_end,
                    canvas_w,
                    canvas_h,
                    rects: Vec::with_capacity(num_rects as usize),
                });
                d.raw_rects.clear();
            }
        }

        unsafe extern "C" fn on_bmp_rect(
            ctx: *mut c_void,
            x: i32,
            y: i32,
            w: i32,
            h: i32,
            linesize: i32,
            indices: *const u8,
            palette256: *const u32,
            rect_forced: bool,
        ) {
            let d = &mut *(ctx as *mut DecodeCtx<'_>);
            if d.eng.sub_style.forced_only && !rect_forced {
                return;
            }
            if w <= 0 || h <= 0 || indices.is_null() || palette256.is_null() {
                return;
            }
            let mut pal = [0u32; 256];
            ptr::copy_nonoverlapping(palette256, pal.as_mut_ptr(), 256);
            let mut idx_packed = vec![0u8; (w as usize) * (h as usize)];
            for row in 0..(h as usize) {
                let src_row = indices.offset((row as isize) * (linesize as isize));
                ptr::copy_nonoverlapping(src_row, idx_packed.as_mut_ptr().add(row * (w as usize)), w as usize);
            }
            d.raw_rects.push((x, y, w, h, idx_packed, pal));
        }

        unsafe extern "C" fn on_bmp_end(ctx: *mut c_void) {
            let d = &mut *(ctx as *mut DecodeCtx<'_>);
            let Some(mut cue) = d.pending_cue.take() else { return };
            if d.raw_rects.is_empty() {
                return;
            }
            let mut cue_peak_luma = 0.0f32;
            for (_, _, _, _, idx_packed, pal) in &d.raw_rects {
                let mut seen = [false; 256];
                for &ix in idx_packed {
                    seen[ix as usize] = true;
                }
                for idx in 0..256 {
                    if !seen[idx] {
                        continue;
                    }
                    let argb = pal[idx];
                    let a = ((argb >> 24) & 0xFF) as u8;
                    if a < 96 {
                        continue;
                    }
                    let cr = ((argb >> 16) & 0xFF) as f32;
                    let cg = ((argb >> 8) & 0xFF) as f32;
                    let cb = (argb & 0xFF) as f32;
                    let luma = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb;
                    if luma > cue_peak_luma {
                        cue_peak_luma = luma;
                    }
                }
            }
            let pgs_luma_gain = if (80.0..205.0).contains(&cue_peak_luma) {
                (230.0 / cue_peak_luma).clamp(1.0, 1.65)
            } else {
                1.0
            };

            for &(x, y, w, h, ref idx_packed, ref pal) in &d.raw_rects {
                let mut rgba = vec![0u8; idx_packed.len() * 4];
                for (px_i, &ix) in idx_packed.iter().enumerate() {
                    let argb = pal[ix as usize];
                    let a = ((argb >> 24) & 0xFF) as u32;
                    let r0 = ((argb >> 16) & 0xFF) as f32;
                    let g0 = ((argb >> 8) & 0xFF) as f32;
                    let b0 = (argb & 0xFF) as f32;
                    let luma = 0.2126 * r0 + 0.7152 * g0 + 0.0722 * b0;
                    let w_gain = if luma <= 32.0 {
                        1.0
                    } else {
                        1.0 + (pgs_luma_gain - 1.0) * ((luma - 32.0) / 64.0).clamp(0.0, 1.0)
                    };
                    let cr = ((r0 * w_gain).round() as u32).min(255);
                    let cg = ((g0 * w_gain).round() as u32).min(255);
                    let cb = ((b0 * w_gain).round() as u32).min(255);
                    rgba[px_i * 4] = ((cr * a + 127) / 255) as u8;
                    rgba[px_i * 4 + 1] = ((cg * a + 127) / 255) as u8;
                    rgba[px_i * 4 + 2] = ((cb * a + 127) / 255) as u8;
                    rgba[px_i * 4 + 3] = a as u8;
                }
                cue.rects.push(PgsBitmapRect { x, y, w, h, rgba });
            }
            if !cue.rects.is_empty() {
                let slot = if d.is_secondary {
                    &mut d.eng.secondary_pgs_cues
                } else {
                    &mut d.eng.pgs_cues
                };
                if slot.len() >= 64 {
                    slot.pop_front();
                }
                slot.push_back(cue);
            }
        }

        let sh = self.sub_storage_h;
        let sw = self.sub_storage_w;
        let mut dctx = DecodeCtx {
            eng: self,
            is_secondary,
            pending_cue: None,
            raw_rects: Vec::new(),
        };
        unsafe {
            dk_shim_decode_subtitle_pkt(
                fmt_ctx,
                stream_idx,
                codec_ctx,
                pkt,
                sw,
                sh,
                &mut dctx as *mut DecodeCtx<'_> as *mut c_void,
                on_text,
                on_bmp_begin,
                on_bmp_rect,
                on_bmp_end,
            );
        }
    }
}

fn apply_pgs_pixel_overrides(
    sr: &mut u8,
    sg: &mut u8,
    sb: &mut u8,
    sa: &mut u8,
    is_secondary: bool,
    enhance_yellow: bool,
    border_width: f32,
) {
    if *sa == 0 {
        return;
    }
    let inv_a = 255.0f32 / (*sa as f32);
    let mut r = ((*sr as f32) * inv_a).min(255.0);
    let mut g = ((*sg as f32) * inv_a).min(255.0);
    let mut b = ((*sb as f32) * inv_a).min(255.0);
    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;

    if enhance_yellow && *sa >= 36 {
        let ur = r.round() as u8;
        let ug = g.round() as u8;
        let ub = b.round() as u8;
        if is_pale_yellow_rgb(ur, ug, ub) {
            let lum_scale = (luma / 205.0).clamp(0.35, 1.05);
            r = (255.0 * lum_scale).min(255.0);
            g = (178.0 * lum_scale).min(255.0);
            b = (46.0 * lum_scale).min(255.0);
        } else if is_secondary && luma >= 120.0 {
            let tint_w = ((luma - 120.0) / 80.0).clamp(0.0, 1.0);
            let lum_scale = (luma / 220.0).clamp(0.45, 1.04);
            let tr = (255.0 * lum_scale).min(255.0);
            let tg = (178.0 * lum_scale).min(255.0);
            let tb = (46.0 * lum_scale).min(255.0);
            r += (tr - r) * tint_w;
            g += (tg - g) * tint_w;
            b += (tb - b) * tint_w;
        }
    }

    if border_width > 3.0 && luma < 48.0 && *sa > 24 && *sa < 245 {
        let boost = 1.0 + ((border_width - 3.0) * 0.12).clamp(0.0, 0.35);
        *sa = (((*sa as f32) * boost).round() as i32).min(255) as u8;
    }

    let af = (*sa as f32) / 255.0;
    *sr = ((r * af).round() as i32).clamp(0, 255) as u8;
    *sg = ((g * af).round() as i32).clamp(0, 255) as u8;
    *sb = ((b * af).round() as i32).clamp(0, 255) as u8;
}

pub(super) fn render_pgs_cue_to_layer(
    sub_style: &DKSubtitleStyleConfig,
    margin_l: i32,
    margin_r: i32,
    cue: &PgsCue,
    is_secondary: bool,
    dst_w: i32,
    dst_h: i32,
    layer_buf: &mut Vec<u8>,
) -> RenderedSubLayer {
    let mut out = RenderedSubLayer { active: false, y0: dst_h, y1: 0 };
    if dst_w <= 0 || dst_h <= 0 || cue.rects.is_empty() {
        return out;
    }
    let needed = (dst_w as usize) * (dst_h as usize) * 4;
    if layer_buf.len() != needed {
        layer_buf.clear();
        layer_buf.resize(needed, 0);
    } else {
        layer_buf.fill(0);
    }

    let cue_w = cue.canvas_w.max(1);
    let cue_h = cue.canvas_h.max(1);
    let vid_area_w = (dst_w - margin_l - margin_r).max(1);
    let base_fit = ((vid_area_w as f32) / (cue_w as f32)).min((dst_h as f32) / (cue_h as f32));
    let user_scale = if sub_style.scale > 0.1 { sub_style.scale.clamp(0.5, 2.5) } else { 1.0 };
    let sec_rel = if sub_style.secondary_scale > 0.2 { sub_style.secondary_scale.clamp(0.5, 1.4) } else { 0.80 };
    let total_scale = base_fit * user_scale * if is_secondary { sec_rel } else { 1.0 };
    let pos_pct = if sub_style.vertical_pos_percent > 10.0 {
        sub_style.vertical_pos_percent.clamp(50.0, 100.0)
    } else {
        92.0
    };

    let mut union_x0 = cue_w;
    let mut union_y0 = cue_h;
    let mut union_x1 = 0;
    let mut union_y1 = 0;
    for r in &cue.rects {
        union_x0 = union_x0.min(r.x);
        union_y0 = union_y0.min(r.y);
        union_x1 = union_x1.max(r.x + r.w);
        union_y1 = union_y1.max(r.y + r.h);
    }
    let union_cx_src = 0.5 * ((union_x0 + union_x1) as f32);
    let union_cx_dst = (margin_l as f32) + (union_cx_src / (cue_w as f32)) * (vid_area_w as f32);
    let union_h_src = ((union_y1 - union_y0) as f32).max(1.0);
    let scaled_union_h = union_h_src * total_scale;
    let target_bottom = ((pos_pct * 0.01) * (dst_h as f32) - 6.0).clamp(scaled_union_h + 8.0, (dst_h - 4) as f32);

    let mut new_y0 = dst_h;
    let mut new_y1 = 0;
    for r in &cue.rects {
        if r.w <= 0 || r.h <= 0 || r.rgba.is_empty() {
            continue;
        }
        let sw = (((r.w as f32) * total_scale).round() as i32).max(1);
        let sh = (((r.h as f32) * total_scale).round() as i32).max(1);
        let rel_x = ((r.x as f32) - union_cx_src) * total_scale;
        let rel_bottom = ((union_y1 - (r.y + r.h)) as f32) * total_scale;
        let base_x = ((union_cx_dst + rel_x).round() as i32).clamp(0, (dst_w - sw).max(0));
        let base_y = ((target_bottom - rel_bottom - (sh as f32)).round() as i32).clamp(4, (dst_h - sh - 4).max(4));

        for y in 0..sh {
            let dy = base_y + y;
            if dy < 0 || dy >= dst_h {
                continue;
            }
            let fy = ((y as f32) + 0.5) / total_scale - 0.5;
            let sy0 = (fy.floor() as i32).clamp(0, r.h - 1);
            let sy1 = (sy0 + 1).clamp(0, r.h - 1);
            let wy = (fy - (sy0 as f32)).clamp(0.0, 1.0);
            for x in 0..sw {
                let dx = base_x + x;
                if dx < 0 || dx >= dst_w {
                    continue;
                }
                let fx = ((x as f32) + 0.5) / total_scale - 0.5;
                let sx0 = (fx.floor() as i32).clamp(0, r.w - 1);
                let sx1 = (sx0 + 1).clamp(0, r.w - 1);
                let wx = (fx - (sx0 as f32)).clamp(0.0, 1.0);

                let p00 = &r.rgba[((sy0 * r.w + sx0) as usize) * 4..][..4];
                let p10 = &r.rgba[((sy0 * r.w + sx1) as usize) * 4..][..4];
                let p01 = &r.rgba[((sy1 * r.w + sx0) as usize) * 4..][..4];
                let p11 = &r.rgba[((sy1 * r.w + sx1) as usize) * 4..][..4];
                let w00 = (1.0 - wx) * (1.0 - wy);
                let w10 = wx * (1.0 - wy);
                let w01 = (1.0 - wx) * wy;
                let w11 = wx * wy;
                let mut sr = ((p00[0] as f32 * w00 + p10[0] as f32 * w10 + p01[0] as f32 * w01 + p11[0] as f32 * w11).round() as i32).clamp(0, 255) as u8;
                let mut sg = ((p00[1] as f32 * w00 + p10[1] as f32 * w10 + p01[1] as f32 * w01 + p11[1] as f32 * w11).round() as i32).clamp(0, 255) as u8;
                let mut sb = ((p00[2] as f32 * w00 + p10[2] as f32 * w10 + p01[2] as f32 * w01 + p11[2] as f32 * w11).round() as i32).clamp(0, 255) as u8;
                let mut sa = ((p00[3] as f32 * w00 + p10[3] as f32 * w10 + p01[3] as f32 * w01 + p11[3] as f32 * w11).round() as i32).clamp(0, 255) as u8;
                if sa == 0 {
                    continue;
                }
                apply_pgs_pixel_overrides(
                    &mut sr,
                    &mut sg,
                    &mut sb,
                    &mut sa,
                    is_secondary,
                    sub_style.enhance_secondary_yellow,
                    sub_style.border_width,
                );
                new_y0 = new_y0.min(dy);
                new_y1 = new_y1.max(dy + 1);

                let dp = &mut layer_buf[((dy * dst_w + dx) as usize) * 4..][..4];
                let inv_a = 255 - (sa as u32);
                dp[0] = ((sr as u32) + (dp[0] as u32 * inv_a + 127) / 255).min(255) as u8;
                dp[1] = ((sg as u32) + (dp[1] as u32 * inv_a + 127) / 255).min(255) as u8;
                dp[2] = ((sb as u32) + (dp[2] as u32 * inv_a + 127) / 255).min(255) as u8;
                dp[3] = ((sa as u32) + (dp[3] as u32 * inv_a + 127) / 255).min(255) as u8;
            }
        }
    }
    if new_y1 > new_y0 {
        out.active = true;
        out.y0 = new_y0;
        out.y1 = new_y1;
    }
    out
}
