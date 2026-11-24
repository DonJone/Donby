use crate::abi::{ CGImageRef, CVPixelBufferRef, DKChapterInfo, DKGpuColorUniforms };
use std::ffi::{ c_char, c_int, c_longlong, c_void };

#[repr(C)]
#[derive(Copy, Clone)]
pub struct DKShimStreamMeta {
    pub codec_type: i32,
    pub codec_id: i32,
    pub is_ass_or_ssa: bool,
    pub is_subrip_or_text: bool,
    pub is_pgs_or_dvd: bool,
    pub disp_default: bool,
    pub disp_forced: bool,
    pub disp_attached_pic: bool,
    pub width: i32,
    pub height: i32,
    pub bit_depth: i32,
    pub channels: i32,
    pub sample_rate: i32,
    pub color_trc: i32,
    pub color_primaries: i32,
    pub dovi_profile: u8,
    pub dovi_level: u8,
    pub dovi_compat: u8,
    pub _pad: u8,
    pub fps: f64,
    pub time_base_sec: f64,
    pub bit_rate: i64,
    pub codec_name: [c_char; 32],
    pub language: [c_char; 32],
    pub title: [c_char; 128],
    pub extradata: *const u8,
    pub extradata_size: i32,
}

impl Default for DKShimStreamMeta {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

pub type DKShimAqCallbackFn = unsafe extern "C" fn(
    rust_ctx: *mut c_void,
    aq: *mut c_void,
    buf: *mut c_void,
    dst_floats: *mut f32,
    cap_floats: u32,
);

pub type DKShimSubTextCb = unsafe extern "C" fn(
    ctx: *mut c_void,
    text: *const u8,
    len: usize,
    is_ass_rect: bool,
    evt_forced: bool,
    start_ms: i64,
    dur_ms: i64,
);

pub type DKShimSubBitmapBeginCb = unsafe extern "C" fn(
    ctx: *mut c_void,
    cue_start: f64,
    cue_end: f64,
    canvas_w: i32,
    canvas_h: i32,
    num_rects: u32,
);

pub type DKShimSubBitmapRectCb = unsafe extern "C" fn(
    ctx: *mut c_void,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    linesize: i32,
    indices: *const u8,
    palette256: *const u32,
    rect_forced: bool,
);

pub type DKShimSubBitmapEndCb = unsafe extern "C" fn(ctx: *mut c_void);

extern "C" {
    pub fn dk_shim_install_ffmpeg_log_bridge();
    pub fn dk_shim_averror_eof() -> c_int;
    pub fn dk_shim_averror_exit() -> c_int;
    pub fn dk_shim_averror_eio() -> c_int;
    pub fn dk_shim_averror_enosys() -> c_int;
    pub fn dk_shim_is_eof(err: c_int) -> bool;
    pub fn dk_shim_is_eagain(err: c_int) -> bool;
    pub fn dk_shim_strerror(err: c_int, buf: *mut c_char, cap: usize);

    pub fn dk_shim_pkt_alloc() -> *mut c_void;
    pub fn dk_shim_pkt_free(pkt: *mut *mut c_void);
    pub fn dk_shim_pkt_clone(pkt: *const c_void) -> *mut c_void;
    pub fn dk_shim_pkt_unref(pkt: *mut c_void);
    pub fn dk_shim_pkt_move_alloc(src_pkt: *mut c_void) -> *mut c_void;
    pub fn dk_shim_pkt_stream_index(pkt: *const c_void) -> i32;
    pub fn dk_shim_pkt_size(pkt: *const c_void) -> i32;

    pub fn dk_shim_frame_alloc() -> *mut c_void;
    pub fn dk_shim_frame_free(frame: *mut *mut c_void);
    pub fn dk_shim_frame_unref(frame: *mut c_void);

    pub fn dk_shim_open_format(
        url: *const c_char,
        headers_crlf: *const c_char,
        is_local_file: bool,
        has_start_seek: bool,
        is_mpeg_ts: bool,
        use_custom_io: bool,
        has_seek_cb: bool,
        opaque: *mut c_void,
        interrupt_cb: unsafe extern "C" fn(*mut c_void) -> c_int,
        read_cb: unsafe extern "C" fn(*mut c_void, *mut u8, c_int) -> c_int,
        seek_cb: unsafe extern "C" fn(*mut c_void, i64, c_int) -> i64,
        out_fmt: *mut *mut c_void,
        out_avio: *mut *mut c_void,
    ) -> c_int;
    pub fn dk_shim_close_format(fmt: *mut *mut c_void, custom_avio: *mut *mut c_void);
    pub fn dk_shim_format_summary(
        fmt: *const c_void,
        out_nb_streams: *mut u32,
        out_nb_chapters: *mut u32,
        out_duration_sec: *mut f64,
        out_bit_rate: *mut i64,
    );
    pub fn dk_shim_get_stream_meta(fmt: *const c_void, idx: u32, out: *mut DKShimStreamMeta) -> bool;
    pub fn dk_shim_get_chapter_info(fmt: *const c_void, idx: u32, out: *mut DKChapterInfo) -> bool;
    pub fn dk_shim_clear_avio_error(fmt: *mut c_void);
    pub fn dk_shim_avio_bytes_read(fmt: *const c_void) -> i64;
    pub fn dk_shim_avio_retry_reseek(fmt: *mut c_void);
    pub fn dk_shim_seek_format(fmt: *mut c_void, target_sec: f64, allow_fallback: bool) -> c_int;
    pub fn dk_shim_read_frame(
        fmt: *mut c_void,
        pkt: *mut c_void,
        out_stream_idx: *mut i32,
        out_size: *mut i32,
        out_corrupt: *mut bool,
        out_pkt_sec: *mut f64,
        out_has_pts: *mut bool,
        out_data: *mut *const u8,
    ) -> c_int;
    pub fn dk_shim_is_hevc_stream(fmt: *const c_void, stream_idx: i32) -> bool;

    pub fn dk_shim_alloc_hw_fmt_ctx(
        rust_opaque: *mut c_void,
        is_vt_failed: unsafe extern "C" fn(*mut c_void) -> bool,
        on_sw_format_selected: unsafe extern "C" fn(*mut c_void),
    ) -> *mut c_void;
    pub fn dk_shim_free_hw_fmt_ctx(ptr: *mut *mut c_void);

    pub fn dk_shim_open_video_decoder(
        fmt: *const c_void,
        stream_idx: i32,
        hw_decode: bool,
        sw_threads: i32,
        hw_fmt_ctx_opaque: *mut c_void,
        out_codec_ctx: *mut *mut c_void,
        out_hw_ctx: *mut *mut c_void,
        out_is_hw: *mut bool,
        out_dec_name: *mut c_char,
    ) -> c_int;
    pub fn dk_shim_close_codec(codec_ctx: *mut *mut c_void);
    pub fn dk_shim_unref_hw_ctx(hw_ctx: *mut *mut c_void);
    pub fn dk_shim_send_packet(codec_ctx: *mut c_void, pkt: *const c_void) -> c_int;
    pub fn dk_shim_receive_frame(codec_ctx: *mut c_void, frame: *mut c_void) -> c_int;
    pub fn dk_shim_flush_codec(codec_ctx: *mut c_void);
    pub fn dk_shim_set_codec_skip_nonref(codec_ctx: *mut c_void, skip_nonref: bool);
    pub fn dk_shim_reclaim_memory();

    pub fn dk_shim_process_video_frame(
        frame: *const c_void,
        fmt: *const c_void,
        video_stream_idx: i32,
        stream_dovi_profile: u8,
        fallback_fps: f64,
        prev_pts: f64,
        drop_until_pts: f64,
        out_dropped: *mut bool,
        out_pts: *mut f64,
        inout_sws: *mut *mut c_void,
        inout_pool: *mut *mut c_void,
        inout_pool_w: *mut i32,
        inout_pool_h: *mut i32,
        inout_pool_fmt: *mut u32,
        out_color: *mut DKGpuColorUniforms,
        out_is_hw: *mut bool,
        out_is_hdr: *mut bool,
        out_is_dovi: *mut bool,
        out_cs_label: *mut c_char,
    ) -> CVPixelBufferRef;
    pub fn dk_shim_release_sw_video_res(sws: *mut *mut c_void, pool: *mut *mut c_void);
    pub fn dk_shim_retain_pixbuf(pb: CVPixelBufferRef);
    pub fn dk_shim_release_pixbuf(pb: CVPixelBufferRef);
    pub fn dk_shim_extract_thumbnail(path: *const c_char, target_sec: f64) -> CGImageRef;

    pub fn dk_shim_open_audio_decoder(
        fmt: *const c_void,
        stream_idx: i32,
        out_codec_ctx: *mut *mut c_void,
        out_swr: *mut *mut c_void,
        out_swr_fmt: *mut i32,
        out_swr_rate: *mut i32,
        out_swr_ch: *mut i32,
        out_dec_name: *mut c_char,
    ) -> c_int;
    pub fn dk_shim_close_swr(swr: *mut *mut c_void);
    pub fn dk_shim_audio_frame_prepare(
        frame: *const c_void,
        codec_ctx: *const c_void,
        fmt: *const c_void,
        audio_stream_idx: i32,
        inout_swr: *mut *mut c_void,
        inout_fmt: *mut i32,
        inout_rate: *mut i32,
        inout_ch: *mut i32,
        drop_until_pts: f64,
        out_dropped: *mut bool,
        out_pts: *mut f64,
        out_has_pts: *mut bool,
    ) -> i32;
    pub fn dk_shim_audio_frame_convert(
        frame: *const c_void,
        swr: *mut c_void,
        out_stereo_48k: *mut f32,
        max_out_samples: i32,
        out_vad_mono_48k: *mut f32,
    ) -> i32;

    pub fn dk_shim_aq_create(
        cb: DKShimAqCallbackFn,
        rust_ctx: *mut c_void,
        rate: f32,
        effective_vol: f32,
        out_aq: *mut *mut c_void,
        out_trampoline: *mut *mut c_void,
        out_bufs: *mut *mut c_void,
    ) -> bool;
    pub fn dk_shim_aq_fill_and_enqueue(
        aq: *mut c_void,
        buf: *mut c_void,
        fill_fn: unsafe extern "C" fn(*mut c_void, *mut f32, u32),
        ctx: *mut c_void,
    );
    pub fn dk_shim_aq_commit_and_enqueue(aq: *mut c_void, buf: *mut c_void);
    pub fn dk_shim_aq_prime_and_start(aq: *mut c_void) -> i32;
    pub fn dk_shim_aq_start_only(aq: *mut c_void) -> i32;
    pub fn dk_shim_aq_pause(aq: *mut c_void);
    pub fn dk_shim_aq_stop_reset(aq: *mut c_void);
    pub fn dk_shim_aq_reset_only(aq: *mut c_void);
    pub fn dk_shim_aq_stop_dispose(aq: *mut *mut c_void, trampoline: *mut *mut c_void);
    pub fn dk_shim_aq_set_rate(aq: *mut c_void, rate: f32);
    pub fn dk_shim_aq_set_volume(aq: *mut c_void, vol: f32);
    pub fn dk_shim_aq_get_sample_time(aq: *mut c_void, out_sample_time: *mut i64) -> bool;

    pub fn dk_shim_ass_set_quiet_logger(ass_lib: *mut c_void);
    pub fn dk_shim_cf_transform_utf8(
        src_bytes: *const u8,
        src_len: usize,
        mode: i32,
        dst_buf: *mut u8,
        dst_cap: usize,
    ) -> usize;
    pub fn dk_shim_open_sub_decoder(
        fmt: *const c_void,
        stream_idx: i32,
        out_codec_ctx: *mut *mut c_void,
        out_hdr: *mut *const u8,
        out_hdr_len: *mut i32,
        out_dec_name: *mut c_char,
    ) -> c_int;
    pub fn dk_shim_decode_subtitle_pkt(
        fmt: *const c_void,
        stream_idx: i32,
        sub_codec_ctx: *mut c_void,
        pkt: *const c_void,
        fallback_storage_w: i32,
        fallback_storage_h: i32,
        cb_ctx: *mut c_void,
        on_text: DKShimSubTextCb,
        on_bmp_begin: DKShimSubBitmapBeginCb,
        on_bmp_rect: DKShimSubBitmapRectCb,
        on_bmp_end: DKShimSubBitmapEndCb,
    );

    pub fn dk_shim_ass_track_meta(
        track: *const c_void,
        out_n_styles: *mut i32,
        out_n_events: *mut i32,
        out_play_res_y: *mut i32,
        out_has_event_format: *mut bool,
    );
    pub fn dk_shim_ass_style_read(
        track: *const c_void,
        idx: i32,
        out_name: *mut *const c_char,
        out_font_name: *mut *const c_char,
        out_font_size: *mut f64,
        out_outline: *mut f64,
        out_margin_v: *mut i32,
        out_primary_colour: *mut u32,
        out_scale_x: *mut f64,
        out_scale_y: *mut f64,
        out_alignment: *mut i32,
        out_border_style: *mut i32,
    ) -> bool;
    pub fn dk_shim_ass_style_write(
        track: *mut c_void,
        idx: i32,
        desired_font: *const c_char,
        primary_colour: u32,
        font_size: f64,
        outline: f64,
        margin_v: i32,
        scale_x: f64,
        scale_y: f64,
        alignment: i32,
        border_style: i32,
        update_box_metrics: bool,
    );
    pub fn dk_shim_ass_event_read(
        track: *const c_void,
        idx: i32,
        out_start_ms: *mut i64,
        out_dur_ms: *mut i64,
        out_style_idx: *mut i32,
        out_margin_v: *mut i32,
        out_text: *mut *const c_char,
    ) -> bool;
    pub fn dk_shim_ass_event_zero_margin_v(track: *mut c_void, idx: i32);
    pub fn dk_shim_ass_image_read(
        img: *const c_void,
        out_w: *mut i32,
        out_h: *mut i32,
        out_stride: *mut i32,
        out_bitmap: *mut *const u8,
        out_color: *mut u32,
        out_dst_x: *mut i32,
        out_dst_y: *mut i32,
    ) -> *const c_void;

    // Direct libass public C API
    pub fn ass_library_init() -> *mut c_void;
    pub fn ass_library_done(lib: *mut c_void);
    pub fn ass_renderer_init(lib: *mut c_void) -> *mut c_void;
    pub fn ass_renderer_done(ren: *mut c_void);
    pub fn ass_set_fonts(
        ren: *mut c_void,
        default_font: *const c_char,
        default_family: *const c_char,
        dfp: c_int,
        config: *const c_char,
        update: c_int,
    );
    pub fn ass_set_frame_size(ren: *mut c_void, w: c_int, h: c_int);
    pub fn ass_set_storage_size(ren: *mut c_void, w: c_int, h: c_int);
    pub fn ass_set_margins(ren: *mut c_void, t: c_int, b: c_int, l: c_int, r: c_int);
    pub fn ass_set_use_margins(ren: *mut c_void, use_margins: c_int);
    pub fn ass_set_font_scale(ren: *mut c_void, factor: f64);
    pub fn ass_set_line_position(ren: *mut c_void, line_pos: f64);
    pub fn ass_new_track(lib: *mut c_void) -> *mut c_void;
    pub fn ass_free_track(track: *mut c_void);
    pub fn ass_flush_events(track: *mut c_void);
    pub fn ass_process_codec_private(track: *mut c_void, data: *const c_char, size: c_int);
    pub fn ass_process_data(track: *mut c_void, data: *const c_char, size: c_int);
    pub fn ass_process_chunk(
        track: *mut c_void,
        data: *const c_char,
        size: c_int,
        timecode: c_longlong,
        duration: c_longlong,
    );
    pub fn ass_read_memory(
        lib: *mut c_void,
        buf: *const c_char,
        bufsize: usize,
        codepage: *const c_char,
    ) -> *mut c_void;
    pub fn ass_render_frame(
        ren: *mut c_void,
        track: *mut c_void,
        now: c_longlong,
        detect_change: *mut c_int,
    ) -> *const c_void;
}

/// RAII wrapper for FFmpeg `AVPacket*` (`Send` when owned exclusively in queue).
pub struct AvPacket(pub *mut c_void);
unsafe impl Send for AvPacket {}

impl AvPacket {
    pub fn alloc() -> Option<Self> {
        let p = unsafe { dk_shim_pkt_alloc() };
        if p.is_null() { None } else { Some(Self(p)) }
    }

