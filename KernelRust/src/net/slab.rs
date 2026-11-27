use crate::net::detect_system_slab_budget_bytes;
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};

pub const SLAB_PAGE_CAPACITY: usize = 524_288;

pub struct SlabPage {
    buf: Box<[u8]>,
}

impl SlabPage {
    pub fn new_heap() -> Self {
        let v = vec![0u8; SLAB_PAGE_CAPACITY];
        Self {
            buf: v.into_boxed_slice(),
        }
    }

    #[inline]
    pub fn as_slice(&self) -> &[u8] {
        &self.buf
    }

    #[inline]
    pub fn as_mut_slice(&mut self) -> &mut [u8] {
        &mut self.buf
    }
}

pub enum CachedPayload {
    Slab(SlabPage, usize),
    Heap(Vec<u8>),
}

impl CachedPayload {
    #[inline]
    pub fn as_bytes(&self) -> &[u8] {
        match self {
            Self::Slab(page, len) => &page.as_slice()[..(*len).min(SLAB_PAGE_CAPACITY)],
            Self::Heap(v) => v.as_slice(),
        }
    }

    #[inline]
    pub fn len(&self) -> usize {
        match self {
            Self::Slab(_, len) => *len,
            Self::Heap(v) => v.len(),
        }
    }
}

pub struct CachedEntry {
    pub payload: CachedPayload,
}

struct StoreRegistry {
    chunks: HashMap<i32, Arc<CachedEntry>>,
    total_chunks: i32,
}

impl StoreRegistry {
    fn new() -> Self {
        Self {
            chunks: HashMap::new(),
            total_chunks: 0,
        }
    }
}

pub struct GlobalSlabPool {
    free_pages: Vec<SlabPage>,
    max_bytes: usize,
    cached_bytes: usize,
    stores: HashMap<u64, StoreRegistry>,
    lru_order: VecDeque<(u64, i32)>,
}

static GLOBAL_POOL: OnceLock<Mutex<GlobalSlabPool>> = OnceLock::new();

pub fn global_slab_pool() -> &'static Mutex<GlobalSlabPool> {
    GLOBAL_POOL.get_or_init(|| Mutex::new(GlobalSlabPool::new(detect_system_slab_budget_bytes())))
}

impl GlobalSlabPool {
    pub fn new(max_bytes: usize) -> Self {
        Self {
            free_pages: Vec::with_capacity(32),
            max_bytes: max_bytes.clamp(32 * 1024 * 1024, 2 * 1024 * 1024 * 1024),
            cached_bytes: 0,
            stores: HashMap::new(),
            lru_order: VecDeque::new(),
        }
    }

    pub fn set_budget_bytes(&mut self, max_bytes: usize) {
        self.max_bytes = max_bytes.clamp(32 * 1024 * 1024, 2 * 1024 * 1024 * 1024);
        self.evict_until_within_budget(0, None);
    }

    pub fn acquire_page(&mut self) -> SlabPage {
        self.free_pages.pop().unwrap_or_else(SlabPage::new_heap)
    }

    pub fn recycle_page(&mut self, page: SlabPage) {
        let max_free = (self.max_bytes / SLAB_PAGE_CAPACITY).max(16);
        if self.free_pages.len() < max_free {
            self.free_pages.push(page);
        }
    }

    pub fn set_store_total_chunks(&mut self, store_id: u64, total_chunks: i32) {
        let reg = self.stores.entry(store_id).or_insert_with(StoreRegistry::new);
        reg.total_chunks = total_chunks.max(0);
    }

    pub fn get_chunk(&self, store_id: u64, chunk_index: i32) -> Option<Arc<CachedEntry>> {
        self.stores.get(&store_id)?.chunks.get(&chunk_index).cloned()
    }

    pub fn has_chunk(&self, store_id: u64, chunk_index: i32) -> bool {
        self.stores
            .get(&store_id)
            .is_some_and(|s| s.chunks.contains_key(&chunk_index))
    }

    pub fn insert_slab(
        &mut self,
        store_id: u64,
        chunk_index: i32,
        page: SlabPage,
        len: usize,
        store_cap_bytes: usize,
    ) {
        let payload = CachedPayload::Slab(page, len.min(SLAB_PAGE_CAPACITY));
        self.insert_payload(store_id, chunk_index, payload, store_cap_bytes);
    }

