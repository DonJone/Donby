use crate::net::disk_store::{DKChunkStore, PendingWriteData, StoreMetaState};
use crate::net::slab::global_slab_pool;
use crate::net::{enumerate_allocated_extents, is_range_covered};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::FileExt;
use std::os::unix::io::AsRawFd;
use std::sync::atomic::Ordering;
use std::sync::Arc;

const BITMAP_MAGIC: &[u8; 4] = b"DKBM";
const BITMAP_VERSION: u32 = 1;
const BITMAP_HEADER_LEN: usize = 32;

impl DKChunkStore {
    pub fn invalidate_probe_chunks(&self) {
        self.drain_pending_disk();
        let mut targets = Vec::new();
        let snap = {
            let Ok(mut st) = self.meta_mtx.lock() else {
                return;
            };
            if st.removed_tombstone {
                return;
            }
            let total = Self::calc_total_chunks(st.total_size, st.chunk_size);
            let head_end = if total > 0 { total.min(4) } else { 4 };
            for i in 0..head_end {
                targets.push(i);
            }
            if total > 4 {
                targets.push(total - 2);
                targets.push(total - 1);
            }
            for &idx in &targets {
                st.clear_bit(idx);
                st.pending_disk.remove(&idx);
            }
            st.bitmap_dirty = true;
            if (st.persist_disk || st.pinned) && !st.closed_for_disk {
                Some(self.snapshot_bitmap_locked(&st))
            } else {
                None
            }
        };
        if let Ok(mut pool) = global_slab_pool().lock() {
            for idx in targets {
                pool.remove_chunk(self.store_id, idx);
            }
        }
        if let Some(bytes) = snap {
            self.write_bitmap_file(&bytes);
        }
    }

    pub fn flush_sync(&self) {
        self.drain_pending_disk();
        let snap = {
            let Ok(mut st) = self.meta_mtx.lock() else {
                return;
            };
            if st.removed_tombstone || st.closed_for_disk || !(st.persist_disk || st.pinned) {
                return;
            }
            if !st.bitmap_dirty && !self.bitmap_path.exists() && st.completed_count == 0 {
                return;
            }
            st.bitmap_dirty = false;
            Some(self.snapshot_bitmap_locked(&st))
        };
        if let Some(bytes) = snap {
            self.write_bitmap_file(&bytes);
        }
    }

    pub fn close_handles(&self) {
        self.drain_pending_disk();
        let snap = {
            let Ok(mut st) = self.meta_mtx.lock() else {
                return;
            };
            st.closed_for_disk = true;
            st.read_file = None;
            st.write_file = None;
            st.pending_disk.clear();
            if !st.removed_tombstone && (st.persist_disk || st.pinned) && st.completed_count > 0 {
                st.bitmap_dirty = false;
                Some(self.snapshot_bitmap_locked(&st))
            } else {
                None
            }
        };
        if let Some(bytes) = snap {
            self.write_bitmap_file(&bytes);
        }
    }

    pub fn invalidate_for_removal(&self) {
        self.removed_flag.store(true, Ordering::Release);
        {
            let Ok(mut st) = self.meta_mtx.lock() else {
                return;
            };
            st.removed_tombstone = true;
            st.closed_for_disk = true;
            st.pending_disk.clear();
            while st.in_flight_write.is_some() {
                match self.flush_cv.wait(st) {
                    Ok(next) => st = next,
                    Err(_) => return,
                }
            }
            st.read_file = None;
            st.write_file = None;
        }
        self.flush_cv.notify_all();
        if let Ok(mut pool) = global_slab_pool().lock() {
            pool.remove_store(self.store_id);
        }
    }

    pub(crate) fn drain_pending_disk(&self) {
        let Ok(mut st) = self.meta_mtx.lock() else {
            return;
        };
        while !st.removed_tombstone && (!st.pending_disk.is_empty() || st.in_flight_write.is_some())
        {
            let Ok(next) = self.flush_cv.wait(st) else { break };
            st = next;
        }
    }

