use crate::abi::{DKSubtitleInterval, DKSubtitleStyleConfig};
use crate::ffi::*;
use std::collections::VecDeque;
use std::ffi::{c_char, c_int, c_longlong, c_void, CStr, CString};
use std::ptr;

mod ass_style;
mod ass_text;
mod compositor;
mod pair_a_parse;
mod pair_a_render;
mod pgs;

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

    sub_codec_ctx: *mut c_void,
    secondary_sub_codec_ctx: *mut c_void,

    ass_canvas_w: i32,
    ass_canvas_h: i32,
    sub_storage_w: i32,
    sub_storage_h: i32,
    sub_margin_t: i32,
    sub_margin_b: i32,
    sub_margin_l: i32,
    sub_margin_r: i32,

    pub(crate) has_bitmap_subs: bool,
    pgs_cues: VecDeque<PgsCue>,
    pgs_generation: u64,
    rendered_pgs_gen: u64,

    secondary_has_bitmap_subs: bool,
    secondary_pgs_cues: VecDeque<PgsCue>,
    secondary_pgs_generation: u64,
    rendered_secondary_pgs_gen: u64,

    sub_rgba_buf: Vec<u8>,
    sub_layer_pri_buf: Vec<u8>,
    sub_layer_sec_buf: Vec<u8>,

    sub_serial: u64,
    sub_read_order: u64,
    sub_last_non_empty: bool,
    sub_style_dirty: bool,
    paired_layout_active: bool,
    paired_layout_hash: u64,
    sub_dirty_y0: i32,
    sub_dirty_y1: i32,
    pub(crate) secondary_time_scale: f64,
    sub_style: DKSubtitleStyleConfig,

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
            unsafe { dk_shim_ass_set_quiet_logger(ass_lib) };
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
            if !self.ass_track.is_null() {
                ass_free_track(self.ass_track);
                self.ass_track = ptr::null_mut();
            }
            if !self.secondary_ass_track.is_null() {
                ass_free_track(self.secondary_ass_track);
                self.secondary_ass_track = ptr::null_mut();
            }
        }
        self.primary_ass_events.clear();
        self.primary_ass_events.shrink_to_fit();
        self.secondary_ass_events.clear();
        self.secondary_ass_events.shrink_to_fit();
        self.primary_codec_private.clear();
        self.primary_codec_private.shrink_to_fit();
        self.secondary_codec_private.clear();
        self.secondary_codec_private.shrink_to_fit();
        self.primary_ext_raw.clear();
        self.primary_ext_raw.shrink_to_fit();
        self.secondary_ext_raw.clear();
        self.secondary_ext_raw.shrink_to_fit();
        self.pgs_cues.clear();
        self.pgs_cues.shrink_to_fit();
        self.secondary_pgs_cues.clear();
        self.secondary_pgs_cues.shrink_to_fit();
        self.sub_rgba_buf.clear();
        self.sub_rgba_buf.shrink_to_fit();
        self.sub_layer_pri_buf.clear();
        self.sub_layer_pri_buf.shrink_to_fit();
        self.sub_layer_sec_buf.clear();
        self.sub_layer_sec_buf.shrink_to_fit();
        self.has_bitmap_subs = false;
        self.secondary_has_bitmap_subs = false;
        self.sub_last_non_empty = false;
        self.paired_layout_active = false;
        self.paired_layout_hash = 0;
        self.sub_dirty_y0 = 0;
        self.sub_dirty_y1 = 0;
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

    pub(crate) fn mark_replayed(&mut self) {
        self.sub_last_non_empty = true;
        self.sub_style_dirty = true;
        self.sub_serial = self.sub_serial.wrapping_add(1);
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

#[cfg(test)]
mod tests {
    use super::ass_text::{parse_srt_time_ms, sanitize_srt_vtt_tags};
    use super::pair_a_parse::build_paired_turns;

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
