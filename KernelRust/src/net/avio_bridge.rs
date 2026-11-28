use crate::abi::{
    DKCustomIOAbortCallback, DKCustomIOCloseCallback, DKCustomIOReadCallback,
    DKCustomIOSeekCallback,
};
use crate::net::disk_store::DKChunkStore;
use crate::net::slab::{global_slab_pool, SlabPage, SLAB_PAGE_CAPACITY};
use std::collections::{BTreeMap, HashMap};
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

struct AttemptPartial {
    start_chunk: i32,
    current_chunk: i32,
    end_chunk_exclusive: i32,
    initial_byte_skip: usize,
    page: Option<SlabPage>,
    buf_len: usize,
    is_rescue: bool,
}

struct BridgePartialsState {
    attempts: HashMap<u64, AttemptPartial>,
    display_attempt_by_chunk: HashMap<i32, u64>,
    direct_slices: BTreeMap<i64, Vec<u8>>,
    in_open_probe: bool,
}

pub struct DKStreamBridge {
    pub store: Arc<DKChunkStore>,
    cursor_offset: AtomicI64,
    aborted: AtomicBool,
    closed: AtomicBool,
    partials_mtx: Mutex<BridgePartialsState>,
    opaque: usize,
    miss_read_cb: DKCustomIOReadCallback,
    seek_cb: DKCustomIOSeekCallback,
    abort_cb: DKCustomIOAbortCallback,
    close_cb: DKCustomIOCloseCallback,
}

impl DKStreamBridge {
    pub fn new(
        store: Arc<DKChunkStore>,
        opaque: *mut c_void,
        miss_read_cb: DKCustomIOReadCallback,
        seek_cb: DKCustomIOSeekCallback,
        abort_cb: DKCustomIOAbortCallback,
        close_cb: DKCustomIOCloseCallback,
    ) -> Arc<Self> {
        store.retain_reader();
        Arc::new(Self {
            store,
            cursor_offset: AtomicI64::new(0),
            aborted: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            partials_mtx: Mutex::new(BridgePartialsState {
                attempts: HashMap::new(),
                display_attempt_by_chunk: HashMap::new(),
                direct_slices: BTreeMap::new(),
                in_open_probe: true,
            }),
            opaque: opaque as usize,
            miss_read_cb,
            seek_cb,
            abort_cb,
            close_cb,
        })
    }

    pub fn cursor_offset(&self) -> i64 {
        self.cursor_offset.load(Ordering::Acquire)
    }

    pub fn set_cursor_offset(&self, offset: i64) {
        self.cursor_offset.store(offset.max(0), Ordering::Release);
    }

    pub fn set_in_open_probe(&self, in_probe: bool) {
        if let Ok(mut st) = self.partials_mtx.lock() {
            st.in_open_probe = in_probe;
        }
    }

    pub fn has_seek_cb(&self) -> bool {
        self.seek_cb.is_some()
    }

    pub fn register_attempt(
        &self,
        attempt_id: u64,
        start_chunk: i32,
        end_chunk_exclusive: i32,
        initial_byte_skip: usize,
        is_rescue: bool,
    ) {
        if let Ok(mut st) = self.partials_mtx.lock() {
            st.attempts.insert(
                attempt_id,
                AttemptPartial {
                    start_chunk,
                    current_chunk: start_chunk,
                    end_chunk_exclusive,
                    initial_byte_skip,
                    page: None,
                    buf_len: 0,
                    is_rescue,
                },
            );
        }
    }

    pub fn update_attempt_end(&self, attempt_id: u64, end_chunk_exclusive: i32) {
        if let Ok(mut st) = self.partials_mtx.lock() {
            if let Some(att) = st.attempts.get_mut(&attempt_id) {
                att.end_chunk_exclusive = end_chunk_exclusive;
            }
        }
    }

