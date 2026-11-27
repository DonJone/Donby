use crate::net::slab::{global_slab_pool, SlabPage, SLAB_PAGE_CAPACITY};
use crate::net::{is_byte_range_allocated, next_store_id};
use std::collections::{HashMap, VecDeque};
use std::fs::{File};
use std::os::unix::fs::FileExt;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread;

const MAX_PENDING_DISK_CHUNKS: usize = 128;

pub enum PendingWriteData {
    Slab(SlabPage, usize),
    Heap(Vec<u8>),
}

impl PendingWriteData {
    #[inline]
    pub fn as_bytes(&self) -> &[u8] {
        match self {
            Self::Slab(page, len) => &page.as_slice()[..(*len).min(SLAB_PAGE_CAPACITY)],
            Self::Heap(v) => v.as_slice(),
        }
    }
}

pub(crate) struct StoreMetaState {
    pub(crate) total_size: i64,
    pub(crate) chunk_size: usize,
    pub(crate) persist_disk: bool,
    pub(crate) pinned: bool,
    pub(crate) closed_for_disk: bool,
    pub(crate) removed_tombstone: bool,
    pub(crate) completed_words: Vec<u64>,
    pub(crate) completed_count: usize,
    pub(crate) bitmap_dirty: bool,
    pub(crate) pending_disk: HashMap<i32, Arc<PendingWriteData>>,
    pub(crate) in_flight_write: Option<(i32, Arc<PendingWriteData>)>,
    pub(crate) read_file: Option<File>,
    pub(crate) write_file: Option<File>,
}

impl StoreMetaState {
    pub(crate) fn set_bit_in(words: &mut Vec<u64>, count: &mut usize, index: i32) {
        if index < 0 {
            return;
        }
        let idx = index as usize;
        let w = idx / 64;
        let b = idx % 64;
        if w >= words.len() {
            words.resize(w + 1, 0);
        }
        let mask = 1u64 << b;
        if (words[w] & mask) == 0 {
            words[w] |= mask;
            *count += 1;
        }
    }

    pub(crate) fn set_bit(&mut self, index: i32) {
        Self::set_bit_in(&mut self.completed_words, &mut self.completed_count, index);
    }

    pub(crate) fn clear_bit(&mut self, index: i32) {
        if index < 0 {
            return;
        }
        let idx = index as usize;
        let w = idx / 64;
        let b = idx % 64;
        if w < self.completed_words.len() {
            let mask = 1u64 << b;
            if (self.completed_words[w] & mask) != 0 {
                self.completed_words[w] &= !mask;
                self.completed_count = self.completed_count.saturating_sub(1);
            }
        }
    }

    pub(crate) fn get_bit(&self, index: i32) -> bool {
        if index < 0 {
            return false;
        }
        let idx = index as usize;
        let w = idx / 64;
        let b = idx % 64;
        self.completed_words
            .get(w)
            .is_some_and(|&v| (v & (1u64 << b)) != 0)
    }
}

pub struct DKChunkStore {
    pub store_id: u64,
    pub(crate) asset_dir: PathBuf,
    pub(crate) media_bin_path: PathBuf,
    pub(crate) bitmap_path: PathBuf,
    max_memory_bytes: Mutex<usize>,
    active_readers: AtomicI32,
    pub(crate) removed_flag: AtomicBool,
    pub(crate) meta_mtx: Mutex<StoreMetaState>,
    pub(crate) flush_cv: Condvar,
}

struct DiskWriteJob {
    store: Arc<DKChunkStore>,
    chunk_index: i32,
}

struct DiskWriteQueue {
    jobs: VecDeque<DiskWriteJob>,
}

static DISK_QUEUE: OnceLock<(Mutex<DiskWriteQueue>, Condvar)> = OnceLock::new();