    pub fn clone_pkt(&self) -> Option<Self> {
        let p = unsafe { dk_shim_pkt_clone(self.0) };
        if p.is_null() { None } else { Some(Self(p)) }
    }

    pub fn move_out(&mut self) -> Option<Self> {
        let p = unsafe { dk_shim_pkt_move_alloc(self.0) };
        if p.is_null() { None } else { Some(Self(p)) }
    }

    pub fn unref(&mut self) {
        unsafe { dk_shim_pkt_unref(self.0) };
    }

    pub fn stream_index(&self) -> i32 {
        unsafe { dk_shim_pkt_stream_index(self.0) }
    }

    pub fn size(&self) -> i32 {
        unsafe { dk_shim_pkt_size(self.0) }
    }
}

impl Drop for AvPacket {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { dk_shim_pkt_free(&mut self.0) };
        }
    }
}

/// RAII wrapper for FFmpeg `AVFrame*`.
pub struct AvFrame(pub *mut c_void);
unsafe impl Send for AvFrame {}

impl AvFrame {
    pub fn alloc() -> Option<Self> {
        let f = unsafe { dk_shim_frame_alloc() };
        if f.is_null() { None } else { Some(Self(f)) }
    }

    pub fn unref(&mut self) {
        unsafe { dk_shim_frame_unref(self.0) };
    }
}

impl Drop for AvFrame {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { dk_shim_frame_free(&mut self.0) };
        }
    }
}

/// RAII wrapper for retained `CVPixelBufferRef`.
pub struct OwnedPixelBuffer(pub CVPixelBufferRef);
unsafe impl Send for OwnedPixelBuffer {}

impl OwnedPixelBuffer {
    pub fn retain_raw(&self) -> CVPixelBufferRef {
        if !self.0.is_null() {
            unsafe { dk_shim_retain_pixbuf(self.0) };
        }
        self.0
    }
}

impl Clone for OwnedPixelBuffer {
    fn clone(&self) -> Self {
        Self(self.retain_raw())
    }
}

impl Drop for OwnedPixelBuffer {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { dk_shim_release_pixbuf(self.0) };
            self.0 = std::ptr::null_mut();
        }
    }
}

pub fn ffmpeg_err_string(err: c_int) -> String {
    let mut buf = [0 as c_char; 256];
    unsafe { dk_shim_strerror(err, buf.as_mut_ptr(), buf.len()) };
    unsafe { std::ffi::CStr::from_ptr(buf.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}