    pub fn remove_attempt(&self, attempt_id: u64) {
        let mut recycled_page: Option<SlabPage> = None;
        if let Ok(mut st) = self.partials_mtx.lock() {
            if let Some(att) = st.attempts.remove(&attempt_id) {
                recycled_page = att.page;
            }
            st.display_attempt_by_chunk.retain(|_, aid| *aid != attempt_id);
        }
        if let Some(page) = recycled_page {
            if let Ok(mut pool) = global_slab_pool().lock() {
                pool.recycle_page(page);
            }
        }
    }

    pub fn attempt_buffered_bytes(&self, attempt_id: u64) -> usize {
        self.partials_mtx
            .lock()
            .ok()
            .and_then(|st| st.attempts.get(&attempt_id).map(|a| a.buf_len))
            .unwrap_or(0)
    }

    pub unsafe fn try_read_partial_or_direct(
        &self,
        current_offset: i64,
        target_chunk: i32,
        offset_in_chunk: usize,
        dst: *mut u8,
        count: i32,
    ) -> i32 {
        if dst.is_null() || count <= 0 {
            return 0;
        }
        let dst_slice = std::slice::from_raw_parts_mut(dst, count as usize);
        self.try_copy_partial_or_direct(current_offset, target_chunk, offset_in_chunk, dst_slice)
            .unwrap_or(0) as i32
    }

    pub fn flush_final_attempt(&self, attempt_id: u64, succeeded: bool) -> Option<i32> {
        let chunk_size = self.store.chunk_size().min(SLAB_PAGE_CAPACITY);
        let mut commit_slab: Option<(i32, SlabPage, usize)> = None;
        let mut commit_direct: Option<(i64, Vec<u8>)> = None;
        let mut recycle_only: Option<SlabPage> = None;

        if let Ok(mut st) = self.partials_mtx.lock() {
            if let Some(mut att) = st.attempts.remove(&attempt_id) {
                st.display_attempt_by_chunk.retain(|_, aid| *aid != attempt_id);
                if let Some(page) = att.page.take() {
                    if att.current_chunk == att.end_chunk_exclusive - 1 && att.buf_len > 0 {
                        let skip = if att.current_chunk == att.start_chunk {
                            att.initial_byte_skip
                        } else {
                            0
                        };
                        let expected = self.store.expected_chunk_len(att.current_chunk).min(chunk_size);
                        let needed = expected.saturating_sub(skip);
                        let can_commit = (needed > 0 && att.buf_len >= needed)
                            || (succeeded && self.store.total_size() <= 0);
                        if can_commit {
                            let len = if needed > 0 && att.buf_len >= needed {
                                needed
                            } else {
                                att.buf_len
                            };
                            if skip == 0 {
                                commit_slab = Some((att.current_chunk, page, len));
                            } else {
                                let off = (att.current_chunk as i64) * (chunk_size as i64) + (skip as i64);
                                commit_direct = Some((off, page.as_slice()[..len].to_vec()));
                                recycle_only = Some(page);
                            }
                        } else {
                            recycle_only = Some(page);
                        }
                    } else {
                        recycle_only = Some(page);
                    }
                }
            }
        }

        if let Some(page) = recycle_only {
            if let Ok(mut pool) = global_slab_pool().lock() {
                pool.recycle_page(page);
            }
        }
        if let Some((off, vec_data)) = commit_direct {
            if let Ok(mut st) = self.partials_mtx.lock() {
                st.direct_slices.insert(off, vec_data);
            }
            return None;
        }
        if let Some((idx, page, len)) = commit_slab {
            self.store.commit_slab_page(idx, page, len, true);
            return Some(idx);
        }
        None
    }

