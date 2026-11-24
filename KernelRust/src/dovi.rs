use crate::abi::DKGpuColorUniforms;

/// Detects HEVC NAL unit type 63 (Dolby Vision EL / FEL) in Annex-B byte streams.
pub fn check_dovi_fel(data: &[u8]) -> bool {
    let n = data.len();
    if n < 5 {
        return false;
    }
    let mut i = 0usize;
    while i + 4 < n {
        let hdr_idx = if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            Some(i + 3)
        } else if i + 5 < n && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1 {
            Some(i + 4)
        } else {
            None
        };
        if let Some(h) = hdr_idx {
            let nal_type = (data[h] >> 1) & 0x3F;
            if nal_type == 63 {
                return true;
            }
            i = h + 1;
        } else {
            i += 1;
        }
    }
    false
}

/// SMPTE ST 2084 (PQ) normalized code value [0, 1] -> linear luminance in nits [0, 10000].
pub fn pq_norm_to_nits(e: f64) -> f32 {
    let e = e.clamp(0.0, 1.0);
    if e <= 0.0 {
        return 0.0;
    }
    const M1: f64 = 2610.0 / 16384.0;
    const M2: f64 = 2523.0 / 32.0;
    const C1: f64 = 3424.0 / 4096.0;
    const C2: f64 = 2413.0 / 128.0;
    const C3: f64 = 2392.0 / 128.0;
    let ep = e.powf(1.0 / M2);
    let num = (ep - C1).max(0.0);
    let den = (C2 - C3 * ep).max(1e-6);
    (10000.0 * (num / den).powf(1.0 / M1)) as f32
}

impl DKGpuColorUniforms {
    /// Standard BT.709 limited-range SDR defaults matching Metal shader expectations.
    pub fn default_sdr() -> Self {
        // SAFETY: All fields are f32/i32 arrays; zero-init then populate active matrices.
        let mut u: Self = unsafe { std::mem::zeroed() };
        u.transfer_fn = 0;
        u.primaries = 0;
        u.is_full_range = 0;
        u.bit_depth = 8;
        u.source_peak_nits = 203.0;
        u.edr_headroom = 1.0;
        u.ycc_offset = [16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0, 1.0];
        // BT.709 studio-swing YCbCr -> RGB
        u.yuv_matrix_r0 = [1.1643836, 0.0, 1.7927411, 0.0];
        u.yuv_matrix_r1 = [1.1643836, -0.2132486, -0.5329093, 0.0];
        u.yuv_matrix_r2 = [1.1643836, 2.1124018, 0.0, 0.0];
        // Identity post-EOTF matrix
        u.lin_matrix_r0 = [1.0, 0.0, 0.0, 0.0];
        u.lin_matrix_r1 = [0.0, 1.0, 0.0, 0.0];
        u.lin_matrix_r2 = [0.0, 0.0, 1.0, 0.0];
        u
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_hevc_nal_63_dovi_el_and_ignores_regular_slices() {
        // NAL type 1 (TRAIL_R): (1 << 1) = 0x02
        let normal = [0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0xAA, 0xBB];
        assert!(!check_dovi_fel(&normal));

        // NAL type 62 (RPU = 0x7C) only -> not FEL
        let rpu_only = [0x00, 0x00, 0x01, 0x7C, 0x01, 0x55];
        assert!(!check_dovi_fel(&rpu_only));

        // NAL type 63 (EL = 0x7E) -> FEL/EL present
        let with_el = [0x00, 0x00, 0x00, 0x01, 0x7E, 0x01, 0x99];
        assert!(check_dovi_fel(&with_el));
    }

    #[test]
    fn pq_eotf_reference_anchors_are_accurate() {
        assert_eq!(pq_norm_to_nits(0.0), 0.0);
        let mid = pq_norm_to_nits(0.50807842); // ~100 nits reference white
        assert!((mid - 100.0).abs() < 0.5, "got {mid}");
        let peak = pq_norm_to_nits(1.0);
        assert!((peak - 10000.0).abs() < 1.0, "got {peak}");
    }
}
