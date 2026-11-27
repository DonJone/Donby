use crate::abi::{
    DKCustomIOAbortCallback, DKCustomIOCloseCallback, DKCustomIOReadCallback,
    DKCustomIOSeekCallback,
};
use crate::net::avio_bridge::{DKDownloadAssembler, DKStreamBridge};
use crate::net::disk_store::DKChunkStore;
use crate::net::slab::global_slab_pool;
use crate::net::{current_companion_rate_limit_bps, update_playback_companion_state};
use crate::{live_players, DKPlayer};
use std::ffi::{c_char, c_void, CStr};
use std::path::Path;
use std::sync::Arc;

#[no_mangle]
pub unsafe extern "C" fn dk_net_set_memory_budget_bytes(max_bytes: i64) {
    if max_bytes <= 0 {
        return;
    }
    if let Ok(mut pool) = global_slab_pool().lock() {
        pool.set_budget_bytes(max_bytes as usize);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_update_playback_companion_state(
    active_count_delta: i32,
    lead_cached_chunks: i32,
    in_open_probe: bool,
    recent_seek: bool,
    recent_rescue: bool,
    wire_speed_bps: i64,
    stream_bitrate_bps: i64,
) {
    update_playback_companion_state(
        active_count_delta,
        lead_cached_chunks,
        in_open_probe,
        recent_seek,
        recent_rescue,
        wire_speed_bps,
        stream_bitrate_bps,
    );
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_get_download_companion_rate_limit_bps() -> i64 {
    current_companion_rate_limit_bps()
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_open(
    asset_dir_utf8: *const c_char,
    total_size: i64,
    chunk_size: i32,
    persist_disk: bool,
    pinned: bool,
    legacy_seed: *const i32,
    legacy_seed_count: i32,
) -> *mut DKChunkStore {
    if asset_dir_utf8.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(dir_str) = CStr::from_ptr(asset_dir_utf8).to_str() else {
        return std::ptr::null_mut();
    };
    let seed = if !legacy_seed.is_null() && legacy_seed_count > 0 {
        std::slice::from_raw_parts(legacy_seed, legacy_seed_count as usize)
    } else {
        &[]
    };
    let store = DKChunkStore::open(
        Path::new(dir_str),
        total_size,
        chunk_size.max(65_536) as usize,
        persist_disk,
        pinned,
        seed,
    );
    Arc::into_raw(store) as *mut DKChunkStore
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_update_config(
    store: *mut DKChunkStore,
    max_memory_bytes: i64,
    persist_disk: bool,
) {
    if let Some(s) = store.as_ref() {
        s.update_config(max_memory_bytes.max(0) as usize, persist_disk);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_set_pinned(store: *mut DKChunkStore, pinned: bool) {
    if let Some(s) = store.as_ref() {
        s.set_pinned(pinned);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_set_total_size(store: *mut DKChunkStore, total_size: i64) {
    if let Some(s) = store.as_ref() {
        s.set_total_size(total_size);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_retain_reader(store: *mut DKChunkStore) {
    if let Some(s) = store.as_ref() {
        s.retain_reader();
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_release_reader(store: *mut DKChunkStore) -> i32 {
    store.as_ref().map_or(0, |s| s.release_reader())
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_active_readers(store: *mut DKChunkStore) -> i32 {
    store.as_ref().map_or(0, |s| s.active_readers())
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_has_chunk(store: *mut DKChunkStore, chunk_index: i32) -> bool {
    store.as_ref().is_some_and(|s| s.has_chunk(chunk_index))
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_write_slice(
    store: *mut DKChunkStore,
    chunk_index: i32,
    data: *const u8,
    len: i32,
    cache_in_l1: bool,
) {
    if store.is_null() || data.is_null() || len <= 0 {
        return;
    }
    Arc::increment_strong_count(store);
    let arc = Arc::from_raw(store);
    let slice = std::slice::from_raw_parts(data, len as usize);
    arc.write_slice(chunk_index, slice, cache_in_l1);
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_read_bytes(
    store: *mut DKChunkStore,
    chunk_index: i32,
    offset_in_chunk: i32,
    dst: *mut u8,
    count: i32,
) -> i32 {
    if store.is_null() || dst.is_null() || count <= 0 || offset_in_chunk < 0 {
        return -1;
    }
    let slice = std::slice::from_raw_parts_mut(dst, count as usize);
    (*store).read_bytes(chunk_index, offset_in_chunk as usize, slice)
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_get_progress(
    store: *mut DKChunkStore,
    out_cached_bytes: *mut i64,
    out_total_bytes: *mut i64,
    out_fully_cached: *mut bool,
) {
    let Some(s) = store.as_ref() else { return };
    let (cached, total, full) = s.progress();
    if !out_cached_bytes.is_null() {
        *out_cached_bytes = cached;
    }
    if !out_total_bytes.is_null() {
        *out_total_bytes = total;
    }
    if !out_fully_cached.is_null() {
        *out_fully_cached = full;
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_copy_completed_indices(
    store: *mut DKChunkStore,
    out_indices: *mut i32,
    max_count: i32,
) -> i32 {
    let Some(s) = store.as_ref() else { return 0 };
    let indices = s.completed_indices();
    if out_indices.is_null() || max_count <= 0 {
        return indices.len() as i32;
    }
    let n = indices.len().min(max_count as usize);
    std::ptr::copy_nonoverlapping(indices.as_ptr(), out_indices, n);
    indices.len() as i32
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_evict_behind_cursor(
    store: *mut DKChunkStore,
    cursor_chunk: i32,
    keep_back: i32,
) {
    if let Some(s) = store.as_ref() {
        s.evict_behind_cursor(cursor_chunk, keep_back);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_evict_distant_chunks(
    store: *mut DKChunkStore,
    center_chunk: i32,
    keep_back: i32,
    keep_ahead: i32,
) {
    if let Some(s) = store.as_ref() {
        s.evict_distant_chunks(center_chunk, keep_back, keep_ahead);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_trim_idle_keeping_pinned(store: *mut DKChunkStore) {
    if let Some(s) = store.as_ref() {
        s.trim_idle_keeping_pinned();
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_invalidate_probe_chunks(store: *mut DKChunkStore) {
    if let Some(s) = store.as_ref() {
        s.invalidate_probe_chunks();
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_flush(store: *mut DKChunkStore) {
    if let Some(s) = store.as_ref() {
        s.flush_sync();
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_close_handles(store: *mut DKChunkStore) {
    if let Some(s) = store.as_ref() {
        s.close_handles();
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_invalidate_for_removal(store: *mut DKChunkStore) {
    if let Some(s) = store.as_ref() {
        s.invalidate_for_removal();
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_store_release(store: *mut DKChunkStore) {
    if !store.is_null() {
        drop(Arc::from_raw(store));
    }
}

// MARK: - DKStreamBridge C ABI

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_create(
    store: *mut DKChunkStore,
    opaque: *mut c_void,
    miss_read_cb: DKCustomIOReadCallback,
    seek_cb: DKCustomIOSeekCallback,
    abort_cb: DKCustomIOAbortCallback,
    close_cb: DKCustomIOCloseCallback,
) -> *mut DKStreamBridge {
    if store.is_null() {
        return std::ptr::null_mut();
    }
    Arc::increment_strong_count(store);
    let store_arc = Arc::from_raw(store);
    let bridge = DKStreamBridge::new(store_arc, opaque, miss_read_cb, seek_cb, abort_cb, close_cb);
    Arc::into_raw(bridge) as *mut DKStreamBridge
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_get_cursor(bridge: *mut DKStreamBridge) -> i64 {
    bridge.as_ref().map_or(0, |b| b.cursor_offset())
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_set_cursor(bridge: *mut DKStreamBridge, offset: i64) {
    if let Some(b) = bridge.as_ref() {
        b.set_cursor_offset(offset);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_set_in_open_probe(bridge: *mut DKStreamBridge, in_probe: bool) {
    if let Some(b) = bridge.as_ref() {
        b.set_in_open_probe(in_probe);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_register_attempt(
    bridge: *mut DKStreamBridge,
    attempt_id: u64,
    start_chunk: i32,
    end_chunk_exclusive: i32,
    initial_byte_skip: i32,
    is_rescue: bool,
) {
    if let Some(b) = bridge.as_ref() {
        b.register_attempt(
            attempt_id,
            start_chunk,
            end_chunk_exclusive,
            initial_byte_skip.max(0) as usize,
            is_rescue,
        );
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_update_attempt_end(
    bridge: *mut DKStreamBridge,
    attempt_id: u64,
    end_chunk_exclusive: i32,
) {
    if let Some(b) = bridge.as_ref() {
        b.update_attempt_end(attempt_id, end_chunk_exclusive);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_remove_attempt(bridge: *mut DKStreamBridge, attempt_id: u64) {
    if let Some(b) = bridge.as_ref() {
        b.remove_attempt(attempt_id);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_attempt_buffered_bytes(
    bridge: *mut DKStreamBridge,
    attempt_id: u64,
) -> i32 {
    bridge
        .as_ref()
        .map_or(0, |b| b.attempt_buffered_bytes(attempt_id) as i32)
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_try_read_partial_or_direct(
    bridge: *mut DKStreamBridge,
    current_offset: i64,
    target_chunk: i32,
    offset_in_chunk: i32,
    dst: *mut u8,
    count: i32,
) -> i32 {
    if bridge.is_null() || offset_in_chunk < 0 {
        return 0;
    }
    (*bridge).try_read_partial_or_direct(
        current_offset,
        target_chunk,
        offset_in_chunk as usize,
        dst,
        count,
    )
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_flush_final_attempt(
    bridge: *mut DKStreamBridge,
    attempt_id: u64,
    succeeded: bool,
    out_completed_chunk: *mut i32,
) -> bool {
    let Some(b) = bridge.as_ref() else {
        return false;
    };
    if let Some(idx) = b.flush_final_attempt(attempt_id, succeeded) {
        if !out_completed_chunk.is_null() {
            *out_completed_chunk = idx;
        }
        return true;
    }
    false
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_ingest_partial(
    bridge: *mut DKStreamBridge,
    attempt_id: u64,
    bytes: *const u8,
    len: i32,
    out_completed_chunks: *mut i32,
    max_completed: i32,
) -> i32 {
    if bridge.is_null() || bytes.is_null() || len <= 0 {
        return 0;
    }
    let slice = std::slice::from_raw_parts(bytes, len as usize);
    let mut out_buf = if !out_completed_chunks.is_null() && max_completed > 0 {
        std::slice::from_raw_parts_mut(out_completed_chunks, max_completed as usize)
    } else {
        &mut []
    };
    (*bridge).ingest_partial(attempt_id, slice, &mut out_buf) as i32
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_ingest_direct(
    bridge: *mut DKStreamBridge,
    start_offset: i64,
    bytes: *const u8,
    len: i32,
) {
    if bridge.is_null() || bytes.is_null() || len <= 0 {
        return;
    }
    let slice = std::slice::from_raw_parts(bytes, len as usize);
    (*bridge).ingest_direct_slice(start_offset, slice);
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_clear_direct_slices(bridge: *mut DKStreamBridge) {
    if let Some(b) = bridge.as_ref() {
        b.clear_direct_slices();
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_bridge_release(bridge: *mut DKStreamBridge) {
    if !bridge.is_null() {
        drop(Arc::from_raw(bridge));
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_player_attach_stream_bridge(
    player: *mut DKPlayer,
    bridge: *mut DKStreamBridge,
) {
    if player.is_null() || bridge.is_null() {
        return;
    }
    let Ok(reg) = live_players().lock() else { return };
    if !reg.contains(&(player as usize)) {
        return;
    }
    Arc::increment_strong_count(bridge);
    let arc = Arc::from_raw(bridge);
    (*player).set_stream_bridge(arc);
}

// MARK: - DKDownloadAssembler C ABI

#[no_mangle]
pub unsafe extern "C" fn dk_net_assembler_create(
    store: *mut DKChunkStore,
    start_chunk: i32,
    end_chunk: i32,
) -> *mut DKDownloadAssembler {
    if store.is_null() {
        return std::ptr::null_mut();
    }
    Arc::increment_strong_count(store);
    let store_arc = Arc::from_raw(store);
    Box::into_raw(Box::new(DKDownloadAssembler::new(
        store_arc,
        start_chunk,
        end_chunk,
    )))
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_assembler_update_end(
    asm_ptr: *mut DKDownloadAssembler,
    end_chunk: i32,
) {
    if let Some(a) = asm_ptr.as_mut() {
        a.update_end_chunk(end_chunk);
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_assembler_ingest(
    asm_ptr: *mut DKDownloadAssembler,
    bytes: *const u8,
    len: i32,
    keep_in_l1: bool,
    out_committed_chunks: *mut i32,
    out_committed_bytes: *mut i64,
    out_hit_end: *mut bool,
) {
    let Some(a) = asm_ptr.as_mut() else { return };
    if bytes.is_null() || len <= 0 {
        return;
    }
    let slice = std::slice::from_raw_parts(bytes, len as usize);
    let (chunks, committed_b, hit_end) = a.ingest(slice, keep_in_l1);
    if !out_committed_chunks.is_null() {
        *out_committed_chunks = chunks;
    }
    if !out_committed_bytes.is_null() {
        *out_committed_bytes = committed_b;
    }
    if !out_hit_end.is_null() {
        *out_hit_end = hit_end;
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_assembler_finish(
    asm_ptr: *mut DKDownloadAssembler,
    keep_in_l1: bool,
    out_committed_chunks: *mut i32,
    out_committed_bytes: *mut i64,
) {
    let Some(a) = asm_ptr.as_mut() else { return };
    let (chunks, bytes) = a.finish(keep_in_l1);
    if !out_committed_chunks.is_null() {
        *out_committed_chunks = chunks;
    }
    if !out_committed_bytes.is_null() {
        *out_committed_bytes = bytes;
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_net_assembler_destroy(asm_ptr: *mut DKDownloadAssembler) {
    if !asm_ptr.is_null() {
        drop(Box::from_raw(asm_ptr));
    }
}