fn disk_queue() -> &'static (Mutex<DiskWriteQueue>, Condvar) {
    DISK_QUEUE.get_or_init(|| {
        let pair = (
            Mutex::new(DiskWriteQueue {
                jobs: VecDeque::new(),
            }),
            Condvar::new(),
        );
        let _ = thread::Builder::new()
            .name("donby-disk-writer".to_string())
            .spawn(disk_writer_loop);
        pair
    })
}

fn disk_writer_loop() {
    let (mtx, cv) = disk_queue();
    loop {
        let job = {
            let Ok(mut q) = mtx.lock() else { return };
            while q.jobs.is_empty() {
                let Ok(next) = cv.wait(q) else { return };
                q = next;
            }
            q.jobs.pop_front()
        };
        if let Some(job) = job {
            job.store.process_disk_job(job.chunk_index);
        }
    }
}

impl DKChunkStore {
    pub fn open(
        asset_dir: &Path,
        total_size: i64,
        chunk_size: usize,
        persist_disk: bool,
        pinned: bool,
        legacy_seed: &[i32],
    ) -> Arc<Self> {
        let store_id = next_store_id();
        let norm_chunk_size = chunk_size.max(65_536);
        let media_bin_path = asset_dir.join("media.bin");
        let bitmap_path = asset_dir.join("chunks.bitmap");
        let state = StoreMetaState {
            total_size: total_size.max(0),
            chunk_size: norm_chunk_size,
            persist_disk: persist_disk || pinned,
            pinned,
            closed_for_disk: false,
            removed_tombstone: false,
            completed_words: Vec::new(),
            completed_count: 0,
            bitmap_dirty: false,
            pending_disk: HashMap::new(),
            in_flight_write: None,
            read_file: None,
            write_file: None,
        };
        let store = Arc::new(Self {
            store_id,
            asset_dir: asset_dir.to_path_buf(),
            media_bin_path,
            bitmap_path,
            max_memory_bytes: Mutex::new(crate::net::detect_system_slab_budget_bytes()),
            active_readers: AtomicI32::new(0),
            removed_flag: AtomicBool::new(false),
            meta_mtx: Mutex::new(state),
            flush_cv: Condvar::new(),
        });
        if let Ok(mut pool) = global_slab_pool().lock() {
            pool.set_store_total_chunks(store_id, store.total_chunks());
        }
        store.reconcile_on_open(legacy_seed);
        store
    }

    pub fn update_config(&self, max_memory_bytes: usize, persist_disk: bool) {
        if let Ok(mut m) = self.max_memory_bytes.lock() {
            *m = max_memory_bytes.clamp(32 * 1024 * 1024, 2 * 1024 * 1024 * 1024);
        }
        if let Ok(mut st) = self.meta_mtx.lock() {
            if st.removed_tombstone {
                return;
            }
            st.persist_disk = persist_disk || st.pinned;
            st.closed_for_disk = false;
        }
    }

    pub fn set_pinned(&self, pinned: bool) {
        let Ok(mut st) = self.meta_mtx.lock() else {
            return;
        };
        if st.removed_tombstone {
            return;
        }
        st.pinned = pinned;
        if pinned {
            st.persist_disk = true;
        }
        if st.completed_count > 0 && !st.closed_for_disk {
            st.bitmap_dirty = true;
            let snap = self.snapshot_bitmap_locked(&st);
            drop(st);
            self.write_bitmap_file(&snap);
        }
    }

    pub fn set_total_size(&self, total_size: i64) {
        if total_size <= 0 {
            return;
        }
        let mut total_chunks = 0;
        let mut snap: Option<Vec<u8>> = None;
        if let Ok(mut st) = self.meta_mtx.lock() {
            if st.removed_tombstone || st.total_size == total_size {
                return;
            }
            st.total_size = total_size;
            total_chunks = Self::calc_total_chunks(st.total_size, st.chunk_size);
            if (st.persist_disk || st.pinned) && !st.closed_for_disk && st.completed_count > 0 {
                st.bitmap_dirty = true;
                snap = Some(self.snapshot_bitmap_locked(&st));
            }
        }
        if let Ok(mut pool) = global_slab_pool().lock() {
            pool.set_store_total_chunks(self.store_id, total_chunks);
        }
        if let Some(bytes) = snap {
            self.write_bitmap_file(&bytes);
        }
    }

