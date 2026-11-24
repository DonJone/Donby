use crate::abi::{DKSubtitleInterval, DKSubtitleStyleConfig};
use crate::ffi::*;
use std::collections::VecDeque;
use std::ffi::{c_char, c_int, c_longlong, c_void, CStr, CString};
use std::ptr;

const PINGFANG_CSTR: &[u8] = b"PingFang SC\0";
const CLASSIC_GOLD_YELLOW_RGBA: u32 = 0xFFB22E00;

#[derive(Clone)]
struct PgsBitmapRect {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    rgba: Vec<u8>,
}

#[derive(Clone)]
struct PgsCue {
    id: u64,
    start_sec: f64,
    end_sec: f64,
    canvas_w: i32,
    canvas_h: i32,
    rects: Vec<PgsBitmapRect>,
}

#[derive(Clone)]
struct StoredAssEvent {
    start_ms: i64,
    dur_ms: i64,
    raw_line: String,
    is_full_dialogue: bool,
    is_forced: bool,
}

#[derive(Clone)]
struct OriginalAssStyle {
    font_name: String,
    font_size: f64,
    outline: f64,
    margin_v: i32,
    primary_colour: u32,
    scale_x: f64,
    scale_y: f64,
    alignment: i32,
    border_style: i32,
}

struct RenderedSubLayer {
    active: bool,
    y0: i32,
    y1: i32,
}

struct PairedLineRaster {
    buf: Vec<u8>,
    x0: i32,
    x1: i32,
    y0: i32,
    y1: i32,
}

