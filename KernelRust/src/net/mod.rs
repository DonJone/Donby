pub mod avio_bridge;
pub mod disk_reconcile;
pub mod disk_store;
pub mod slab;

use std::ffi::{c_char, c_void};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

pub const CHUNK_SIZE_DEFAULT: usize = 524_288;
pub const DARWIN_SEEK_HOLE: i32 = 3;
pub const DARWIN_SEEK_DATA: i32 = 4;
pub const DARWIN_ENXIO: i32 = 6;

extern "C" {
    fn lseek(fd: i32, offset: i64, whence: i32) -> i64;
    fn sysctlbyname(
        name: *const c_char,
        oldp: *mut c_void,
        oldlenp: *mut usize,
        newp: *const c_void,
        newlen: usize,
    ) -> i32;
}

/// Returns the L1 GlobalSlabPool byte budget tiered by physical system RAM:
/// - `< 16 GiB` -> `96 MiB`
/// - `16 ..< 32 GiB` -> `160 MiB`
/// - `32 ..< 64 GiB` -> `256 MiB`
/// - `>= 64 GiB` -> `384 MiB`
pub fn tier_slab_budget_for_physical_ram(mem_bytes: u64) -> usize {
    const GIB: u64 = 1024 * 1024 * 1024;
    const MIB: usize = 1024 * 1024;
    if mem_bytes >= 64 * GIB {
        384 * MIB
    } else if mem_bytes >= 32 * GIB {
        256 * MIB
    } else if mem_bytes >= 16 * GIB {
        160 * MIB
    } else {
        96 * MIB
    }
}

pub fn detect_system_slab_budget_bytes() -> usize {
    let mut mem_bytes: u64 = 0;
    let mut size = std::mem::size_of::<u64>();
    let name = b"hw.memsize\0";
    let rc = unsafe {
        sysctlbyname(
            name.as_ptr() as *const c_char,
            (&mut mem_bytes as *mut u64).cast::<c_void>(),
            &mut size,
            std::ptr::null(),
            0,
        )
    };
    if rc == 0 && mem_bytes > 0 {
        tier_slab_budget_for_physical_ram(mem_bytes)
    } else {
        128 * 1024 * 1024
    }
}

/// Checks whether `[offset, offset + length)` is backed by allocated disk blocks
/// (not past EOF and not inside an unallocated APFS sparse hole).
pub fn is_byte_range_allocated(fd: i32, file_size: u64, offset: u64, length: u64) -> bool {
    if length == 0 || offset.saturating_add(length) > file_size {
        return false;
    }
    let off_i64 = match i64::try_from(offset) {
        Ok(v) => v,
        Err(_) => return false,
    };
    let data_start = unsafe { lseek(fd, off_i64, DARWIN_SEEK_DATA) };
    if data_start < 0 {
        let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
        return err != DARWIN_ENXIO;
    }
    if data_start as u64 != offset {
        return false;
    }
    let hole_start = unsafe { lseek(fd, off_i64, DARWIN_SEEK_HOLE) };
    if hole_start < 0 {
        return true;
    }
    (hole_start as u64) >= offset.saturating_add(length)
}

/// Enumerates all allocated (non-hole) `[start, end)` byte extents in `fd`.
/// Returns `None` if the underlying filesystem does not support `SEEK_DATA`/`SEEK_HOLE`.
pub fn enumerate_allocated_extents(fd: i32, logical_size: u64) -> Option<Vec<(u64, u64)>> {
    if logical_size == 0 {
        return Some(Vec::new());
    }
    let mut extents = Vec::new();
    let mut pos: u64 = 0;
    while pos < logical_size {
        let pos_i64 = i64::try_from(pos).ok()?;
        let ds = unsafe { lseek(fd, pos_i64, DARWIN_SEEK_DATA) };
        if ds < 0 {
            let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            if err == DARWIN_ENXIO {
                break;
            }
            return None;
        }
        let data_start = ds as u64;
        if data_start >= logical_size {
            break;
        }
        let hs = unsafe { lseek(fd, ds, DARWIN_SEEK_HOLE) };
        if hs < 0 {
            return None;
        }
        let hole_start = logical_size.min(hs as u64);
        if hole_start > data_start {
            extents.push((data_start, hole_start));
        }
        if hole_start <= pos {
            break;
        }
        pos = hole_start;
    }
    Some(extents)
}

pub fn is_range_covered(offset: u64, length: u64, extents: &[(u64, u64)]) -> bool {
    if length == 0 || extents.is_empty() {
        return false;
    }
    let Some(end_offset) = offset.checked_add(length) else {
        return false;
    };
    let idx = extents.partition_point(|&(start, _)| start <= offset);
    if idx == 0 {
        return false;
    }
    let (start, end) = extents[idx - 1];
    start <= offset && end >= end_offset
}

// MARK: - Playback Companion Pacer (Dynamic Bandwidth Yielding)

#[derive(Default)]
struct CompanionState {
    active_playback_count: i32,
    lead_cached_chunks: i32,
    in_open_probe: bool,
    last_seek_uptime_ms: u64,
    last_rescue_uptime_ms: u64,
    wire_speed_bps: i64,
    stream_bitrate_bps: i64,
    last_update_ms: u64,
}