    pub fn retain_reader(&self) {
        self.active_readers.fetch_add(1, Ordering::AcqRel);
    }

    pub fn release_reader(&self) -> i32 {
        let prev = self.active_readers.fetch_sub(1, Ordering::AcqRel);
        let rem = (prev - 1).max(0);
        if rem == 0 && prev <= 0 {
            self.active_readers.store(0, Ordering::Release);
        }
        rem
    }

    pub fn active_readers(&self) -> i32 {
        self.active_readers.load(Ordering::Acquire).max(0)
    }

    pub fn total_size(&self) -> i64 {
        self.meta_mtx.lock().map(|s| s.total_size).unwrap_or(0)
    }

    pub fn chunk_size(&self) -> usize {
        self.meta_mtx
            .lock()
            .map(|s| s.chunk_size)
            .unwrap_or(crate::net::CHUNK_SIZE_DEFAULT)
    }

    pub fn total_chunks(&self) -> i32 {
        self.meta_mtx
            .lock()
            .map(|s| Self::calc_total_chunks(s.total_size, s.chunk_size))
            .unwrap_or(0)
    }

    pub fn expected_chunk_len(&self, index: i32) -> usize {
        self.meta_mtx
            .lock()
            .map(|s| Self::expected_len_locked(&s, index))
            .unwrap_or(0)
    }

    pub fn has_chunk(&self, index: i32) -> bool {
        if index < 0 || self.removed_flag.load(Ordering::Acquire) {
            return false;
        }
        if let Ok(pool) = global_slab_pool().lock() {
            if pool.has_chunk(self.store_id, index) {
                return true;
            }
        }
        let Ok(st) = self.meta_mtx.lock() else {
            return false;
        };
        if st.removed_tombstone {
            return false;
        }
        st.pending_disk.contains_key(&index)
            || st.in_flight_write.as_ref().is_some_and(|(i, _)| *i == index)
            || st.get_bit(index)
    }

    pub fn progress(&self) -> (i64, i64, bool) {
        let Ok(st) = self.meta_mtx.lock() else {
            return (0, 0, false);
        };
        let total = st.total_size;
        let total_chunks = Self::calc_total_chunks(total, st.chunk_size);
        let fully = total_chunks > 0 && (st.completed_count as i32) >= total_chunks;
        let count = st.completed_count as i64;
        let cached = if count == 0 {
            0
        } else if total <= 0 {
            count * (st.chunk_size as i64)
        } else {
            let last_idx = total_chunks - 1;
            if st.get_bit(last_idx) {
                let last_len = (total - (last_idx as i64) * (st.chunk_size as i64)).max(0);
                total.min((count - 1) * (st.chunk_size as i64) + last_len)
            } else {
                total.min(count * (st.chunk_size as i64))
            }
        };
        (cached, total, fully)
    }

    pub fn completed_indices(&self) -> Vec<i32> {
        let Ok(st) = self.meta_mtx.lock() else {
            return Vec::new();
        };
        let mut out = Vec::with_capacity(st.completed_count);
        for (word_idx, &word) in st.completed_words.iter().enumerate() {
            let mut w = word;
            while w != 0 {
                let tz = w.trailing_zeros() as usize;
                out.push(((word_idx * 64) + tz) as i32);
                w &= w - 1;
            }
        }
        out
    }

    pub fn write_slice(self: &Arc<Self>, index: i32, data: &[u8], cache_in_l1: bool) {
        if index < 0 || data.is_empty() || self.removed_flag.load(Ordering::Acquire) {
            return;
        }
        if cache_in_l1 && data.len() <= SLAB_PAGE_CAPACITY {
            let store_cap = *self.max_memory_bytes.lock().unwrap_or_else(|e| e.into_inner());
            if let Ok(mut pool) = global_slab_pool().lock() {
                let mut page = pool.acquire_page();
                page.as_mut_slice()[..data.len()].copy_from_slice(data);
                drop(pool);
                self.commit_slab_page_inner(index, page, data.len(), true, store_cap);
                return;
            }
        }
        self.write_pending_data(index, Arc::new(PendingWriteData::Heap(data.to_vec())), cache_in_l1);
    }