    pub fn insert_bytes(
        &mut self,
        store_id: u64,
        chunk_index: i32,
        data: &[u8],
        store_cap_bytes: usize,
    ) {
        if data.is_empty() {
            return;
        }
        if data.len() <= SLAB_PAGE_CAPACITY {
            let mut page = self.acquire_page();
            page.as_mut_slice()[..data.len()].copy_from_slice(data);
            self.insert_slab(store_id, chunk_index, page, data.len(), store_cap_bytes);
        } else {
            self.insert_payload(store_id, chunk_index, CachedPayload::Heap(data.to_vec()), store_cap_bytes);
        }
    }

    fn insert_payload(
        &mut self,
        store_id: u64,
        chunk_index: i32,
        payload: CachedPayload,
        store_cap_bytes: usize,
    ) {
        let incoming = payload.len();
        let effective_budget = self.max_bytes.min(store_cap_bytes.max(32 * 1024 * 1024));
        if incoming > effective_budget {
            if let CachedPayload::Slab(page, _) = payload {
                self.recycle_page(page);
            }
            return;
        }
        if let Some(prev) = self
            .stores
            .get_mut(&store_id)
            .and_then(|s| s.chunks.remove(&chunk_index))
        {
            self.cached_bytes = self.cached_bytes.saturating_sub(prev.payload.len());
            self.recycle_entry(prev);
        }
        self.evict_until_within_budget(incoming, Some((store_id, chunk_index)));
        let entry = Arc::new(CachedEntry { payload });
        let reg = self.stores.entry(store_id).or_insert_with(StoreRegistry::new);
        reg.chunks.insert(chunk_index, entry);
        self.cached_bytes += incoming;
        self.lru_order.push_back((store_id, chunk_index));
    }

    pub fn remove_chunk(&mut self, store_id: u64, chunk_index: i32) {
        if let Some(prev) = self
            .stores
            .get_mut(&store_id)
            .and_then(|s| s.chunks.remove(&chunk_index))
        {
            self.cached_bytes = self.cached_bytes.saturating_sub(prev.payload.len());
            self.recycle_entry(prev);
        }
    }

    pub fn remove_store(&mut self, store_id: u64) {
        if let Some(reg) = self.stores.remove(&store_id) {
            for (_, entry) in reg.chunks {
                self.cached_bytes = self.cached_bytes.saturating_sub(entry.payload.len());
                self.recycle_entry(entry);
            }
        }
        self.lru_order.retain(|&(sid, _)| sid != store_id);
    }

    pub fn evict_behind_cursor(&mut self, store_id: u64, cursor_chunk: i32, keep_back: i32, backed_by_disk: bool) {
        let threshold = cursor_chunk - keep_back.max(2);
        if threshold <= 0 {
            return;
        }
        let soft_cap = if backed_by_disk {
            (self.max_bytes * 3 / 4).min(96 * 1024 * 1024)
        } else {
            self.max_bytes * 3 / 4
        };
        if self.cached_bytes <= soft_cap {
            return;
        }
        let Some(reg) = self.stores.get(&store_id) else {
            return;
        };
        let protected_tail_start = if reg.total_chunks > 4 {
            reg.total_chunks - 2
        } else {
            i32::MAX
        };
        let victims: Vec<i32> = reg
            .chunks
            .keys()
            .copied()
            .filter(|&k| k >= 4 && k < threshold && k < protected_tail_start)
            .collect();
        for k in victims {
            self.remove_chunk(store_id, k);
        }
    }