static COMPANION_STATE: OnceLock<Mutex<CompanionState>> = OnceLock::new();
static NEXT_STORE_ID: AtomicU64 = AtomicU64::new(1);
static COMPANION_OVERRIDE_BPS: AtomicI64 = AtomicI64::new(-2);

pub(crate) fn next_store_id() -> u64 {
    NEXT_STORE_ID.fetch_add(1, Ordering::Relaxed)
}

fn companion_state() -> &'static Mutex<CompanionState> {
    COMPANION_STATE.get_or_init(|| Mutex::new(CompanionState::default()))
}

fn monotonic_ms() -> u64 {
    static START: OnceLock<std::time::Instant> = OnceLock::new();
    let base = START.get_or_init(std::time::Instant::now);
    (base.elapsed().as_millis() as u64).saturating_add(1)
}

pub fn update_playback_companion_state(
    active_count_delta: i32,
    lead_cached_chunks: i32,
    in_open_probe: bool,
    recent_seek: bool,
    recent_rescue: bool,
    wire_speed_bps: i64,
    stream_bitrate_bps: i64,
) {
    let now = monotonic_ms();
    if let Ok(mut st) = companion_state().lock() {
        st.active_playback_count = (st.active_playback_count + active_count_delta).max(0);
        if st.active_playback_count == 0 {
            st.lead_cached_chunks = 0;
            st.in_open_probe = false;
            st.last_seek_uptime_ms = 0;
            st.last_rescue_uptime_ms = 0;
        } else if active_count_delta >= 0 {
            st.lead_cached_chunks = lead_cached_chunks.max(0);
            st.in_open_probe = in_open_probe;
            if recent_seek {
                st.last_seek_uptime_ms = now;
            }
            if recent_rescue {
                st.last_rescue_uptime_ms = now;
            }
            if wire_speed_bps > 0 {
                st.wire_speed_bps = wire_speed_bps;
            }
            if stream_bitrate_bps > 0 {
                st.stream_bitrate_bps = stream_bitrate_bps;
            }
            st.last_update_ms = now;
        }
    }
}

/// Returns:
/// - `-1`: unlimited (no active remote playback)
/// - `0`: pause download (playback opening, recent seek `< 3s`, recent rescue `< 10s`, or `< 32 MiB` cushion)
/// - `> 0`: allowed companion download bytes/sec when playback cushion `>= 32 MiB`
pub fn current_companion_rate_limit_bps() -> i64 {
    let ov = COMPANION_OVERRIDE_BPS.load(Ordering::Acquire);
    if ov >= -1 {
        return ov;
    }
    let now = monotonic_ms();
    let Ok(st) = companion_state().lock() else {
        return 0;
    };
    if st.active_playback_count <= 0 {
        return -1;
    }
    if st.in_open_probe || st.lead_cached_chunks < 64 {
        return 0;
    }
    if st.last_seek_uptime_ms > 0 && now.saturating_sub(st.last_seek_uptime_ms) < 3_000 {
        return 0;
    }
    if st.last_rescue_uptime_ms > 0 && now.saturating_sub(st.last_rescue_uptime_ms) < 10_000 {
        return 0;
    }
    let bitrate = st.stream_bitrate_bps.max(12_000_000);
    let required_bps = (bitrate / 8) * 16 / 10;
    let headroom = if st.wire_speed_bps > 0 {
        (st.wire_speed_bps - required_bps).max(1_048_576)
    } else {
        2_097_152
    };
    headroom.min(16 * 1024 * 1024)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ram_tier_sizing_matches_policy() {
        const GIB: u64 = 1024 * 1024 * 1024;
        const MIB: usize = 1024 * 1024;
        assert_eq!(tier_slab_budget_for_physical_ram(8 * GIB), 96 * MIB);
        assert_eq!(tier_slab_budget_for_physical_ram(16 * GIB), 160 * MIB);
        assert_eq!(tier_slab_budget_for_physical_ram(32 * GIB), 256 * MIB);
        assert_eq!(tier_slab_budget_for_physical_ram(64 * GIB), 384 * MIB);
        assert_eq!(tier_slab_budget_for_physical_ram(128 * GIB), 384 * MIB);
    }

    #[test]
    fn companion_pacer_yields_on_shallow_buffer_and_allows_on_deep_cushion() {
        if let Ok(mut st) = companion_state().lock() {
            *st = CompanionState::default();
        }
        assert_eq!(current_companion_rate_limit_bps(), -1);

        // Shallow buffer (< 64 chunks = 32 MiB) -> pause (0)
        update_playback_companion_state(1, 20, false, false, false, 12_000_000, 40_000_000);
        assert_eq!(current_companion_rate_limit_bps(), 0);

        // Deep cushion (>= 64 chunks) without recent seek/rescue -> positive pace
        update_playback_companion_state(0, 72, false, false, false, 16_000_000, 40_000_000);
        assert!(current_companion_rate_limit_bps() >= 1_048_576);

        // Recent seek -> immediate yield (0)
        update_playback_companion_state(0, 72, false, true, false, 16_000_000, 40_000_000);
        assert_eq!(current_companion_rate_limit_bps(), 0);

        // Release playback -> unlimited (-1)
        update_playback_companion_state(-1, 0, false, false, false, 0, 0);
        assert_eq!(current_companion_rate_limit_bps(), -1);
    }
}
