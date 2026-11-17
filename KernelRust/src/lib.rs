use std::collections::BTreeMap;
use std::sync::{Arc, RwLock};

struct CacheInner {
    current_bytes: usize,
    chunks: BTreeMap<i64, Arc<Vec<u8>>>,
}

pub struct DKRSArenaCache {
    capacity: usize,
    chunk_size: usize,
    inner: RwLock<CacheInner>,
}

impl DKRSArenaCache {
    pub fn new(capacity: usize, chunk_size: usize) -> Self {
        Self {
            capacity: if capacity == 0 { 64 * 1024 * 1024 } else { capacity },
            chunk_size: if chunk_size == 0 { 256 * 1024 } else { chunk_size },
            inner: RwLock::new(CacheInner {
                current_bytes: 0,
                chunks: BTreeMap::new(),
            }),
        }
    }

    pub fn read(&self, offset: i64, dst: &mut [u8]) -> i32 {
        if offset < 0 || dst.is_empty() {
            return 0;
        }
        let guard = match self.inner.read() {
            Ok(g) => g,
            Err(_) => return 0,
        };

        let chunk_start = (offset / self.chunk_size as i64) * self.chunk_size as i64;
        if let Some(chunk_data) = guard.chunks.get(&chunk_start) {
            let inner_offset = (offset - chunk_start) as usize;
            if inner_offset < chunk_data.len() {
                let avail = chunk_data.len() - inner_offset;
                let copy_len = std::cmp::min(dst.len(), avail);
                dst[..copy_len].copy_from_slice(&chunk_data[inner_offset..inner_offset + copy_len]);
                return copy_len as i32;
            }
        }
        0
    }

    pub fn write(&self, offset: i64, src: &[u8]) {
        if offset < 0 || src.is_empty() || src.len() > self.capacity {
            return;
        }
        let mut guard = match self.inner.write() {
            Ok(g) => g,
            Err(_) => return,
        };

        let chunk_start = (offset / self.chunk_size as i64) * self.chunk_size as i64;
        if let Some(previous) = guard.chunks.remove(&chunk_start) {
            guard.current_bytes = guard.current_bytes.saturating_sub(previous.len());
        }

        let mut data = Vec::with_capacity(src.len());
        data.extend_from_slice(src);

        // FIFO evict if capacity exceeded
        while guard.current_bytes + data.len() > self.capacity {
            let Some(first_key) = guard.chunks.keys().next().copied() else {
                break;
            };
            if let Some(evicted) = guard.chunks.remove(&first_key) {
                guard.current_bytes = guard.current_bytes.saturating_sub(evicted.len());
            } else {
                break;
            }
        }

        guard.current_bytes += data.len();
        guard.chunks.insert(chunk_start, Arc::new(data));
    }

    pub fn clear(&self) {
        if let Ok(mut g) = self.inner.write() {
            g.chunks.clear();
            g.current_bytes = 0;
        }
    }

    pub fn get_bytes(&self) -> usize {
        self.inner.read().map(|g| g.current_bytes).unwrap_or(0)
    }
}

// C-ABI Exports
#[no_mangle]
pub extern "C" fn dk_rs_cache_create(capacity_bytes: usize, chunk_size: usize) -> *mut DKRSArenaCache {
    let cache = Box::new(DKRSArenaCache::new(capacity_bytes, chunk_size));
    Box::into_raw(cache)
}

#[no_mangle]
/// # Safety
/// `cache` must be either null or a pointer previously returned by `dk_rs_cache_create` that has not yet been destroyed.
pub unsafe extern "C" fn dk_rs_cache_destroy(cache: *mut DKRSArenaCache) {
    if !cache.is_null() {
        unsafe { drop(Box::from_raw(cache)); }
    }
}

#[no_mangle]
/// # Safety
/// `cache` must be a valid pointer from `dk_rs_cache_create`, and `dst` must be writable for `size` bytes when positive.
pub unsafe extern "C" fn dk_rs_cache_read(cache: *mut DKRSArenaCache, offset: i64, dst: *mut u8, size: i32) -> i32 {
    if cache.is_null() || dst.is_null() || size <= 0 {
        return 0;
    }
    let c = unsafe { &*cache };
    let slice = unsafe { std::slice::from_raw_parts_mut(dst, size as usize) };
    c.read(offset, slice)
}

#[no_mangle]
/// # Safety
/// `cache` must be a valid pointer from `dk_rs_cache_create`, and `src` must be readable for `size` bytes when positive.
pub unsafe extern "C" fn dk_rs_cache_write(cache: *mut DKRSArenaCache, offset: i64, src: *const u8, size: i32) {
    if cache.is_null() || src.is_null() || size <= 0 {
        return;
    }
    let c = unsafe { &*cache };
    let slice = unsafe { std::slice::from_raw_parts(src, size as usize) };
    c.write(offset, slice);
}

#[no_mangle]
/// # Safety
/// `cache` must be either null or a valid pointer from `dk_rs_cache_create`.
pub unsafe extern "C" fn dk_rs_cache_clear(cache: *mut DKRSArenaCache) {
    if !cache.is_null() {
        let c = unsafe { &*cache };
        c.clear();
    }
}

#[no_mangle]
/// # Safety
/// `cache` must be either null or a valid pointer from `dk_rs_cache_create`.
pub unsafe extern "C" fn dk_rs_cache_get_bytes(cache: *mut DKRSArenaCache) -> usize {
    if cache.is_null() { return 0; }
    let c = unsafe { &*cache };
    c.get_bytes()
}

#[no_mangle]
/// # Safety
/// `nalu_data` must be either null or readable for `nalu_len` bytes.
pub unsafe extern "C" fn dk_rs_check_dovi_fel(nalu_data: *const u8, nalu_len: usize) -> bool {
    if nalu_data.is_null() || nalu_len < 4 {
        return false;
    }
    let slice = unsafe { std::slice::from_raw_parts(nalu_data, nalu_len) };
    // Scan for Dolby Vision RPU header indicator: 0x00 0x00 0x01 + NAL_UNSPEC62 / NAL_UNSPEC63
    for w in slice.windows(4) {
        if w[0] == 0x00 && w[1] == 0x00 && w[2] == 0x01 {
            let nal_type = (w[3] >> 1) & 0x3F;
            if nal_type == 62 || nal_type == 63 {
                return true;
            }
        }
    }
    false
}