    pub fn commit_slab_page(self: &Arc<Self>, index: i32, page: SlabPage, len: usize, cache_in_l1: bool) {
        if index < 0 || len == 0 || self.removed_flag.load(Ordering::Acquire) {
            if let Ok(mut pool) = global_slab_pool().lock() {
                pool.recycle_page(page);
            }
            return;
        }
        let store_cap = *self.max_memory_bytes.lock().unwrap_or_else(|e| e.into_inner());
        self.commit_slab_page_inner(index, page, len, cache_in_l1, store_cap);
    }

    fn commit_slab_page_inner(
        self: &Arc<Self>,
        index: i32,
        page: SlabPage,
        len: usize,
        cache_in_l1: bool,
        store_cap: usize,
    ) {
        let need_disk = {
            let Ok(st) = self.meta_mtx.lock() else {
                if let Ok(mut pool) = global_slab_pool().lock() {
                    pool.recycle_page(page);
                }
                return;
            };
            if st.removed_tombstone {
                if let Ok(mut pool) = global_slab_pool().lock() {
                    pool.recycle_page(page);
                }
                return;
            }
            (st.persist_disk || st.pinned) && !st.closed_for_disk
        };
        if cache_in_l1 && !need_disk {
            if let Ok(mut pool) = global_slab_pool().lock() {
                pool.insert_slab(self.store_id, index, page, len, store_cap);
            }
            self.mark_completed_only(index, len);
            return;
        }
        if cache_in_l1 {
            let bytes = &page.as_slice()[..len.min(SLAB_PAGE_CAPACITY)];
            if let Ok(mut pool) = global_slab_pool().lock() {
                pool.insert_bytes(self.store_id, index, bytes, store_cap);
            }
        }
        self.write_pending_data(index, Arc::new(PendingWriteData::Slab(page, len)), false);
    }

    fn mark_completed_only(&self, index: i32, len: usize) {
        if let Ok(mut st) = self.meta_mtx.lock() {
            if st.removed_tombstone {
                return;
            }
            if st.total_size > 0 {
                let expected = Self::expected_len_locked(&st, index);
                if expected == 0 || len < expected {
                    return;
                }
            }
            st.set_bit(index);
        }
    }

    fn write_pending_data(self: &Arc<Self>, index: i32, pending: Arc<PendingWriteData>, cache_in_l1: bool) {
        let len = pending.as_bytes().len();
        let (should_persist, need_backpressure) = {
            let Ok(mut st) = self.meta_mtx.lock() else {
                return;
            };
            if st.removed_tombstone {
                return;
            }
            if st.total_size > 0 {
                let expected = Self::expected_len_locked(&st, index);
                if expected == 0 || len < expected {
                    return;
                }
            }
            st.set_bit(index);
            let persist = (st.persist_disk || st.pinned) && !st.closed_for_disk;
            if persist {
                st.pending_disk.insert(index, Arc::clone(&pending));
                st.bitmap_dirty = true;
            }
            let bp = persist && st.pending_disk.len() >= MAX_PENDING_DISK_CHUNKS;
            (persist, bp)
        };
        if cache_in_l1 {
            let store_cap = *self.max_memory_bytes.lock().unwrap_or_else(|e| e.into_inner());
            if let Ok(mut pool) = global_slab_pool().lock() {
                pool.insert_bytes(self.store_id, index, pending.as_bytes(), store_cap);
            }
        }
        if !should_persist {
            return;
        }
        let (mtx, cv) = disk_queue();
        if let Ok(mut q) = mtx.lock() {
            q.jobs.push_back(DiskWriteJob {
                store: Arc::clone(self),
                chunk_index: index,
            });
            cv.notify_one();
        }
        if need_backpressure {
            if let Ok(mut st) = self.meta_mtx.lock() {
                while !st.removed_tombstone
                    && !st.closed_for_disk
                    && st.pending_disk.len() >= MAX_PENDING_DISK_CHUNKS
                {
                    let Ok(next) = self.flush_cv.wait(st) else { break };
                    st = next;
                }
            }
        }
    }