    /// Appends network bytes directly into a `SlabPage` and promotes completed chunks into `DKChunkStore`
    /// without intermediate `Data` copies. Returns the number of completed chunk indices written into `out_completed`.
    pub fn ingest_partial(
        &self,
        attempt_id: u64,
        bytes: &[u8],
        out_completed: &mut [i32],
    ) -> usize {
        if bytes.is_empty() || self.aborted.load(Ordering::Acquire) || self.closed.load(Ordering::Acquire) {
            return 0;
        }
        let chunk_size = self.store.chunk_size().min(SLAB_PAGE_CAPACITY);
        let mut completed_count = 0usize;
        let mut pending_commits: Vec<(i32, Option<SlabPage>, Vec<u8>, usize)> = Vec::new();
        let mut direct_commits: Vec<(i64, Vec<u8>)> = Vec::new();

        {
            let Ok(mut st) = self.partials_mtx.lock() else {
                return 0;
            };
            if !st.attempts.contains_key(&attempt_id) {
                return 0;
            }

            let mut input_off = 0usize;
            while input_off < bytes.len() {
                let (cur_idx, skip, cur_buf_len, need_page) = {
                    let Some(att) = st.attempts.get(&attempt_id) else {
                        break;
                    };
                    if att.current_chunk >= att.end_chunk_exclusive {
                        break;
                    }
                    let skip = if att.current_chunk == att.start_chunk {
                        att.initial_byte_skip
                    } else {
                        0
                    };
                    (att.current_chunk, skip, att.buf_len, att.page.is_none())
                };
                let expected = self.store.expected_chunk_len(cur_idx).min(chunk_size);
                if expected <= skip {
                    break;
                }
                let needed = expected - skip;
                if need_page {
                    let Ok(mut pool) = global_slab_pool().lock() else {
                        break;
                    };
                    let page = pool.acquire_page();
                    if let Some(att) = st.attempts.get_mut(&attempt_id) {
                        if att.page.is_none() {
                            att.page = Some(page);
                        } else {
                            pool.recycle_page(page);
                        }
                    } else {
                        pool.recycle_page(page);
                        break;
                    }
                }

                let Some(att) = st.attempts.get_mut(&attempt_id) else {
                    break;
                };
                let space = needed.saturating_sub(cur_buf_len);
                let take = space.min(bytes.len() - input_off);
                if take > 0 {
                    if let Some(ref mut page) = att.page {
                        page.as_mut_slice()[att.buf_len..att.buf_len + take]
                            .copy_from_slice(&bytes[input_off..input_off + take]);
                        att.buf_len += take;
                    }
                    input_off += take;
                }

                if att.buf_len >= needed {
                    let filled_page = att.page.take();
                    att.buf_len = 0;
                    att.current_chunk += 1;
                    let _ = att.is_rescue;
                    if let Some(p) = filled_page {
                        if skip == 0 {
                            pending_commits.push((cur_idx, Some(p), Vec::new(), needed));
                        } else {
                            let slice_off = (cur_idx as i64) * (chunk_size as i64) + (skip as i64);
                            direct_commits.push((slice_off, p.as_slice()[..needed].to_vec()));
                            if let Ok(mut pool) = global_slab_pool().lock() {
                                pool.recycle_page(p);
                            }
                        }
                    }
                    if completed_count < out_completed.len() {
                        out_completed[completed_count] = cur_idx;
                        completed_count += 1;
                    }
                } else {
                    break;
                }
            }

            if let Some(att) = st.attempts.get(&attempt_id) {
                if att.current_chunk < att.end_chunk_exclusive {
                    let cur_idx = att.current_chunk;
                    let cur_len = att.buf_len;
                    let replace = match st.display_attempt_by_chunk.get(&cur_idx).copied() {
                        Some(prev_id) if prev_id != attempt_id => {
                            st.attempts.get(&prev_id).is_none_or(|p| p.buf_len < cur_len)
                        }
                        None => true,
                        _ => false,
                    };
                    if replace {
                        st.display_attempt_by_chunk.insert(cur_idx, attempt_id);
                    }
                }
            }
        }

        if !direct_commits.is_empty() {
            if let Ok(mut st) = self.partials_mtx.lock() {
                for (off, vec_data) in direct_commits {
                    st.direct_slices.insert(off, vec_data);
                }
            }
        }
        for (idx, page_opt, _fallback, len) in pending_commits {
            if let Some(page) = page_opt {
                self.store.commit_slab_page(idx, page, len, true);
            }
        }
        completed_count
    }