    pub fn evict_distant_chunks(
        &mut self,
        store_id: u64,
        center_chunk: i32,
        keep_back: i32,
        keep_ahead: i32,
    ) {
        let soft_cap = (self.max_bytes * 3 / 4).min(96 * 1024 * 1024);
        if self.cached_bytes <= soft_cap {
            return;
        }
        let Some(reg) = self.stores.get(&store_id) else {
            return;
        };
        let protected_tail_start = if reg.total_chunks > 4 {
            reg.total_chunks - 2
        } else {
            i32::MAX
        };
        let keep_lo = (center_chunk - keep_back).max(4);
        let keep_hi = center_chunk + keep_ahead;
        let victims: Vec<i32> = reg
            .chunks
            .keys()
            .copied()
            .filter(|&k| k >= 4 && k < protected_tail_start && (k < keep_lo || k > keep_hi))
            .collect();
        for k in victims {
            self.remove_chunk(store_id, k);
        }
    }

    pub fn trim_idle_keeping_pinned(&mut self, store_id: u64) {
        let Some(reg) = self.stores.get(&store_id) else {
            return;
        };
        let protected_tail_start = if reg.total_chunks > 4 {
            reg.total_chunks - 2
        } else {
            i32::MAX
        };
        let victims: Vec<i32> = reg
            .chunks
            .keys()
            .copied()
            .filter(|&k| k >= 4 && k < protected_tail_start)
            .collect();
        for k in victims {
            self.remove_chunk(store_id, k);
        }
        self.free_pages.truncate(16);
    }

    pub fn cached_bytes_total(&self) -> usize {
        self.cached_bytes
    }

    fn is_anchor_chunk(total_chunks: i32, idx: i32) -> bool {
        idx < 4 || (total_chunks > 4 && idx >= total_chunks - 2)
    }

    fn evict_until_within_budget(&mut self, incoming: usize, protect: Option<(u64, i32)>) {
        // Pass 1: evict non-anchor LRU entries first
        let mut scanned = 0usize;
        let max_scan = self.lru_order.len();
        while self.cached_bytes + incoming > self.max_bytes && scanned < max_scan {
            let Some((sid, idx)) = self.lru_order.pop_front() else {
                break;
            };
            scanned += 1;
            if protect == Some((sid, idx)) {
                self.lru_order.push_back((sid, idx));
                continue;
            }
            let is_anchor = self
                .stores
                .get(&sid)
                .is_some_and(|s| Self::is_anchor_chunk(s.total_chunks, idx));
            if is_anchor {
                self.lru_order.push_back((sid, idx));
                continue;
            }
            if let Some(prev) = self.stores.get_mut(&sid).and_then(|s| s.chunks.remove(&idx)) {
                self.cached_bytes = self.cached_bytes.saturating_sub(prev.payload.len());
                self.recycle_entry(prev);
            }
        }
        // Pass 2: if still over budget (e.g. many pinned anchors), evict oldest entries regardless
        while self.cached_bytes + incoming > self.max_bytes {
            let Some((sid, idx)) = self.lru_order.pop_front() else {
                break;
            };
            if protect == Some((sid, idx)) {
                continue;
            }
            if let Some(prev) = self.stores.get_mut(&sid).and_then(|s| s.chunks.remove(&idx)) {
                self.cached_bytes = self.cached_bytes.saturating_sub(prev.payload.len());
                self.recycle_entry(prev);
            }
        }
    }

    fn recycle_entry(&mut self, entry: Arc<CachedEntry>) {
        if let Ok(owned) = Arc::try_unwrap(entry) {
            if let CachedPayload::Slab(page, _) = owned.payload {
                self.recycle_page(page);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slab_pool_enforces_hard_cap_and_protects_anchors() {
        let mut pool = GlobalSlabPool::new(32 * 1024 * 1024);
        pool.set_store_total_chunks(1, 200);
        let chunk = vec![0x5Au8; SLAB_PAGE_CAPACITY];
        // Insert anchors 0..4 and tail 198..200
        for idx in [0, 1, 2, 3, 198, 199] {
            pool.insert_bytes(1, idx, &chunk, 32 * 1024 * 1024);
        }
        // Insert 64 normal chunks (32 MiB) -> triggers eviction of non-anchors first
        for idx in 10..74 {
            pool.insert_bytes(1, idx, &chunk, 32 * 1024 * 1024);
        }
        assert!(pool.cached_bytes_total() <= 32 * 1024 * 1024);
        assert!(pool.has_chunk(1, 0));
        assert!(pool.has_chunk(1, 199));
        assert!(!pool.has_chunk(1, 10));
    }
}
