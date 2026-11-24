// Note: Runtime DoVi RPU parsing and PQ EOTF run inside Sources/DonbyKernelC/dk_ffi_shim.c.

/// Detects HEVC NAL unit type 63 (Dolby Vision EL / FEL) in Annex-B byte streams.
#[cfg(test)]
pub fn check_dovi_fel(data: &[u8]) -> bool {
    scan_hevc_nal(data, |t| t == 63)
}

/// Detects HEVC NAL unit type 62 (RPU) or 63 (EL) in Annex-B packets.
pub fn check_dovi_rpu_or_el(data: &[u8]) -> bool {
    scan_hevc_nal(data, |t| t == 62 || t == 63)
}

fn scan_hevc_nal(data: &[u8], pred: impl Fn(u8) -> bool) -> bool {
    let n = data.len();
    if n < 4 {
        return false;
    }
    let mut i = 0usize;
    while i + 3 < n {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            let nal_type = (data[i + 3] >> 1) & 0x3F;
            if pred(nal_type) {
                return true;
            }
            i += 4;
        } else {
            i += 1;
        }
    }
    false
}

/// SMPTE ST 2084 (PQ) normalized code value [0, 1] -> linear luminance in nits [0, 10000].
#[cfg(test)]
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_hevc_nal_62_and_63() {
        let normal = [0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0xAA, 0xBB];
        assert!(!check_dovi_fel(&normal));
        assert!(!check_dovi_rpu_or_el(&normal));

        let rpu_only = [0x00, 0x00, 0x01, 0x7C, 0x01, 0x55];
        assert!(!check_dovi_fel(&rpu_only));
        assert!(check_dovi_rpu_or_el(&rpu_only));

        let with_el = [0x00, 0x00, 0x00, 0x01, 0x7E, 0x01, 0x99];
        assert!(check_dovi_fel(&with_el));
        assert!(check_dovi_rpu_or_el(&with_el));
    }

    #[test]
    fn pq_eotf_reference_anchors_are_accurate() {
        assert_eq!(pq_norm_to_nits(0.0), 0.0);
        let mid = pq_norm_to_nits(0.50807842);
        assert!((mid - 100.0).abs() < 0.5, "got {mid}");
        let peak = pq_norm_to_nits(1.0);
        assert!((peak - 10000.0).abs() < 1.0, "got {peak}");
    }
}