impl PairedLineRaster {
    #[inline]
    fn w(&self) -> i32 {
        (self.x1 - self.x0).max(0)
    }
    #[inline]
    fn h(&self) -> i32 {
        (self.y1 - self.y0).max(0)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct SemanticTurn {
    pri_lines: Vec<String>,
    sec_lines: Vec<String>,
}

pub struct SubtitleEngine {
    ass_lib: *mut c_void,
    ass_renderer: *mut c_void,
    secondary_ass_renderer: *mut c_void,
    paired_ass_renderer: *mut c_void,
    ass_track: *mut c_void,
    secondary_ass_track: *mut c_void,

    pub sub_codec_ctx: *mut c_void,
    pub secondary_sub_codec_ctx: *mut c_void,

    pub ass_canvas_w: i32,
    pub ass_canvas_h: i32,
    pub sub_storage_w: i32,
    pub sub_storage_h: i32,
    pub sub_margin_t: i32,
    pub sub_margin_b: i32,
    pub sub_margin_l: i32,
    pub sub_margin_r: i32,

    pub has_bitmap_subs: bool,
    pgs_cues: VecDeque<PgsCue>,
    pgs_generation: u64,
    rendered_pgs_gen: u64,

    pub secondary_has_bitmap_subs: bool,
    secondary_pgs_cues: VecDeque<PgsCue>,
    secondary_pgs_generation: u64,
    rendered_secondary_pgs_gen: u64,

    sub_rgba_buf: Vec<u8>,
    sub_layer_pri_buf: Vec<u8>,
    sub_layer_sec_buf: Vec<u8>,

    pub sub_serial: u64,
    sub_read_order: u64,
    pub sub_last_non_empty: bool,
    pub sub_style_dirty: bool,
    paired_layout_active: bool,
    paired_layout_hash: u64,
    pub sub_dirty_y0: i32,
    pub sub_dirty_y1: i32,
    pub secondary_time_scale: f64,
    pub sub_style: DKSubtitleStyleConfig,

    primary_orig_track_ptr: usize,
    primary_orig_styles: Vec<OriginalAssStyle>,
    secondary_orig_track_ptr: usize,
    secondary_orig_styles: Vec<OriginalAssStyle>,

    primary_codec_private: Vec<u8>,
    secondary_codec_private: Vec<u8>,
    primary_ass_events: Vec<StoredAssEvent>,
    secondary_ass_events: Vec<StoredAssEvent>,
    primary_ext_raw: String,
    primary_ext_is_ass: bool,
    secondary_ext_raw: String,
    secondary_ext_is_ass: bool,
}

unsafe impl Send for SubtitleEngine {}

impl SubtitleEngine {
    pub fn new() -> Self {
        let ass_lib = unsafe { ass_library_init() };
        let mut ass_renderer = ptr::null_mut();
        if !ass_lib.is_null() {
            ass_renderer = unsafe { ass_renderer_init(ass_lib) };
            if !ass_renderer.is_null() {
                unsafe {
                    ass_set_fonts(
                        ass_renderer,
                        ptr::null(),
                        PINGFANG_CSTR.as_ptr() as *const c_char,
                        1,
                        ptr::null(),
                        1,
                    );
                }
            }
        }
        Self {
            ass_lib,
            ass_renderer,
            secondary_ass_renderer: ptr::null_mut(),
            paired_ass_renderer: ptr::null_mut(),
            ass_track: ptr::null_mut(),
            secondary_ass_track: ptr::null_mut(),
            sub_codec_ctx: ptr::null_mut(),
            secondary_sub_codec_ctx: ptr::null_mut(),
            ass_canvas_w: 0,
            ass_canvas_h: 0,
            sub_storage_w: 1920,
            sub_storage_h: 1080,
            sub_margin_t: 0,
            sub_margin_b: 0,
            sub_margin_l: 0,
            sub_margin_r: 0,
            has_bitmap_subs: false,
            pgs_cues: VecDeque::new(),
            pgs_generation: 0,
            rendered_pgs_gen: 0,
            secondary_has_bitmap_subs: false,
            secondary_pgs_cues: VecDeque::new(),
            secondary_pgs_generation: 0,
            rendered_secondary_pgs_gen: 0,
            sub_rgba_buf: Vec::new(),
            sub_layer_pri_buf: Vec::new(),
            sub_layer_sec_buf: Vec::new(),
            sub_serial: 0,
            sub_read_order: 0,
            sub_last_non_empty: false,
            sub_style_dirty: false,
            paired_layout_active: false,
            paired_layout_hash: 0,
            sub_dirty_y0: 0,
            sub_dirty_y1: 0,
            secondary_time_scale: 1.0,
            sub_style: DKSubtitleStyleConfig::default(),
            primary_orig_track_ptr: 0,
            primary_orig_styles: Vec::new(),
            secondary_orig_track_ptr: 0,
            secondary_orig_styles: Vec::new(),
            primary_codec_private: Vec::new(),
            secondary_codec_private: Vec::new(),
            primary_ass_events: Vec::new(),
            secondary_ass_events: Vec::new(),
            primary_ext_raw: String::new(),
            primary_ext_is_ass: false,
            secondary_ext_raw: String::new(),
            secondary_ext_is_ass: false,
        }
    }

    pub fn close_stream_state(&mut self) {
        unsafe {
            dk_shim_close_codec(&mut self.sub_codec_ctx);
            dk_shim_close_codec(&mut self.secondary_sub_codec_ctx);
            if !self.secondary_ass_track.is_null() {
                ass_free_track(self.secondary_ass_track);
                self.secondary_ass_track = ptr::null_mut();
            }
        }
        self.primary_ass_events.clear();
        self.secondary_ass_events.clear();
        self.primary_codec_private.clear();
        self.secondary_codec_private.clear();
        self.primary_ext_raw.clear();
        self.secondary_ext_raw.clear();
        self.pgs_cues.clear();
        self.secondary_pgs_cues.clear();
        self.has_bitmap_subs = false;
        self.secondary_has_bitmap_subs = false;
        self.secondary_time_scale = 1.0;
    }

    pub fn ensure_default_primary_track(&mut self) {
        if !self.ass_lib.is_null() && self.ass_track.is_null() {
            self.ass_track = unsafe { ass_new_track(self.ass_lib) };
            self.ensure_ass_track_header_for(self.ass_track, false);
        }
    }

    pub fn flush_for_seek(&mut self, has_primary_stream: bool, has_secondary_stream: bool) {
        unsafe {
            if has_primary_stream {
                if !self.sub_codec_ctx.is_null() {
                    dk_shim_flush_codec(self.sub_codec_ctx);
                }
                if !self.ass_track.is_null() {
                    ass_flush_events(self.ass_track);
                }
                self.primary_ass_events.clear();
                self.pgs_cues.clear();
                self.pgs_generation += 1;
            }
            if has_secondary_stream {
                if !self.secondary_sub_codec_ctx.is_null() {
                    dk_shim_flush_codec(self.secondary_sub_codec_ctx);
                }
                if !self.secondary_ass_track.is_null() {
                    ass_flush_events(self.secondary_ass_track);
                }
                self.secondary_ass_events.clear();
                self.secondary_pgs_cues.clear();
                self.secondary_pgs_generation += 1;
            }
        }
        if !self.sub_rgba_buf.is_empty() && self.ass_canvas_w > 0 && self.ass_canvas_h > 0 {
            let y0 = self.sub_dirty_y0.clamp(0, self.ass_canvas_h);
            let y1 = self.sub_dirty_y1.clamp(y0, self.ass_canvas_h);
            if y1 > y0 {
                let row_bytes = (self.ass_canvas_w as usize) * 4;
                let off = (y0 as usize) * row_bytes;
                let end = (y1 as usize) * row_bytes;
                if end <= self.sub_rgba_buf.len() {
                    self.sub_rgba_buf[off..end].fill(0);
                }
            }
        }
        self.rendered_pgs_gen = 0;
        self.rendered_secondary_pgs_gen = 0;
        self.sub_last_non_empty = false;
        self.paired_layout_active = false;
        self.paired_layout_hash = 0;
        self.sub_dirty_y0 = 0;
        self.sub_dirty_y1 = 0;
        self.sub_serial += 1;
    }

    pub fn open_stream_decoder(
        &mut self,
        fmt_ctx: *const c_void,
        stream_idx: i32,
        is_secondary: bool,
        video_w: i32,
        video_h: i32,
    ) {
        unsafe {
            if is_secondary {
                dk_shim_close_codec(&mut self.secondary_sub_codec_ctx);
                if !self.secondary_ass_track.is_null() {
                    ass_free_track(self.secondary_ass_track);
                    self.secondary_ass_track = ptr::null_mut();
                }
                self.secondary_codec_private.clear();
                self.secondary_ass_events.clear();
                self.secondary_ext_raw.clear();
                self.secondary_pgs_cues.clear();
                self.secondary_pgs_generation += 1;
                self.rendered_secondary_pgs_gen = 0;
                self.secondary_has_bitmap_subs = false;
            } else {
                dk_shim_close_codec(&mut self.sub_codec_ctx);
                if !self.ass_track.is_null() {
                    ass_free_track(self.ass_track);
                    self.ass_track = ptr::null_mut();
                }
                self.primary_codec_private.clear();
                self.primary_ass_events.clear();
                self.primary_ext_raw.clear();
                self.pgs_cues.clear();
                self.pgs_generation += 1;
                self.rendered_pgs_gen = 0;
                self.has_bitmap_subs = false;
            }
        }
        self.sub_rgba_buf.clear();
        self.sub_last_non_empty = false;
        self.paired_layout_active = false;
        self.paired_layout_hash = 0;
        self.sub_dirty_y0 = 0;
        self.sub_dirty_y1 = 0;
        self.sub_serial += 1;

        if fmt_ctx.is_null() || stream_idx < 0 {
            return;
        }
        let mut meta = DKShimStreamMeta::default();
        if !unsafe { dk_shim_get_stream_meta(fmt_ctx, stream_idx as u32, &mut meta) } || meta.codec_type != 2 {
            return;
        }

        let track = if !self.ass_lib.is_null() {
            unsafe { ass_new_track(self.ass_lib) }
        } else {
            ptr::null_mut()
        };
        if is_secondary {
            self.secondary_ass_track = track;
        } else {
            self.ass_track = track;
            if meta.width > 0 && meta.height > 0 {
                self.sub_storage_w = meta.width;
                self.sub_storage_h = meta.height;
            } else if video_w > 0 && video_h > 0 {
                self.sub_storage_w = video_w;
                self.sub_storage_h = video_h;
            }
        }

        let mut codec_ctx: *mut c_void = ptr::null_mut();
        let mut sub_hdr: *const u8 = ptr::null();
        let mut sub_hdr_len: i32 = 0;
        let mut dec_name = [0 as c_char; 32];
        let open_rc = unsafe {
            dk_shim_open_sub_decoder(
                fmt_ctx,
                stream_idx,
                &mut codec_ctx,
                &mut sub_hdr,
                &mut sub_hdr_len,
                dec_name.as_mut_ptr(),
            )
        };

        if open_rc < 0 || codec_ctx.is_null() {
            if !track.is_null() && !meta.extradata.is_null() && meta.extradata_size > 0 {
                let slice = unsafe { std::slice::from_raw_parts(meta.extradata, meta.extradata_size as usize) };
                if is_secondary {
                    self.secondary_codec_private = slice.to_vec();
                } else {
                    self.primary_codec_private = slice.to_vec();
                }
                unsafe { ass_process_codec_private(track, slice.as_ptr() as *const c_char, slice.len() as c_int) };
            }
            self.ensure_ass_track_header_for(track, is_secondary);
            return;
        }

        if is_secondary {
            self.secondary_sub_codec_ctx = codec_ctx;
        } else {
            self.sub_codec_ctx = codec_ctx;
        }

        if !track.is_null() {
            if meta.is_ass_or_ssa {
                if !meta.extradata.is_null() && meta.extradata_size > 0 {
                    let slice = unsafe { std::slice::from_raw_parts(meta.extradata, meta.extradata_size as usize) };
                    if is_secondary {
                        self.secondary_codec_private = slice.to_vec();
                    } else {
                        self.primary_codec_private = slice.to_vec();
                    }
                    unsafe { ass_process_codec_private(track, slice.as_ptr() as *const c_char, slice.len() as c_int) };
                } else if !sub_hdr.is_null() && sub_hdr_len > 0 {
                    let slice = unsafe { std::slice::from_raw_parts(sub_hdr, sub_hdr_len as usize) };
                    if is_secondary {
                        self.secondary_codec_private = slice.to_vec();
                    } else {
                        self.primary_codec_private = slice.to_vec();
                    }
                    unsafe { ass_process_codec_private(track, slice.as_ptr() as *const c_char, slice.len() as c_int) };
                }
            }
            self.ensure_ass_track_header_for(track, is_secondary);
        }
    }

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

    fn feed_and_store_ass_event(
        &mut self,
        is_secondary: bool,
        raw_str: String,
        is_dialogue: bool,
        evt_forced: bool,
        start_ms: i64,
        dur_ms: i64,
    ) {
        let track = if is_secondary { self.secondary_ass_track } else { self.ass_track };
        if track.is_null() {
            return;
        }
        let events = if is_secondary {
            &mut self.secondary_ass_events
        } else {
            &mut self.primary_ass_events
        };
        if events.len() < 4096 {
            events.push(StoredAssEvent {
                start_ms,
                dur_ms,
                raw_line: raw_str.clone(),
                is_full_dialogue: is_dialogue,
                is_forced: evt_forced,
            });
        }
        if self.sub_style.forced_only && !evt_forced {
            return;
        }
        let transformed = transform_ass_line(
            &raw_str,
            self.sub_style.text_transform,
            is_dialogue,
            self.sub_style.unify_pingfang_font,
            self.sub_style.enhance_secondary_yellow,
        );
        unsafe {
            if is_dialogue {
                ass_process_data(track, transformed.as_ptr() as *const c_char, transformed.len() as c_int);
            } else {
                ass_process_chunk(
                    track,
                    transformed.as_ptr() as *const c_char,
                    transformed.len() as c_int,
                    start_ms as c_longlong,
                    dur_ms as c_longlong,
                );
            }
        }
    }

    pub fn load_external_subtitle(&mut self, content_utf8: &str, is_ass: bool, is_secondary: bool) {
        if self.ass_lib.is_null() {
            return;
        }
        unsafe {
            if is_secondary {
                dk_shim_close_codec(&mut self.secondary_sub_codec_ctx);
                self.secondary_ass_events.clear();
                self.secondary_codec_private.clear();
                self.secondary_pgs_cues.clear();
                self.secondary_has_bitmap_subs = false;
                self.secondary_time_scale = 1.0;
                self.rendered_secondary_pgs_gen = 0;
                self.secondary_ext_raw = content_utf8.to_owned();
                self.secondary_ext_is_ass = is_ass;
            } else {
                dk_shim_close_codec(&mut self.sub_codec_ctx);
                self.primary_ass_events.clear();
                self.primary_codec_private.clear();
                self.pgs_cues.clear();
                self.has_bitmap_subs = false;
                self.rendered_pgs_gen = 0;
                self.primary_ext_raw = content_utf8.to_owned();
                self.primary_ext_is_ass = is_ass;
            }
        }
        self.sub_rgba_buf.clear();
        self.sub_last_non_empty = false;
        self.sub_style_dirty = true;
        self.paired_layout_active = false;
        self.paired_layout_hash = 0;
        self.sub_dirty_y0 = 0;
        self.sub_dirty_y1 = 0;
        self.sub_serial += 1;
        let raw = if is_secondary {
            self.secondary_ext_raw.clone()
        } else {
            self.primary_ext_raw.clone()
        };
        self.populate_external_track(&raw, is_ass, is_secondary);
    }

    fn populate_external_track(&mut self, raw_utf8: &str, is_ass: bool, is_secondary: bool) {
        let cur_track = if is_secondary { self.secondary_ass_track } else { self.ass_track };
        if !cur_track.is_null() {
            unsafe { ass_free_track(cur_track) };
            if is_secondary {
                self.secondary_ass_track = ptr::null_mut();
            } else {
                self.ass_track = ptr::null_mut();
            }
        }
        if raw_utf8.is_empty() || self.ass_lib.is_null() {
            return;
        }
        if is_ass {
            let transformed = transform_ass_document(
                raw_utf8,
                self.sub_style.text_transform,
                self.sub_style.unify_pingfang_font,
                self.sub_style.enhance_secondary_yellow,
            );
            let tr = unsafe {
                ass_read_memory(
                    self.ass_lib,
                    transformed.as_ptr() as *const c_char,
                    transformed.len(),
                    ptr::null(),
                )
            };
            if is_secondary {
                self.secondary_ass_track = tr;
            } else {
                self.ass_track = tr;
            }
            if !tr.is_null() {
                self.ensure_ass_track_header_for(tr, is_secondary);
            }
            return;
        }

        let tr = unsafe { ass_new_track(self.ass_lib) };
        if tr.is_null() {
            return;
        }
        if is_secondary {
            self.secondary_ass_track = tr;
        } else {
            self.ass_track = tr;
        }
        self.ensure_ass_track_header_for(tr, is_secondary);

        let text = raw_utf8.strip_prefix('\u{feff}').unwrap_or(raw_utf8);
        let mut cue_start: i64 = -1;
        let mut cue_end: i64 = -1;
        let mut cue_body = String::new();

        let flush_cue = |this: &mut Self, cs: &mut i64, ce: &mut i64, body: &mut String| {
            if *cs >= 0 && *ce > *cs && !body.is_empty() {
                let mut sanitized = sanitize_srt_vtt_tags(body);
                if !is_secondary && this.sub_style.enhance_secondary_yellow {
                    if let Some(br) = sanitized.find("\\N") {
                        if br > 0 && br + 2 < sanitized.len() {
                            let line1 = &sanitized[..br];
                            let line2 = &sanitized[br + 2..];
                            if has_cjk_utf8(line1)
                                && is_mostly_latin_line(line2)
                                && !line2.contains("\\c&")
                                && !line2.contains("\\1c&")
                            {
                                sanitized = format!("{line1}\\N{{\\fscx62\\fscy62\\1c&H002EB2FF&}}{line2}");
                            }
                        }
                    }
                }
                let transformed = transform_ass_payload(
                    &sanitized,
                    this.sub_style.text_transform,
                    this.sub_style.unify_pingfang_font,
                    this.sub_style.enhance_secondary_yellow,
                );
                this.sub_read_order += 1;
                let chunk = format!("{},0,Default,,0,0,0,,{}", this.sub_read_order, transformed);
                unsafe {
                    ass_process_chunk(
                        tr,
                        chunk.as_ptr() as *const c_char,
                        chunk.len() as c_int,
                        *cs as c_longlong,
                        (*ce - *cs) as c_longlong,
                    );
                }
            }
            *cs = -1;
            *ce = -1;
            body.clear();
        };

        for raw_line in text.split('\n') {
            let line = raw_line.strip_suffix('\r').unwrap_or(raw_line);
            if line.is_empty() {
                flush_cue(self, &mut cue_start, &mut cue_end, &mut cue_body);
                continue;
            }
            if cue_start < 0
                && (line.starts_with("WEBVTT") || line.starts_with("NOTE") || line.starts_with("STYLE"))
            {
                continue;
            }
            if let Some(arrow) = line.find("-->") {
                flush_cue(self, &mut cue_start, &mut cue_end, &mut cue_body);
                let lhs = line[..arrow].trim_start();
                let rhs_full = line[arrow + 3..].trim_start();
                let rhs = rhs_full.split([' ', '\t']).next().unwrap_or(rhs_full);
                cue_start = parse_srt_time_ms(lhs);
                cue_end = parse_srt_time_ms(rhs);
            } else if cue_start >= 0 {
                if !cue_body.is_empty() {
                    cue_body.push_str("\\N");
                }
                cue_body.push_str(line);
            }
        }
        flush_cue(self, &mut cue_start, &mut cue_end, &mut cue_body);
    }

    fn rebuild_embedded_ass_track(&mut self, is_secondary: bool) {
        let old = if is_secondary { self.secondary_ass_track } else { self.ass_track };
        if !old.is_null() {
            unsafe { ass_free_track(old) };
            if is_secondary {
                self.secondary_ass_track = ptr::null_mut();
            } else {
                self.ass_track = ptr::null_mut();
            }
        }
        if self.ass_lib.is_null() {
            return;
        }
        let tr = unsafe { ass_new_track(self.ass_lib) };
        if tr.is_null() {
            return;
        }
        if is_secondary {
            self.secondary_ass_track = tr;
        } else {
            self.ass_track = tr;
        }
        let priv_bytes = if is_secondary {
            &self.secondary_codec_private
        } else {
            &self.primary_codec_private
        };
        if !priv_bytes.is_empty() {
            unsafe {
                ass_process_codec_private(tr, priv_bytes.as_ptr() as *const c_char, priv_bytes.len() as c_int);
            }
        }
        self.ensure_ass_track_header_for(tr, is_secondary);
        let events = if is_secondary {
            self.secondary_ass_events.clone()
        } else {
            self.primary_ass_events.clone()
        };
        for ev in &events {
            if self.sub_style.forced_only && !ev.is_forced {
                continue;
            }
            let transformed = transform_ass_line(
                &ev.raw_line,
                self.sub_style.text_transform,
                ev.is_full_dialogue,
                self.sub_style.unify_pingfang_font,
                self.sub_style.enhance_secondary_yellow,
            );
            unsafe {
                if ev.is_full_dialogue {
                    ass_process_data(tr, transformed.as_ptr() as *const c_char, transformed.len() as c_int);
                } else {
                    ass_process_chunk(
                        tr,
                        transformed.as_ptr() as *const c_char,
                        transformed.len() as c_int,
                        ev.start_ms as c_longlong,
                        ev.dur_ms as c_longlong,
                    );
                }
            }
        }
    }

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

    fn sync_ass_renderer_params(&self, ren: *mut c_void) {
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

    fn ensure_ass_track_header_for(&mut self, track: *mut c_void, is_secondary: bool) {
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

    fn clear_subtitle_canvas(&mut self, target_w: i32, target_h: i32) {
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
            self.rendered_pgs_gen = cur_pri_pgs_id;
            self.rendered_secondary_pgs_gen = cur_sec_pgs_id;
            self.sub_last_non_empty = true;
            self.sub_serial += 1;
        }

        (true, self.sub_rgba_buf.as_ptr(), canvas_w, canvas_h, self.sub_serial)
    }

    fn raster_paired_line(
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

    fn try_render_paired_bilingual(
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

impl Drop for SubtitleEngine {
    fn drop(&mut self) {
        self.close_stream_state();
        unsafe {
            if !self.ass_track.is_null() {
                ass_free_track(self.ass_track);
                self.ass_track = ptr::null_mut();
            }
            if !self.ass_renderer.is_null() {
                ass_renderer_done(self.ass_renderer);
                self.ass_renderer = ptr::null_mut();
            }
            if !self.secondary_ass_renderer.is_null() {
                ass_renderer_done(self.secondary_ass_renderer);
                self.secondary_ass_renderer = ptr::null_mut();
            }
            if !self.paired_ass_renderer.is_null() {
                ass_renderer_done(self.paired_ass_renderer);
                self.paired_ass_renderer = ptr::null_mut();
            }
            if !self.ass_lib.is_null() {
                ass_library_done(self.ass_lib);
                self.ass_lib = ptr::null_mut();
            }
        }
    }
}

// -----------------------------------------------------------------------------
// Pure Subtitle Formatting, Compositing & Pair-A Semantic Pairing Helpers
// -----------------------------------------------------------------------------

fn cf_transform_segment(seg: &str, mode: i32) -> String {
    if mode == 0 || seg.is_empty() {
        return seg.to_owned();
    }
    let cap = seg.len() * 4 + 32;
    let mut dst = vec![0u8; cap];
    let written = unsafe { dk_shim_cf_transform_utf8(seg.as_ptr(), seg.len(), mode, dst.as_mut_ptr(), cap) };
    if written == 0 {
        return seg.to_owned();
    }
    String::from_utf8_lossy(&dst[..written]).into_owned()
}

fn is_pale_yellow_rgb(r: u8, g: u8, b: u8) -> bool {
    if r < 175 || g < 145 {
        return false;
    }
    if (r as i32) - (b as i32) < 16 {
        return false;
    }
    if (g as i32) - (b as i32) < 12 {
        return false;
    }
    if ((r as i32) - (g as i32)).abs() > 85 {
        return false;
    }
    true
}

fn style_looks_like_foreign_secondary(name: &str) -> bool {
    if name.is_empty() {
        return false;
    }
    let lower = name.to_ascii_lowercase();
    lower.contains("eng")
        || lower.contains("english")
        || lower.contains("sub")
        || lower.contains("sec")
        || lower.contains("foreign")
        || lower.contains("en_")
        || lower.contains("_en")
        || lower == "en"
        || lower.contains('英')
        || lower.contains('外')
        || lower.contains('日')
        || lower.contains('韩')
}

fn has_cjk_utf8(s: &str) -> bool {
    let bytes = s.as_bytes();
    bytes.windows(3).any(|w| (0xE4..=0xE9).contains(&w[0]))
}

fn is_mostly_latin_line(s: &str) -> bool {
    let mut latin = 0;
    let mut in_tag = false;
    for &b in s.as_bytes() {
        if b == b'{' {
            in_tag = true;
            continue;
        }
        if b == b'}' {
            in_tag = false;
            continue;
        }
        if in_tag {
            continue;
        }
        if (0xE4..=0xE9).contains(&b) {
            return false;
        }
        if b.is_ascii_alphabetic() {
            latin += 1;
        }
    }
    latin >= 2
}

fn filter_ass_tag_block(block: &str, strip_font: bool, enhance_yellow: bool) -> String {
    if (!strip_font && !enhance_yellow) || block.len() < 2 || !block.starts_with('{') || !block.ends_with('}') {
        return block.to_owned();
    }
    let inner = &block[1..block.len() - 1];
    let bytes = inner.as_bytes();
    let mut out = String::with_capacity(inner.len() + 8);
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] != b'\\' {
            out.push(bytes[i] as char);
            i += 1;
            continue;
        }
        let next_bs = inner[i + 1..].find('\\').map(|p| i + 1 + p).unwrap_or(inner.len());
        let tok = &inner[i..next_bs];
        i = next_bs;
        let tb = tok.as_bytes();

        if strip_font && tb.len() >= 3 && tb[1].eq_ignore_ascii_case(&b'f') && tb[2].eq_ignore_ascii_case(&b'n') {
            continue;
        }
        if enhance_yellow
            && ((tb.len() >= 3 && tb[1].eq_ignore_ascii_case(&b'c') && tb[2] == b'&')
                || (tb.len() >= 4 && tb[1] == b'1' && tb[2].eq_ignore_ascii_case(&b'c') && tb[3] == b'&'))
        {
            if let Some(h_pos) = tok.find(['H', 'h']) {
                let hex: String = tok[h_pos + 1..]
                    .chars()
                    .take_while(|c| c.is_ascii_hexdigit())
                    .collect();
                if (3..=8).contains(&hex.len()) {
                    if let Ok(val) = u32::from_str_radix(&hex, 16) {
                        let r = (val & 0xFF) as u8;
                        let g = ((val >> 8) & 0xFF) as u8;
                        let b = ((val >> 16) & 0xFF) as u8;
                        if is_pale_yellow_rgb(r, g, b) {
                            out.push_str("\\1c&H002EB2FF&");
                            continue;
                        }
                    }
                }
            }
        }
        out.push_str(tok);
    }
    if out.is_empty() {
        String::new()
    } else {
        format!("{{{out}}}")
    }
}

fn transform_ass_payload(payload: &str, mode: i32, strip_font: bool, enhance_yellow: bool) -> String {
    if (mode == 0 && !strip_font && !enhance_yellow) || payload.is_empty() {
        return payload.to_owned();
    }
    let bytes = payload.as_bytes();
    let mut out = String::with_capacity(payload.len() + 32);
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'{' {
            if let Some(rel_close) = payload[i + 1..].find('}') {
                let close = i + 1 + rel_close;
                out.push_str(&filter_ass_tag_block(&payload[i..=close], strip_font, enhance_yellow));
                i = close + 1;
                continue;
            }
        }
        if bytes[i] == b'\\' && i + 1 < bytes.len() && matches!(bytes[i + 1], b'N' | b'n' | b'h') {
            out.push_str(&payload[i..i + 2]);
            i += 2;
            continue;
        }
        let start = i;
        while i < bytes.len()
            && bytes[i] != b'{'
            && !(bytes[i] == b'\\' && i + 1 < bytes.len() && matches!(bytes[i + 1], b'N' | b'n' | b'h'))
        {
            i += 1;
        }
        if mode != 0 {
            out.push_str(&cf_transform_segment(&payload[start..i], mode));
        } else {
            out.push_str(&payload[start..i]);
        }
    }

    if enhance_yellow {
        if let Some(br) = out.find("\\N") {
            if br > 0 && br + 2 < out.len() {
                let line1 = &out[..br];
                let line2 = &out[br + 2..];
                let has_color = line2.contains("\\1c&")
                    || line2.contains("\\c&")
                    || line2.contains("\\1C&")
                    || line2.contains("\\C&");
                if !has_color && has_cjk_utf8(line1) && is_mostly_latin_line(line2) {
                    out = format!("{line1}\\N{{\\1c&H002EB2FF&}}{line2}");
                }
            }
        }
    }
    out
}

fn transform_ass_line(line: &str, mode: i32, is_full_dialogue: bool, strip_font: bool, enhance_yellow: bool) -> String {
    if (mode == 0 && !strip_font && !enhance_yellow) || line.is_empty() {
        return line.to_owned();
    }
    let target_commas = if is_full_dialogue { 9 } else { 8 };
    let mut seen = 0;
    let mut split_pos = None;
    for (idx, b) in line.bytes().enumerate() {
        if b == b',' {
            seen += 1;
            if seen == target_commas {
                split_pos = Some(idx + 1);
                break;
            }
        }
    }
    match split_pos {
        Some(sp) if sp < line.len() => {
            format!("{}{}", &line[..sp], transform_ass_payload(&line[sp..], mode, strip_font, enhance_yellow))
        }
        _ => transform_ass_payload(line, mode, strip_font, enhance_yellow),
    }
}

fn transform_ass_document(doc: &str, mode: i32, strip_font: bool, enhance_yellow: bool) -> String {
    if (mode == 0 && !strip_font && !enhance_yellow) || doc.is_empty() {
        return doc.to_owned();
    }
    let mut out = String::with_capacity(doc.len() + 32);
    for chunk in doc.split_inclusive('\n') {
        if chunk.starts_with("Dialogue:") {
            out.push_str(&transform_ass_line(chunk, mode, true, strip_font, enhance_yellow));
        } else {
            out.push_str(chunk);
        }
    }
    out
}

fn parse_srt_time_ms(t: &str) -> i64 {
    let t = t.trim();
    let parts: Vec<&str> = t.split(':').collect();
    if parts.len() == 3 {
        let hh: i64 = parts[0].parse().unwrap_or(-1);
        let mm: i64 = parts[1].parse().unwrap_or(-1);
        let mut sec_parts = parts[2].split([',', '.']);
        let ss: i64 = sec_parts.next().and_then(|s| s.parse().ok()).unwrap_or(-1);
        let ms_str = sec_parts.next().unwrap_or("0");
        let ms: i64 = parse_frac_ms(ms_str);
        if hh >= 0 && mm >= 0 && ss >= 0 && ms >= 0 {
            return (hh * 3600 + mm * 60 + ss) * 1000 + ms;
        }
    } else if parts.len() == 2 {
        let mm: i64 = parts[0].parse().unwrap_or(-1);
        let mut sec_parts = parts[1].split([',', '.']);
        let ss: i64 = sec_parts.next().and_then(|s| s.parse().ok()).unwrap_or(-1);
        let ms_str = sec_parts.next().unwrap_or("0");
        let ms: i64 = parse_frac_ms(ms_str);
        if mm >= 0 && ss >= 0 && ms >= 0 {
            return (mm * 60 + ss) * 1000 + ms;
        }
    }
    -1
}

fn parse_frac_ms(s: &str) -> i64 {
    let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).take(3).collect();
    if digits.is_empty() {
        return -1;
    }
    let val: i64 = digits.parse().unwrap_or(0);
    match digits.len() {
        1 => val * 100,
        2 => val * 10,
        _ => val,
    }
}

fn sanitize_srt_vtt_tags(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = String::with_capacity(raw.len() + 8);
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'<' {
            if let Some(rel_close) = raw[i + 1..].find('>') {
                let close = i + 1 + rel_close;
                let tag = raw[i + 1..close].to_ascii_lowercase();
                match tag.as_str() {
                    "i" => out.push_str("{\\i1}"),
                    "/i" => out.push_str("{\\i0}"),
                    "b" => out.push_str("{\\b1}"),
                    "/b" => out.push_str("{\\b0}"),
                    "u" => out.push_str("{\\u1}"),
                    "/u" => out.push_str("{\\u0}"),
                    _ => {}
                }
                i = close + 1;
                continue;
            }
        }
        let ch = raw[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

fn ass_text_is_vector_drawing(text: &str) -> bool {
    let b = text.as_bytes();
    b.windows(3).any(|w| w[0] == b'\\' && w[1] == b'p' && (b'1'..=b'9').contains(&w[2]))
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

fn render_pgs_cue_to_layer(
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

fn blit_paired_raster(
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

fn trim_sub_ws(s: &str) -> &str {
    s.trim_matches([' ', '\t', '\r', '\n'])
}

fn event_has_special_ass_effects(style_alignment: i32, text: &str) -> bool {
    if (style_alignment & 0x0C) != 0 {
        return true;
    }
    let b = text.as_bytes();
    let mut i = 0usize;
    while i < b.len() {
        if b[i] != b'{' {
            i += 1;
            continue;
        }
        let mut j = i + 1;
        while j < b.len() && b[j] != b'}' {
            if b[j] == b'\\' {
                let c1 = b.get(j + 1).map(|c| c.to_ascii_lowercase()).unwrap_or(0);
                let c2 = b.get(j + 2).map(|c| c.to_ascii_lowercase()).unwrap_or(0);
                let c3 = b.get(j + 3).map(|c| c.to_ascii_lowercase()).unwrap_or(0);
                if (c1 == b'p' && c2 == b'o' && c3 == b's')
                    || (c1 == b'm' && c2 == b'o' && c3 == b'v')
                    || (c1 == b'o' && c2 == b'r' && c3 == b'g')
                    || (c1 == b'c' && c2 == b'l' && c3 == b'i')
                    || (c1 == b'i' && c2 == b'c' && c3 == b'l')
                {
                    return true;
                }
                if c1 == b'p' && (b'1'..=b'9').contains(&c2) {
                    return true;
                }
                if c1 == b'a' && c2 == b'n' && (b'4'..=b'9').contains(&c3) {
                    return true;
                }
            }
            j += 1;
        }
        if j >= b.len() {
            break;
        }
        i = j + 1;
    }
    false
}

fn extract_clean_lines_from_ass_text(
    raw_text: &str,
    style_is_foreign: bool,
    out_tagged: &mut Vec<(String, bool)>,
) {
    if raw_text.is_empty() {
        return;
    }
    let bytes = raw_text.as_bytes();
    let mut raw_parts = Vec::new();
    let mut start = 0usize;
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() && (bytes[i + 1] == b'N' || bytes[i + 1] == b'n') {
            raw_parts.push(&raw_text[start..i]);
            i += 2;
            start = i;
        } else if bytes[i] == b'\n' {
            raw_parts.push(&raw_text[start..i]);
            i += 1;
            start = i;
        } else {
            i += 1;
        }
    }
    raw_parts.push(&raw_text[start..]);

    let mut cur_italic = false;
    let mut cur_foreign_hint = style_is_foreign;
    for part in raw_parts {
        let mut clean = String::with_capacity(part.len());
        if cur_italic {
            clean.push_str("{\\i1}");
        }
        let mut part_has_visible = false;
        let pb = part.as_bytes();
        let mut k = 0usize;
        while k < pb.len() {
            if pb[k] == b'{' {
                if let Some(rel_close) = part[k + 1..].find('}') {
                    let close = k + 1 + rel_close;
                    let inner = &part[k + 1..close];
                    if inner.contains("\\i1") || inner.contains("\\I1") {
                        if !cur_italic {
                            clean.push_str("{\\i1}");
                            cur_italic = true;
                        }
                    } else if inner.contains("\\i0") || inner.contains("\\I0") {
                        if cur_italic {
                            clean.push_str("{\\i0}");
                            cur_italic = false;
                        }
                    }
                    if let Some(rpos) = inner.find("\\r") {
                        let rest = &inner[rpos + 2..];
                        let rname = rest.split('\\').next().unwrap_or("");
                        if !rname.is_empty() && style_looks_like_foreign_secondary(rname) {
                            cur_foreign_hint = true;
                        } else if rname.is_empty() {
                            cur_foreign_hint = style_is_foreign;
                        }
                    }
                    k = close + 1;
                    continue;
                }
            }
            if pb[k] == b'\\' && k + 1 < pb.len() && pb[k + 1] == b'h' {
                clean.push(' ');
                k += 2;
                continue;
            }
            let ch = part[k..].chars().next().unwrap();
            if ch != '\r' {
                clean.push(ch);
                if ch != ' ' && ch != '\t' {
                    part_has_visible = true;
                }
            }
            k += ch.len_utf8();
        }

        let trimmed = trim_sub_ws(&clean).to_owned();
        if !part_has_visible || trimmed.is_empty() {
            continue;
        }
        let is_foreign = if has_cjk_utf8(&trimmed) {
            false
        } else if is_mostly_latin_line(&trimmed) {
            true
        } else {
            cur_foreign_hint
        };
        out_tagged.push((trimmed, is_foreign));
    }
}

fn looks_like_speaker_dash(line: &str) -> bool {
    let mut s = line.trim_start_matches([' ', '\t']);
    if s.starts_with('{') {
        if let Some(close) = s.find('}') {
            s = s[close + 1..].trim_start_matches([' ', '\t']);
        }
    }
    s.starts_with('-') || s.starts_with('\u{2013}') || s.starts_with('\u{2014}')
}

fn try_split_inline_two_speakers(line: &str) -> Option<(String, String)> {
    let mut skip = 0usize;
    let mut count = 0usize;
    for ch in line.chars().take(2) {
        skip += ch.len_utf8();
        count += 1;
    }
    if count < 2 || skip >= line.len() {
        return None;
    }
    let tail = &line[skip..];
    let pos = tail
        .find(" - ")
        .or_else(|| tail.find("? -"))
        .or_else(|| tail.find("! -"))
        .or_else(|| tail.find(". -"))
        .map(|p| p + skip)?;
    let dash_pos = line[pos..].find('-').map(|p| pos + p)?;
    if dash_pos <= 1 || dash_pos + 1 >= line.len() {
        return None;
    }
    let a = trim_sub_ws(&line[..dash_pos]).to_owned();
    let b = trim_sub_ws(&line[dash_pos..]).to_owned();
    if !a.is_empty() && !b.is_empty() {
        Some((a, b))
    } else {
        None
    }
}

fn strip_ass_braces(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut i = 0usize;
    let b = line.as_bytes();
    while i < b.len() {
        if b[i] == b'{' {
            if let Some(rel_close) = line[i + 1..].find('}') {
                i = i + 1 + rel_close + 1;
                continue;
            }
        }
        let ch = line[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

fn is_bracket_or_music_line(line: &str) -> bool {
    let plain = strip_ass_braces(line);
    let t = trim_sub_ws(&plain);
    t.starts_with('[')
        || t.starts_with('(')
        || t.starts_with('\u{266A}')
        || t.starts_with('\u{266B}')
        || t.starts_with('\u{FF08}')
        || t.starts_with('\u{3010}')
}

fn utf8_visible_len(line: &str) -> usize {
    strip_ass_braces(line).chars().count()
}

fn join_two_lines(a: &str, b: &str, is_latin: bool) -> String {
    if a.is_empty() {
        return b.to_owned();
    }
    if b.is_empty() {
        return a.to_owned();
    }
    if is_latin {
        return format!("{a} {b}");
    }
    if a.ends_with(['，', '。', '！', '？', '、', '；', '：', '…', '—', ' ']) {
        format!("{a}{b}")
    } else {
        format!("{a} {b}")
    }
}

fn group_by_speaker_dash(lines: &[String], is_latin: bool) -> Vec<String> {
    if lines.len() <= 1 || !lines[1..].iter().any(|l| looks_like_speaker_dash(l)) {
        return lines.to_vec();
    }
    let mut grouped: Vec<String> = Vec::new();
    for l in lines {
        if grouped.is_empty() || looks_like_speaker_dash(l) || is_bracket_or_music_line(l) {
            grouped.push(l.clone());
        } else if let Some(last) = grouped.last_mut() {
            *last = join_two_lines(last, l, is_latin);
        }
    }
    grouped
}

fn reflow_non_dialogue_lines(lines: &[String], is_latin: bool) -> Vec<String> {
    if lines.len() <= 1 {
        return lines.to_vec();
    }
    for (i, l) in lines.iter().enumerate() {
        if (i > 0 && looks_like_speaker_dash(l)) || is_bracket_or_music_line(l) {
            return lines.to_vec();
        }
    }
    let mut merged = lines[0].clone();
    for l in &lines[1..] {
        merged = join_two_lines(&merged, l, is_latin);
    }
    vec![merged]
}

fn has_multi_speaker_dashes(lines: &[String]) -> bool {
    lines.len() >= 2 && lines[1..].iter().any(|l| looks_like_speaker_dash(l))
}

fn try_split_counterpart_by_anchor_ratio(line: &str, anchor_ratio: f64) -> Option<(String, String)> {
    if let Some(pair) = try_split_inline_two_speakers(line) {
        return Some(pair);
    }
    let total_vis = utf8_visible_len(line);
    if total_vis < 4 {
        return None;
    }
    let clamped_target = anchor_ratio.clamp(0.18, 0.82);

    struct Cand {
        split_after_byte: usize,
        next_start_byte: usize,
        ratio: f64,
        tier: i32,
    }
    let mut cands = Vec::new();
    let mut vis_so_far = 0usize;
    let mut in_brace = false;
    let mut i = 0usize;
    while i < line.len() {
        let ch = line[i..].chars().next().unwrap();
        let ch_len = ch.len_utf8();
        if ch == '{' {
            in_brace = true;
            i += ch_len;
            continue;
        }
        if in_brace {
            if ch == '}' {
                in_brace = false;
            }
            i += ch_len;
            continue;
        }
        vis_so_far += 1;
        let is_sent_end = matches!(ch, '?' | '!' | '？' | '！' | '。' | '…');
        let is_soft_sep = matches!(ch, ' ' | '\t' | '\u{3000}' | '，' | '；');

        if is_sent_end {
            let mut split_end = i + ch_len;
            while split_end < line.len() && matches!(line.as_bytes()[split_end], b'?' | b'!' | b'.') {
                split_end += 1;
                vis_so_far += 1;
            }
            let mut next_s = split_end;
            while next_s < line.len() && matches!(line.as_bytes()[next_s], b' ' | b'\t') {
                next_s += 1;
            }
            if next_s < line.len() {
                let r = (vis_so_far as f64) / (total_vis as f64);
                if (0.15..=0.85).contains(&r) {
                    cands.push(Cand { split_after_byte: split_end, next_start_byte: next_s, ratio: r, tier: 1 });
                }
            }
            i = split_end;
            continue;
        }
        if is_soft_sep {
            let keep_left = matches!(ch, '，' | '；');
            let split_end = if keep_left { i + ch_len } else { i };
            let mut next_s = i + ch_len;
            while next_s < line.len() && matches!(line.as_bytes()[next_s], b' ' | b'\t') {
                next_s += 1;
            }
            if split_end > 0 && next_s < line.len() {
                let r = (vis_so_far as f64) / (total_vis as f64);
                if (0.15..=0.85).contains(&r) {
                    cands.push(Cand { split_after_byte: split_end, next_start_byte: next_s, ratio: r, tier: 2 });
                }
            }
            i = next_s;
            continue;
        }
        i += ch_len;
    }

    let mut best: Option<&Cand> = None;
    let mut best_score = 1e9f64;
    for cand in &cands {
        let dist = (cand.ratio - clamped_target).abs();
        if cand.tier == 2 && dist > 0.28 {
            continue;
        }
        let score = dist + if cand.tier == 2 { 0.12 } else { 0.0 };
        if score < best_score {
            best_score = score;
            best = Some(cand);
        }
    }
    let b = best?;
    let out_a = trim_sub_ws(&line[..b.split_after_byte]).to_owned();
    let out_b = trim_sub_ws(&line[b.next_start_byte..]).to_owned();
    if !out_a.is_empty() && !out_b.is_empty() {
        Some((out_a, out_b))
    } else {
        None
    }
}

fn track_looks_predominantly_latin(tr: *const c_void) -> bool {
    if tr.is_null() {
        return false;
    }
    let mut n_events = 0;
    unsafe { dk_shim_ass_track_meta(tr, ptr::null_mut(), &mut n_events, ptr::null_mut(), ptr::null_mut()) };
    if n_events <= 0 {
        return false;
    }
    let mut latin_hits = 0;
    let mut cjk_hits = 0;
    let step = (n_events / 24).max(1);
    let mut i = 0;
    while i < n_events && (latin_hits + cjk_hits) < 20 {
        let mut txt_p: *const c_char = ptr::null();
        if unsafe {
            dk_shim_ass_event_read(tr, i, ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut(), &mut txt_p)
        } && !txt_p.is_null()
        {
            let raw = unsafe { CStr::from_ptr(txt_p) }.to_string_lossy();
            let plain = strip_ass_braces(&raw);
            let clean = trim_sub_ws(&plain);
            if clean.len() >= 3 {
                if has_cjk_utf8(clean) {
                    cjk_hits += 1;
                } else if is_mostly_latin_line(clean) {
                    latin_hits += 1;
                }
            }
        }
        i += step;
    }
    latin_hits > cjk_hits
}

fn build_paired_turns(
    pri_track_tagged: &[(String, bool)],
    sec_track_lines: &[String],
    anchor_is_secondary: bool,
) -> Vec<SemanticTurn> {
    let mut turns = Vec::new();

    let mut pair_or_reflow_two_lists = |cns_in: Vec<String>, ens_in: Vec<String>| {
        let mut cns = group_by_speaker_dash(&cns_in, false);
        let mut ens = group_by_speaker_dash(&ens_in, true);

        let split_ratio = |a: &str, b: &str| -> f64 {
            let la = utf8_visible_len(a).max(1) as f64;
            let lb = utf8_visible_len(b).max(1) as f64;
            la / (la + lb)
        };

        let en_has_2spk = ens.len() == 2
            && (looks_like_speaker_dash(&ens[0]) || looks_like_speaker_dash(&ens[1]))
            && looks_like_speaker_dash(&ens[1]);
        let cn_has_2spk = cns.len() == 2
            && (looks_like_speaker_dash(&cns[0]) || looks_like_speaker_dash(&cns[1]))
            && looks_like_speaker_dash(&cns[1]);

        if en_has_2spk && cns.len() == 1 {
            let ratio = split_ratio(&ens[0], &ens[1]);
            let split = if anchor_is_secondary {
                try_split_counterpart_by_anchor_ratio(&cns[0], ratio)
            } else {
                try_split_inline_two_speakers(&cns[0])
                    .or_else(|| try_split_counterpart_by_anchor_ratio(&cns[0], ratio))
            };
            if let Some((a, b)) = split {
                cns = vec![a, b];
            }
        } else if cn_has_2spk && ens.len() == 1 {
            let ratio = split_ratio(&cns[0], &cns[1]);
            let split = if !anchor_is_secondary {
                try_split_counterpart_by_anchor_ratio(&ens[0], ratio)
            } else {
                try_split_inline_two_speakers(&ens[0])
                    .or_else(|| try_split_counterpart_by_anchor_ratio(&ens[0], ratio))
            };
            if let Some((a, b)) = split {
                ens = vec![a, b];
            }
        }

        if cns.is_empty() {
            turns.push(SemanticTurn {
                pri_lines: Vec::new(),
                sec_lines: reflow_non_dialogue_lines(&ens, true),
            });
            return;
        }
        if ens.is_empty() {
            turns.push(SemanticTurn {
                pri_lines: reflow_non_dialogue_lines(&cns, false),
                sec_lines: Vec::new(),
            });
            return;
        }

        let is_two_speaker = has_multi_speaker_dashes(&cns) || has_multi_speaker_dashes(&ens);
        if cns.len() == ens.len() && cns.len() >= 2 {
            if is_two_speaker {
                for (c, e) in cns.into_iter().zip(ens.into_iter()) {
                    turns.push(SemanticTurn { pri_lines: vec![c], sec_lines: vec![e] });
                }
                return;
            }
            let total_cn: usize = cns.iter().map(|s| utf8_visible_len(s)).sum();
            let total_en: usize = ens.iter().map(|s| utf8_visible_len(s)).sum();
            let any_bracket =
                cns.iter().any(|s| is_bracket_or_music_line(s)) || ens.iter().any(|s| is_bracket_or_music_line(s));
            if !any_bracket && total_cn <= 26 && total_en <= 88 {
                turns.push(SemanticTurn {
                    pri_lines: reflow_non_dialogue_lines(&cns, false),
                    sec_lines: reflow_non_dialogue_lines(&ens, true),
                });
            } else {
                for (c, e) in cns.into_iter().zip(ens.into_iter()) {
                    turns.push(SemanticTurn { pri_lines: vec![c], sec_lines: vec![e] });
                }
            }
            return;
        }

        turns.push(SemanticTurn {
            pri_lines: reflow_non_dialogue_lines(&cns, false),
            sec_lines: reflow_non_dialogue_lines(&ens, true),
        });
    };

    if !sec_track_lines.is_empty() {
        let pri_lines: Vec<String> = pri_track_tagged.iter().map(|(l, _)| l.clone()).collect();
        pair_or_reflow_two_lists(pri_lines, sec_track_lines.to_vec());
        return turns;
    }

    if pri_track_tagged.is_empty() {
        return turns;
    }

    let any_pri = pri_track_tagged.iter().any(|(_, is_sec)| !*is_sec);
    let any_sec = pri_track_tagged.iter().any(|(_, is_sec)| *is_sec);
    if !any_pri || !any_sec {
        let mut mono: Vec<String> = pri_track_tagged.iter().map(|(l, _)| l.clone()).collect();
        let looks_latin = !mono.is_empty() && is_mostly_latin_line(&mono[0]);
        mono = group_by_speaker_dash(&mono, looks_latin);
        if !has_multi_speaker_dashes(&mono) {
            mono = reflow_non_dialogue_lines(&mono, looks_latin);
        }
        turns.push(SemanticTurn { pri_lines: mono, sec_lines: Vec::new() });
        return turns;
    }

    let mut is_interleaved = pri_track_tagged.len() >= 4 && pri_track_tagged.len() % 2 == 0;
    if is_interleaved {
        for pair in pri_track_tagged.chunks_exact(2) {
            if pair[0].1 == pair[1].1 {
                is_interleaved = false;
                break;
            }
        }
    }
    if is_interleaved {
        for pair in pri_track_tagged.chunks_exact(2) {
            let (pri, sec) = if !pair[0].1 {
                (pair[0].0.clone(), pair[1].0.clone())
            } else {
                (pair[1].0.clone(), pair[0].0.clone())
            };
            turns.push(SemanticTurn { pri_lines: vec![pri], sec_lines: vec![sec] });
        }
        return turns;
    }

    let mut cns = Vec::new();
    let mut ens = Vec::new();
    for (line, is_sec) in pri_track_tagged {
        if *is_sec {
            ens.push(line.clone());
        } else {
            cns.push(line.clone());
        }
    }
    pair_or_reflow_two_lists(cns, ens);
    turns
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn srt_timestamp_and_tag_sanitization_work() {
        assert_eq!(parse_srt_time_ms("01:02:03,450"), 3_723_450);
        assert_eq!(parse_srt_time_ms("00:10.5"), 10_500);
        assert_eq!(sanitize_srt_vtt_tags("<i>Hello</i> <font color=red>world</font>"), "{\\i1}Hello{\\i0} world");
    }

    #[test]
    fn pair_a_rescues_space_separated_cn_from_english_2_speaker_anchor() {
        let pri = vec![("你确定吗 相信我".to_string(), false)];
        let sec = vec!["- Are you sure?".to_string(), "- Trust me.".to_string()];
        let turns = build_paired_turns(&pri, &sec, true);
        assert_eq!(turns.len(), 2);
        assert_eq!(turns[0].pri_lines, vec!["你确定吗"]);
        assert_eq!(turns[1].pri_lines, vec!["相信我"]);
    }
}