    pub fn read_bytes(&self, index: i32, offset_in_chunk: usize, dst: &mut [u8]) -> i32 {
        if index < 0 || dst.is_empty() || self.removed_flag.load(Ordering::Acquire) {
            return -1;
        }
        if let Ok(pool) = global_slab_pool().lock() {
            if let Some(entry) = pool.get_chunk(self.store_id, index) {
                let bytes = entry.payload.as_bytes();
                if offset_in_chunk >= bytes.len() {
                    return 0;
                }
                let n = dst.len().min(bytes.len() - offset_in_chunk);
                dst[..n].copy_from_slice(&bytes[offset_in_chunk..offset_in_chunk + n]);
                return n as i32;
            }
        }

        let (expected_len, has_known_total, chunk_size, pending_arc) = {
            let Ok(st) = self.meta_mtx.lock() else {
                return -1;
            };
            if st.removed_tombstone {
                return -1;
            }
            if let Some(p) = st.pending_disk.get(&index).cloned().or_else(|| {
                st.in_flight_write
                    .as_ref()
                    .and_then(|(i, p)| if *i == index { Some(Arc::clone(p)) } else { None })
            }) {
                (0, false, st.chunk_size, Some(p))
            } else {
                if !st.get_bit(index) {
                    return -1;
                }
                let exp = Self::expected_len_locked(&st, index);
                if exp == 0 {
                    return -1;
                }
                (exp, st.total_size > 0, st.chunk_size, None)
            }
        };

        if let Some(p) = pending_arc {
            let bytes = p.as_bytes();
            if offset_in_chunk >= bytes.len() {
                return 0;
            }
            let n = dst.len().min(bytes.len() - offset_in_chunk);
            dst[..n].copy_from_slice(&bytes[offset_in_chunk..offset_in_chunk + n]);
            return n as i32;
        }

        let file_offset = (index as u64) * (chunk_size as u64);
        let mut st = match self.meta_mtx.lock() {
            Ok(g) => g,
            Err(_) => return -1,
        };
        if st.removed_tombstone {
            return -1;
        }
        if let Some(p) = st.pending_disk.get(&index).cloned() {
            drop(st);
            let bytes = p.as_bytes();
            if offset_in_chunk >= bytes.len() {
                return 0;
            }
            let n = dst.len().min(bytes.len() - offset_in_chunk);
            dst[..n].copy_from_slice(&bytes[offset_in_chunk..offset_in_chunk + n]);
            return n as i32;
        }
        if st.read_file.is_none() && self.media_bin_path.exists() {
            st.read_file = File::open(&self.media_bin_path).ok();
        }
        let mut loaded_valid = false;
        let mut copy_len = 0usize;
        let mut promote_buf: Option<Vec<u8>> = None;

        if let Some(ref rf) = st.read_file {
            let file_size = rf.metadata().map(|m| m.len()).unwrap_or(0);
            let req_len = if has_known_total {
                expected_len as u64
            } else {
                (expected_len as u64).min(file_size.saturating_sub(file_offset))
            };
            if req_len > 0
                && is_byte_range_allocated(rf.as_raw_fd(), file_size, file_offset, req_len)
            {
                let exact_len = req_len as usize;
                if offset_in_chunk >= exact_len {
                    return 0;
                }
                if self.active_readers() > 0 && exact_len <= SLAB_PAGE_CAPACITY {
                    let mut buf = vec![0u8; exact_len];
                    if rf.read_exact_at(&mut buf, file_offset).is_ok() {
                        copy_len = dst.len().min(exact_len - offset_in_chunk);
                        dst[..copy_len]
                            .copy_from_slice(&buf[offset_in_chunk..offset_in_chunk + copy_len]);
                        promote_buf = Some(buf);
                        loaded_valid = true;
                    }
                } else {
                    let max_read = dst.len().min(exact_len - offset_in_chunk);
                    if rf
                        .read_exact_at(&mut dst[..max_read], file_offset + (offset_in_chunk as u64))
                        .is_ok()
                    {
                        copy_len = max_read;
                        loaded_valid = true;
                    }
                }
            }
        }

        if !loaded_valid {
            st.clear_bit(index);
            st.bitmap_dirty = true;
            let should_persist = (st.persist_disk || st.pinned) && !st.closed_for_disk;
            let snap = if should_persist {
                Some(self.snapshot_bitmap_locked(&st))
            } else {
                None
            };
            drop(st);
            if let Some(bytes) = snap {
                self.write_bitmap_file(&bytes);
            }
            return -1;
        }
        drop(st);

        if let Some(buf) = promote_buf {
            let store_cap = *self.max_memory_bytes.lock().unwrap_or_else(|e| e.into_inner());
            if let Ok(mut pool) = global_slab_pool().lock() {
                pool.insert_bytes(self.store_id, index, &buf, store_cap);
            }
        }
        copy_len as i32
    }