    pub(crate) fn process_disk_job(&self, chunk_index: i32) {
        let (pending, file_offset) = {
            let Ok(mut st) = self.meta_mtx.lock() else {
                return;
            };
            if st.removed_tombstone || st.closed_for_disk || !(st.persist_disk || st.pinned) {
                st.pending_disk.remove(&chunk_index);
                self.flush_cv.notify_all();
                return;
            }
            let Some(p) = st.pending_disk.remove(&chunk_index) else {
                self.flush_cv.notify_all();
                return;
            };
            st.in_flight_write = Some((chunk_index, Arc::clone(&p)));
            if st.write_file.is_none() {
                let _ = fs::create_dir_all(&self.asset_dir);
                st.write_file = OpenOptions::new()
                    .create(true)
                    .write(true)
                    .read(true)
                    .open(&self.media_bin_path)
                    .ok();
            }
            let off = (chunk_index as u64) * (st.chunk_size as u64);
            (p, off)
        };

        let mut wrote_ok = false;
        let write_fd_clone = self
            .meta_mtx
            .lock()
            .ok()
            .and_then(|s| s.write_file.as_ref().and_then(|f| f.try_clone().ok()));
        if let Some(wf) = write_fd_clone {
            wrote_ok = wf.write_all_at(pending.as_bytes(), file_offset).is_ok();
        }

        let mut bitmap_snap: Option<Vec<u8>> = None;
        if let Ok(mut st) = self.meta_mtx.lock() {
            if let Some((_, inflight_data)) = st.in_flight_write.take() {
                if let Ok(owned) = Arc::try_unwrap(inflight_data) {
                    if let PendingWriteData::Slab(page, _) = owned {
                        if let Ok(mut pool) = global_slab_pool().lock() {
                            pool.recycle_page(page);
                        }
                    }
                }
            }
            if let Ok(owned) = Arc::try_unwrap(pending) {
                if let PendingWriteData::Slab(page, _) = owned {
                    if let Ok(mut pool) = global_slab_pool().lock() {
                        pool.recycle_page(page);
                    }
                }
            }
            if !wrote_ok && !st.removed_tombstone {
                st.clear_bit(chunk_index);
                st.bitmap_dirty = true;
            }
            if !st.removed_tombstone && st.pending_disk.is_empty() && st.bitmap_dirty {
                st.bitmap_dirty = false;
                bitmap_snap = Some(self.snapshot_bitmap_locked(&st));
            }
            self.flush_cv.notify_all();
        }
        if let Some(bytes) = bitmap_snap {
            self.write_bitmap_file(&bytes);
        }
    }

    pub(crate) fn reconcile_on_open(&self, legacy_seed: &[i32]) {
        let mut st = match self.meta_mtx.lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        let chunks_dir = self.asset_dir.join("chunks");
        if chunks_dir.is_dir() {
            let mut folded_any = false;
            if let Ok(entries) = fs::read_dir(&chunks_dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.extension().and_then(|s| s.to_str()) != Some("chk") {
                        continue;
                    }
                    let Some(idx) = path
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .and_then(|s| s.parse::<i32>().ok())
                    else {
                        continue;
                    };
                    if idx < 0 {
                        continue;
                    }
                    if let Ok(bytes) = fs::read(&path) {
                        let req = if st.total_size > 0 {
                            Self::expected_len_locked(&st, idx)
                        } else {
                            1
                        };
                        if req > 0 && bytes.len() >= req {
                            if st.write_file.is_none() {
                                let _ = fs::create_dir_all(&self.asset_dir);
                                st.write_file = OpenOptions::new()
                                    .create(true)
                                    .write(true)
                                    .read(true)
                                    .open(&self.media_bin_path)
                                    .ok();
                            }
                            if let Some(ref wf) = st.write_file {
                                let off = (idx as u64) * (st.chunk_size as u64);
                                if wf.write_all_at(&bytes, off).is_ok() {
                                    st.set_bit(idx);
                                    folded_any = true;
                                }
                            }
                        }
                    }
                }
            }
            let _ = fs::remove_dir_all(&chunks_dir);
            if folded_any {
                st.bitmap_dirty = true;
            }
        }

        if self.bitmap_path.exists() {
            if let Ok(raw) = fs::read(&self.bitmap_path) {
                if let Some((words, _count)) = Self::decode_bitmap(&raw) {
                    for (wi, &w) in words.iter().enumerate() {
                        if wi >= st.completed_words.len() {
                            st.completed_words.resize(wi + 1, 0);
                        }
                        st.completed_words[wi] |= w;
                    }
                    st.completed_count = st
                        .completed_words
                        .iter()
                        .map(|w| w.count_ones() as usize)
                        .sum();
                }
            }
        }
        for &idx in legacy_seed {
            if idx >= 0 {
                st.set_bit(idx);
            }
        }