    pub fn ingest_direct_slice(&self, start_offset: i64, bytes: &[u8]) {
        if bytes.is_empty() || self.aborted.load(Ordering::Acquire) || self.closed.load(Ordering::Acquire) {
            return;
        }
        if let Ok(mut st) = self.partials_mtx.lock() {
            st.direct_slices.insert(start_offset, bytes.to_vec());
        }
    }

    pub fn clear_direct_slices(&self) {
        if let Ok(mut st) = self.partials_mtx.lock() {
            st.direct_slices.clear();
        }
    }

    /// In-kernel AVIO read: satisfies L1 SlabPool, L2 pread, and active partial pages directly
    /// inside Rust; falls back to `miss_read_cb` only on true uncached misses.
    pub unsafe fn avio_read(&self, dst: *mut u8, count: i32) -> i32 {
        if dst.is_null() || count <= 0 {
            return 0;
        }
        if self.aborted.load(Ordering::Acquire) || self.closed.load(Ordering::Acquire) {
            return -1;
        }
        let cur = self.cursor_offset.load(Ordering::Acquire);
        let total = self.store.total_size();
        if total > 0 && cur >= total {
            return 0;
        }
        let chunk_size = self.store.chunk_size() as i64;
        if chunk_size <= 0 {
            return -1;
        }
        let target_chunk = (cur / chunk_size) as i32;
        let offset_in_chunk = (cur % chunk_size) as usize;
        let dst_slice = std::slice::from_raw_parts_mut(dst, count as usize);

        // Fast Path 1: L1 SlabPool or L2 media.bin pread
        let n = self.store.read_bytes(target_chunk, offset_in_chunk, dst_slice);
        if n > 0 {
            self.cursor_offset.fetch_add(n as i64, Ordering::AcqRel);
            return n;
        }

        // Fast Path 2: Progressive partial slab or direct exact-offset slice
        if let Some(copied) = self.try_copy_partial_or_direct(cur, target_chunk, offset_in_chunk, dst_slice) {
            if copied > 0 {
                self.cursor_offset.fetch_add(copied as i64, Ordering::AcqRel);
                return copied as i32;
            }
        }

        // Slow Path: invoke Swift TurboStreamByteHandle miss/wait handler (without holding any Rust lock)
        if let Some(cb) = self.miss_read_cb {
            if self.opaque != 0 {
                let n = cb(self.opaque as *mut c_void, dst, count);
                if n > 0 {
                    // Single source of truth: advance Rust cursor even if Swift's miss path
                    // satisfied the read from an internal slice without calling set_cursor.
                    self.cursor_offset.store(cur + n as i64, Ordering::Release);
                }
                return n;
            }
        }
        -1
    }

    pub unsafe fn avio_seek(&self, offset: i64, whence: i32) -> i64 {
        const AVSEEK_SIZE: i32 = 0x10000;
        if whence == AVSEEK_SIZE {
            let total = self.store.total_size();
            if total > 0 {
                return total;
            }
        }
        if let Some(cb) = self.seek_cb {
            if self.opaque != 0 {
                let res = cb(self.opaque as *mut c_void, offset, whence);
                if res >= 0 && whence != AVSEEK_SIZE {
                    self.cursor_offset.store(res, Ordering::Release);
                }
                return res;
            }
        }
        -1
    }

    pub unsafe fn abort(&self) {
        self.aborted.store(true, Ordering::Release);
        if let Some(cb) = self.abort_cb {
            if self.opaque != 0 {
                cb(self.opaque as *mut c_void);
            }
        }
    }