    pub fn read_full_chunk(&self, index: i32) -> Option<Vec<u8>> {
        let len = self.expected_chunk_len(index);
        if len == 0 {
            return None;
        }
        let mut buf = vec![0u8; len];
        let n = self.read_bytes(index, 0, &mut buf);
        if n <= 0 {
            return None;
        }
        buf.truncate(n as usize);
        Some(buf)
    }

    pub fn evict_behind_cursor(&self, cursor_chunk: i32, keep_back: i32) {
        let backed = self
            .meta_mtx
            .lock()
            .map(|s| s.persist_disk || s.pinned)
            .unwrap_or(false);
        if let Ok(mut pool) = global_slab_pool().lock() {
            pool.evict_behind_cursor(self.store_id, cursor_chunk, keep_back, backed);
        }
    }

    pub fn evict_distant_chunks(&self, center_chunk: i32, keep_back: i32, keep_ahead: i32) {
        let backed = self
            .meta_mtx
            .lock()
            .map(|s| s.persist_disk || s.pinned)
            .unwrap_or(false);
        if !backed {
            return;
        }
        if let Ok(mut pool) = global_slab_pool().lock() {
            pool.evict_distant_chunks(self.store_id, center_chunk, keep_back, keep_ahead);
        }
    }

    pub fn trim_idle_keeping_pinned(&self) {
        if self.active_readers() > 0 {
            return;
        }
        let backed = self
            .meta_mtx
            .lock()
            .map(|s| (s.persist_disk || s.pinned) && !s.removed_tombstone)
            .unwrap_or(false);
        if !backed {
            return;
        }
        if let Ok(mut pool) = global_slab_pool().lock() {
            pool.trim_idle_keeping_pinned(self.store_id);
        }
    }

    pub(crate) fn calc_total_chunks(total_size: i64, chunk_size: usize) -> i32 {
        if total_size <= 0 || chunk_size == 0 {
            return 0;
        }
        ((total_size + (chunk_size as i64) - 1) / (chunk_size as i64)) as i32
    }

    pub(crate) fn expected_len_locked(st: &StoreMetaState, index: i32) -> usize {
        if index < 0 {
            return 0;
        }
        if st.total_size <= 0 {
            return st.chunk_size;
        }
        let start = (index as i64) * (st.chunk_size as i64);
        if start >= st.total_size {
            return 0;
        }
        (st.chunk_size as i64).min(st.total_size - start) as usize
    }
}

impl Drop for DKChunkStore {
    fn drop(&mut self) {
        if let Ok(mut pool) = global_slab_pool().lock() {
            pool.remove_store(self.store_id);
        }
    }
}
