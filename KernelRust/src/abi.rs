use std::ffi::{c_char, c_int, c_void, CStr};

pub type CVPixelBufferRef = *mut c_void;
pub type CGImageRef = *mut c_void;

#[repr(C)]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum DKPlayerState {
    Idle = 0,
    Opening = 1,
    Buffering = 2,
    Playing = 3,
    Paused = 4,
    Ended = 5,
    Error = 6,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct DKRuntimeStats {
    pub width: i32,
    pub height: i32,
    pub bit_depth: i32,
    pub fps: f64,
    pub video_bitrate_mbps: f64,
    pub is_hdr: bool,
    pub is_dolby_vision: bool,
    pub is_hw_accelerated: bool,
    pub video_codec: [c_char; 32],
    pub audio_codec: [c_char; 32],
    pub color_space: [c_char; 32],
    pub cached_bytes: i64,
    pub total_bytes_read: i64,
    pub download_speed_mbs: f64,
}

impl Default for DKRuntimeStats {
    fn default() -> Self {
        // SAFETY: All fields are plain integer/float/bool/char-array primitives valid when zeroed.
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct DKTrackInfo {
    pub stream_index: i32,
    pub channels: i32,
    pub is_selected: bool,
    pub is_default: bool,
    pub is_forced: bool,
    pub codec: [c_char; 32],
    pub language: [c_char; 32],
    pub title: [c_char; 128],
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct DKChapterInfo {
    pub index: i32,
    pub start_sec: f64,
    pub end_sec: f64,
    pub title: [c_char; 128],
}

#[repr(C)]
#[derive(Copy, Clone, Debug, Default, PartialEq)]
pub struct DKSubtitleInterval {
    pub start_sec: f64,
    pub end_sec: f64,
}

#[repr(C)]
#[derive(Copy, Clone, Debug)]
pub struct DKSubtitleStyleConfig {
    pub scale: f32,
    pub border_width: f32,
    pub vertical_pos_percent: f32,
    pub primary_delay_sec: f64,
    pub secondary_delay_sec: f64,
    pub text_transform: i32,
    pub override_ass_style: bool,
    pub forced_only: bool,
    pub unify_pingfang_font: bool,
    pub enhance_secondary_yellow: bool,
    pub secondary_scale: f32,
    pub dual_gap_px: f32,
    pub primary_on_top: bool,
    pub dual_layout_mode: i32,
    pub dual_anchor_mode: i32,
}

impl Default for DKSubtitleStyleConfig {
    fn default() -> Self {
        Self {
            scale: 1.0,
            border_width: 2.2,
            vertical_pos_percent: 92.0,
            primary_delay_sec: 0.0,
            secondary_delay_sec: 0.0,
            text_transform: 0,
            override_ass_style: false,
            forced_only: false,
            unify_pingfang_font: true,
            enhance_secondary_yellow: true,
            secondary_scale: 0.60,
            dual_gap_px: 7.0,
            primary_on_top: true,
            dual_layout_mode: 0,
            dual_anchor_mode: 0,
        }
    }
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct DKGpuColorUniforms {
    pub transfer_fn: i32,
    pub primaries: i32,
    pub is_full_range: i32,
    pub bit_depth: i32,

    pub use_dovi_chain: i32,
    pub has_dovi_reshape: i32,
    pub source_peak_nits: f32,
    pub edr_headroom: f32,

    pub ycc_offset: [f32; 4],

    pub yuv_matrix_r0: [f32; 4],
    pub yuv_matrix_r1: [f32; 4],
    pub yuv_matrix_r2: [f32; 4],

    pub lin_matrix_r0: [f32; 4],
    pub lin_matrix_r1: [f32; 4],
    pub lin_matrix_r2: [f32; 4],

    pub reshape_pieces: [i32; 4],
    pub reshape_pivots: [f32; 36],
    pub reshape_coeffs: [f32; 96],
    pub reshape_mmr_meta: [i32; 24],
    pub reshape_mmr_coeffs: [f32; 576],
}

impl DKGpuColorUniforms {
    /// Standard BT.709 limited-range SDR defaults matching Metal shader expectations.
    pub fn default_sdr() -> Self {
        let mut u: Self = unsafe { std::mem::zeroed() };
        u.transfer_fn = 0;
        u.primaries = 0;
        u.is_full_range = 0;
        u.bit_depth = 8;
        u.source_peak_nits = 203.0;
        u.edr_headroom = 1.0;
        u.ycc_offset = [16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0, 1.0];
        u.yuv_matrix_r0 = [1.1643836, 0.0, 1.7927411, 0.0];
        u.yuv_matrix_r1 = [1.1643836, -0.2132486, -0.5329093, 0.0];
        u.yuv_matrix_r2 = [1.1643836, 2.1124018, 0.0, 0.0];
        u.lin_matrix_r0 = [1.0, 0.0, 0.0, 0.0];
        u.lin_matrix_r1 = [0.0, 1.0, 0.0, 0.0];
        u.lin_matrix_r2 = [0.0, 0.0, 1.0, 0.0];
        u
    }
}

pub(crate) fn cchar_array_to_string(arr: &[c_char]) -> String {
    unsafe { CStr::from_ptr(arr.as_ptr()) }.to_string_lossy().into_owned()
}

pub(crate) fn write_str_to_cchar<const N: usize>(dst: &mut [c_char; N], s: &str) {
    *dst = [0 as c_char; N];
    let bytes = s.as_bytes();
    let n = bytes.len().min(N.saturating_sub(1));
    for i in 0..n {
        dst[i] = bytes[i] as c_char;
    }
}

pub type DKCustomIOReadCallback =
    Option<unsafe extern "C" fn(opaque: *mut c_void, buf: *mut u8, buf_size: c_int) -> c_int>;
pub type DKCustomIOSeekCallback =
    Option<unsafe extern "C" fn(opaque: *mut c_void, offset: i64, whence: c_int) -> i64>;
pub type DKCustomIOAbortCallback = Option<unsafe extern "C" fn(opaque: *mut c_void)>;
pub type DKCustomIOCloseCallback = Option<unsafe extern "C" fn(opaque: *mut c_void)>;

pub type DKLogCallback = Option<unsafe extern "C" fn(level: c_int, message: *const c_char)>;
pub type DKSubtitleRgbaCallback = Option<
    unsafe extern "C" fn(
        rgba: *const u8,
        width: i32,
        height: i32,
        serial: u64,
        context: *mut c_void,
    ),
>;

// Lock C ABI sizes and alignments to Sources/DonbyKernelC/include/donby_kernel.h at compile time.
const _: () = {
    assert!(std::mem::size_of::<DKPlayerState>() == 4);
    assert!(std::mem::align_of::<DKPlayerState>() == 4);
    assert!(std::mem::size_of::<DKRuntimeStats>() == 160);
    assert!(std::mem::align_of::<DKRuntimeStats>() == 8);
    assert!(std::mem::size_of::<DKTrackInfo>() == 204);
    assert!(std::mem::align_of::<DKTrackInfo>() == 4);
    assert!(std::mem::size_of::<DKChapterInfo>() == 152);
    assert!(std::mem::align_of::<DKChapterInfo>() == 8);
    assert!(std::mem::size_of::<DKSubtitleInterval>() == 16);
    assert!(std::mem::align_of::<DKSubtitleInterval>() == 8);
    assert!(std::mem::size_of::<DKSubtitleStyleConfig>() == 64);
    assert!(std::mem::align_of::<DKSubtitleStyleConfig>() == 8);
    assert!(std::mem::size_of::<DKGpuColorUniforms>() == 3088);
    assert!(std::mem::align_of::<DKGpuColorUniforms>() == 4);
};

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::offset_of;

    #[test]
    fn c_abi_field_offsets_match_clang_darwin64() {
        assert_eq!(offset_of!(DKRuntimeStats, fps), 16);
        assert_eq!(offset_of!(DKRuntimeStats, is_hdr), 32);
        assert_eq!(offset_of!(DKRuntimeStats, video_codec), 35);
        assert_eq!(offset_of!(DKRuntimeStats, cached_bytes), 136);

        assert_eq!(offset_of!(DKTrackInfo, codec), 11);
        assert_eq!(offset_of!(DKTrackInfo, title), 75);

        assert_eq!(offset_of!(DKChapterInfo, start_sec), 8);
        assert_eq!(offset_of!(DKChapterInfo, title), 24);

        assert_eq!(offset_of!(DKSubtitleStyleConfig, primary_delay_sec), 16);
        assert_eq!(offset_of!(DKSubtitleStyleConfig, text_transform), 32);
        assert_eq!(offset_of!(DKSubtitleStyleConfig, secondary_scale), 40);
        assert_eq!(offset_of!(DKSubtitleStyleConfig, dual_anchor_mode), 56);

        assert_eq!(offset_of!(DKGpuColorUniforms, use_dovi_chain), 16);
        assert_eq!(offset_of!(DKGpuColorUniforms, ycc_offset), 32);
        assert_eq!(offset_of!(DKGpuColorUniforms, reshape_pivots), 160);
        assert_eq!(offset_of!(DKGpuColorUniforms, reshape_mmr_meta), 688);
        assert_eq!(offset_of!(DKGpuColorUniforms, reshape_mmr_coeffs), 784);
    }
}