        if st.completed_count > 0 {
            if !self.media_bin_path.exists() {
                st.completed_words.clear();
                st.completed_count = 0;
                st.bitmap_dirty = true;
            } else if let Ok(rf) = File::open(&self.media_bin_path) {
                let logical_size = rf.metadata().map(|m| m.len()).unwrap_or(0);
                let extents = enumerate_allocated_extents(rf.as_raw_fd(), logical_size);
                let chunk_sz = st.chunk_size as u64;
                let mut valid_words = vec![0u64; st.completed_words.len()];
                let mut valid_count = 0usize;
                let mut pruned = false;
                for (wi, &word) in st.completed_words.iter().enumerate() {
                    let mut w = word;
                    while w != 0 {
                        let tz = w.trailing_zeros() as usize;
                        let idx = (wi * 64 + tz) as i32;
                        w &= w - 1;
                        let off = (idx as u64) * chunk_sz;
                        let req = if st.total_size > 0 {
                            Self::expected_len_locked(&st, idx) as u64
                        } else {
                            chunk_sz.min(logical_size.saturating_sub(off))
                        };
                        let ok = req > 0
                            && off.saturating_add(req) <= logical_size
                            && extents
                                .as_ref()
                                .is_none_or(|exts| is_range_covered(off, req, exts));
                        if ok {
                            StoreMetaState::set_bit_in(&mut valid_words, &mut valid_count, idx);
                        } else {
                            pruned = true;
                        }
                    }
                }
                if pruned {
                    st.completed_words = valid_words;
                    st.completed_count = valid_count;
                    st.bitmap_dirty = true;
                }
            }
        }
        let snap = if st.bitmap_dirty && (st.persist_disk || st.pinned) && st.completed_count > 0
        {
            st.bitmap_dirty = false;
            Some(self.snapshot_bitmap_locked(&st))
        } else {
            None
        };
        drop(st);
        if let Some(bytes) = snap {
            self.write_bitmap_file(&bytes);
        }
    }

    pub(crate) fn snapshot_bitmap_locked(&self, st: &StoreMetaState) -> Vec<u8> {
        let word_count = st.completed_words.len();
        let mut out = Vec::with_capacity(BITMAP_HEADER_LEN + word_count * 8);
        out.extend_from_slice(BITMAP_MAGIC);
        out.extend_from_slice(&BITMAP_VERSION.to_le_bytes());
        out.extend_from_slice(&(st.chunk_size as u32).to_le_bytes());
        out.extend_from_slice(&st.total_size.to_le_bytes());
        out.extend_from_slice(&(word_count as u32).to_le_bytes());
        let mut hash: u64 = 0xcbf29ce484222325;
        for &w in &st.completed_words {
            for b in w.to_le_bytes() {
                hash ^= b as u64;
                hash = hash.wrapping_mul(0x100000001b3);
            }
        }
        out.extend_from_slice(&hash.to_le_bytes());
        for &w in &st.completed_words {
            out.extend_from_slice(&w.to_le_bytes());
        }
        out
    }

    pub(crate) fn decode_bitmap(raw: &[u8]) -> Option<(Vec<u64>, usize)> {
        if raw.len() < BITMAP_HEADER_LEN || &raw[0..4] != BITMAP_MAGIC {
            return None;
        }
        let ver = u32::from_le_bytes(raw[4..8].try_into().ok()?);
        if ver != BITMAP_VERSION {
            return None;
        }
        let word_count = u32::from_le_bytes(raw[20..24].try_into().ok()?) as usize;
        let expected_hash = u64::from_le_bytes(raw[24..32].try_into().ok()?);
        if raw.len() < BITMAP_HEADER_LEN + word_count * 8 {
            return None;
        }
        let body = &raw[BITMAP_HEADER_LEN..BITMAP_HEADER_LEN + word_count * 8];
        let mut hash: u64 = 0xcbf29ce484222325;
        for &b in body {
            hash ^= b as u64;
            hash = hash.wrapping_mul(0x100000001b3);
        }
        if hash != expected_hash {
            return None;
        }
        let mut words = Vec::with_capacity(word_count);
        let mut ones = 0usize;
        for chunk in body.chunks_exact(8) {
            let w = u64::from_le_bytes(chunk.try_into().ok()?);
            ones += w.count_ones() as usize;
            words.push(w);
        }
        Some((words, ones))
    }

    pub(crate) fn write_bitmap_file(&self, bytes: &[u8]) {
        if self.removed_flag.load(Ordering::Acquire) {
            return;
        }
        let _ = fs::create_dir_all(&self.asset_dir);
        let tmp = self.asset_dir.join("chunks.bitmap.tmp");
        if let Ok(mut f) = File::create(&tmp) {
            if f.write_all(bytes).is_ok() {
                let _ = fs::rename(&tmp, &self.bitmap_path);
            } else {
                let _ = fs::remove_file(&tmp);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::next_store_id;

    #[test]
    fn sparse_direct_write_and_tombstone_prevent_zombie_files() {
        let root = std::env::temp_dir().join(format!("donby_rs_store_{}", next_store_id()));
        let _ = fs::remove_dir_all(&root);
        let chunk_sz = 65_536;
        let total = (chunk_sz * 300) as i64;
        {
            let store = DKChunkStore::open(&root, total, chunk_sz, true, false, &[]);
            store.write_slice(256, &vec![0x7B; chunk_sz], false);
            store.write_slice(0, &vec![0x11; chunk_sz], true);
            store.flush_sync();
            assert!(!root.join("chunks").exists());
            assert!(root.join("chunks.bitmap").exists());
            assert_eq!(store.read_full_chunk(256).unwrap()[0], 0x7B);

            let reopened = DKChunkStore::open(&root, total, chunk_sz, true, false, &[]);
            assert!(reopened.has_chunk(0));
            assert!(reopened.has_chunk(256));
            assert!(!reopened.has_chunk(1));

            reopened.invalidate_for_removal();
            let _ = fs::remove_dir_all(&root);
            reopened.flush_sync();
            reopened.close_handles();
        }
        assert!(!root.exists());
    }
}