    pub unsafe fn close(&self) {
        self.closed.store(true, Ordering::Release);
        self.aborted.store(true, Ordering::Release);
        let mut pages_to_recycle = Vec::new();
        if let Ok(mut st) = self.partials_mtx.lock() {
            for (_, mut att) in st.attempts.drain() {
                if let Some(p) = att.page.take() {
                    pages_to_recycle.push(p);
                }
            }
            st.display_attempt_by_chunk.clear();
            st.direct_slices.clear();
        }
        if !pages_to_recycle.is_empty() {
            if let Ok(mut pool) = global_slab_pool().lock() {
                for p in pages_to_recycle {
                    pool.recycle_page(p);
                }
            }
        }
        self.store.release_reader();
        if let Some(cb) = self.close_cb {
            if self.opaque != 0 {
                cb(self.opaque as *mut c_void);
            }
        }
    }

    fn try_copy_partial_or_direct(
        &self,
        current_offset: i64,
        target_chunk: i32,
        offset_in_chunk: usize,
        dst: &mut [u8],
    ) -> Option<usize> {
        let st = self.partials_mtx.lock().ok()?;
        if let Some(&disp_id) = st.display_attempt_by_chunk.get(&target_chunk) {
            if let Some(att) = st.attempts.get(&disp_id) {
                if att.current_chunk == target_chunk {
                    let skip = if target_chunk == att.start_chunk {
                        att.initial_byte_skip
                    } else {
                        0
                    };
                    if offset_in_chunk >= skip {
                        let rel = offset_in_chunk - skip;
                        if rel < att.buf_len {
                            if let Some(ref page) = att.page {
                                let avail = att.buf_len - rel;
                                let n = dst.len().min(avail);
                                dst[..n].copy_from_slice(&page.as_slice()[rel..rel + n]);
                                return Some(n);
                            }
                        }
                    }
                }
            }
        }
        for (&slice_start, slice_data) in &st.direct_slices {
            let slice_end = slice_start + (slice_data.len() as i64);
            if current_offset >= slice_start && current_offset < slice_end {
                let rel = (current_offset - slice_start) as usize;
                let n = dst.len().min(slice_data.len() - rel);
                dst[..n].copy_from_slice(&slice_data[rel..rel + n]);
                return Some(n);
            }
        }
        None
    }
}

pub struct DKDownloadAssembler {
    store: Arc<DKChunkStore>,
    current_chunk: i32,
    end_chunk: i32,
    page: Option<SlabPage>,
    buf_len: usize,
}

impl DKDownloadAssembler {
    pub fn new(store: Arc<DKChunkStore>, start_chunk: i32, end_chunk: i32) -> Self {
        let page = global_slab_pool().lock().ok().map(|mut p| p.acquire_page());
        Self {
            store,
            current_chunk: start_chunk,
            end_chunk,
            page,
            buf_len: 0,
        }
    }

    pub fn update_end_chunk(&mut self, end_chunk: i32) {
        self.end_chunk = end_chunk;
    }

    pub fn current_chunk(&self) -> i32 {
        self.current_chunk
    }

    pub fn ingest(&mut self, bytes: &[u8], keep_in_l1: bool) -> (i32, i64, bool) {
        let mut committed_chunks = 0i32;
        let mut committed_bytes = 0i64;
        let mut off = 0usize;
        let chunk_sz = self.store.chunk_size().min(SLAB_PAGE_CAPACITY);

        while off < bytes.len() && self.current_chunk <= self.end_chunk {
            let expected = self.store.expected_chunk_len(self.current_chunk).min(chunk_sz);
            if expected == 0 {
                break;
            }
            if self.page.is_none() {
                self.page = global_slab_pool().lock().ok().map(|mut p| p.acquire_page());
            }
            let Some(ref mut page) = self.page else { break };
            let space = expected.saturating_sub(self.buf_len);
            let take = space.min(bytes.len() - off);
            if take > 0 {
                page.as_mut_slice()[self.buf_len..self.buf_len + take]
                    .copy_from_slice(&bytes[off..off + take]);
                self.buf_len += take;
                off += take;
            }
            if self.buf_len >= expected {
                if let Some(filled) = self.page.take() {
                    self.store.commit_slab_page(self.current_chunk, filled, expected, keep_in_l1);
                }
                self.buf_len = 0;
                self.current_chunk += 1;
                committed_chunks += 1;
                committed_bytes += expected as i64;
            }
        }
        (committed_chunks, committed_bytes, self.current_chunk > self.end_chunk)
    }

    pub fn finish(&mut self, keep_in_l1: bool) -> (i32, i64) {
        let mut committed_chunks = 0i32;
        let mut committed_bytes = 0i64;
        if self.current_chunk <= self.end_chunk && self.buf_len > 0 {
            let expected = self.store.expected_chunk_len(self.current_chunk);
            if expected > 0 && self.buf_len >= expected {
                if let Some(filled) = self.page.take() {
                    self.store.commit_slab_page(self.current_chunk, filled, expected, keep_in_l1);
                    self.current_chunk += 1;
                    committed_chunks = 1;
                    committed_bytes = expected as i64;
                }
            }
        }
        if let Some(page) = self.page.take() {
            if let Ok(mut pool) = global_slab_pool().lock() {
                pool.recycle_page(page);
            }
        }
        self.buf_len = 0;
        (committed_chunks, committed_bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_bridge_ingests_slab_and_reads_in_kernel() {
        let root = std::env::temp_dir().join(format!("donby_bridge_{}", crate::net::next_store_id()));
        let _ = std::fs::remove_dir_all(&root);
        let store = DKChunkStore::open(&root, 262_144, 65_536, false, false, &[]);
        let bridge = DKStreamBridge::new(store.clone(), std::ptr::null_mut(), None, None, None, None);
        bridge.register_attempt(1, 0, 2, 0, false);

        let payload = vec![0x3Cu8; 65_536];
        let mut completed = [0i32; 4];
        let count = bridge.ingest_partial(1, &payload[..32_768], &mut completed);
        assert_eq!(count, 0);

        let mut out = vec![0u8; 4096];
        let n_partial = unsafe { bridge.avio_read(out.as_mut_ptr(), 4096) };
        assert_eq!(n_partial, 4096);
        assert_eq!(out[0], 0x3C);

        let count2 = bridge.ingest_partial(1, &payload[32_768..], &mut completed);
        assert_eq!(count2, 1);
        assert_eq!(completed[0], 0);
        assert!(store.has_chunk(0));

        unsafe { bridge.close() };
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn miss_read_advances_rust_cursor_without_swift_set_cursor() {
        unsafe extern "C" fn mock_miss_read(
            _opaque: *mut c_void,
            dst: *mut u8,
            count: i32,
        ) -> i32 {
            let n = count.min(16);
            if n > 0 && !dst.is_null() {
                std::ptr::write_bytes(dst, 0xAA, n as usize);
            }
            n
        }

        let root = std::env::temp_dir().join(format!("donby_bridge_cursor_{}", crate::net::next_store_id()));
        let _ = std::fs::remove_dir_all(&root);
        let store = DKChunkStore::open(&root, 262_144, 65_536, false, false, &[]);
        let dummy_opaque = 1usize as *mut c_void;
        let bridge = DKStreamBridge::new(
            store,
            dummy_opaque,
            Some(mock_miss_read),
            None,
            None,
            None,
        );
        bridge.set_cursor_offset(1000);

        let mut first = [0u8; 16];
        let n1 = unsafe { bridge.avio_read(first.as_mut_ptr(), 16) };
        assert_eq!(n1, 16);
        assert!(first.iter().all(|&b| b == 0xAA));
        assert_eq!(bridge.cursor_offset(), 1016);

        let mut slice = vec![0xAAu8; 16];
        slice.extend_from_slice(&[0xBBu8; 16]);
        bridge.ingest_direct_slice(1000, &slice);

        let mut second = [0u8; 16];
        let n2 = unsafe { bridge.avio_read(second.as_mut_ptr(), 16) };
        assert_eq!(n2, 16);
        assert!(second.iter().all(|&b| b == 0xBB));
        assert_eq!(bridge.cursor_offset(), 1032);

        unsafe { bridge.close() };
        let _ = std::fs::remove_dir_all(&root);
    }
}
