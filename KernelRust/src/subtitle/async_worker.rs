use crate::abi::DKSubtitleRgbaCallback;
use crate::player::DKPlayer;
use std::ffi::c_void;
use std::ptr;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread::{self, JoinHandle};

struct SubRequest {
    pts: f64,
    canvas_w: i32,
    canvas_h: i32,
    has_request: bool,
    dirty: bool,
    shutdown: bool,
}

struct ReadySubtitleFrame {
    has_sub: bool,
    rgba: Vec<u8>,
    w: i32,
    h: i32,
    serial: u64,
    bounds: Option<(i32, i32, i32)>,
}

struct SubWorkerHandle {
    req_mtx: Mutex<SubRequest>,
    req_cv: Condvar,
    ready_mtx: Mutex<ReadySubtitleFrame>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

static SUB_WORKERS: OnceLock<Mutex<Vec<(usize, Arc<SubWorkerHandle>)>>> = OnceLock::new();

fn registry() -> &'static Mutex<Vec<(usize, Arc<SubWorkerHandle>)>> {
    SUB_WORKERS.get_or_init(|| Mutex::new(Vec::new()))
}

fn find_handle(player: *mut DKPlayer) -> Option<Arc<SubWorkerHandle>> {
    let key = player as usize;
    let reg = registry().lock().unwrap_or_else(|e| e.into_inner());
    reg.iter().find(|(k, _)| *k == key).map(|(_, h)| Arc::clone(h))
}

fn get_or_spawn(player: *mut DKPlayer) -> Arc<SubWorkerHandle> {
    let key = player as usize;
    let mut reg = registry().lock().unwrap_or_else(|e| e.into_inner());
    if let Some((_, h)) = reg.iter().find(|(k, _)| *k == key) {
        return Arc::clone(h);
    }
    let handle = Arc::new(SubWorkerHandle {
        req_mtx: Mutex::new(SubRequest {
            pts: 0.0,
            canvas_w: 0,
            canvas_h: 0,
            has_request: false,
            dirty: false,
            shutdown: false,
        }),
        req_cv: Condvar::new(),
        ready_mtx: Mutex::new(ReadySubtitleFrame {
            has_sub: false,
            rgba: Vec::new(),
            w: 0,
            h: 0,
            serial: 0,
            bounds: None,
        }),
        thread: Mutex::new(None),
    });
    let worker_handle = Arc::clone(&handle);
    let spawned = thread::Builder::new()
        .name("donby-sub-worker".to_string())
        .spawn(move || worker_loop(key, worker_handle))
        .ok();
    if let Ok(mut th) = handle.thread.lock() {
        *th = spawned;
    }
    reg.push((key, Arc::clone(&handle)));
    handle
}

fn worker_loop(p_addr: usize, handle: Arc<SubWorkerHandle>) {
    let p = unsafe { &*(p_addr as *const DKPlayer) };
    if !p.is_closing.load(Ordering::Acquire) && !p.abort_requested.load(Ordering::Acquire) {
        if let Ok(mut sub) = p.sub_mtx.lock() {
            sub.prewarm_cjk_font();
        }
    }

    loop {
        let (pts, cw, ch, has_req) = {
            let mut req = handle.req_mtx.lock().unwrap_or_else(|e| e.into_inner());
            while !req.dirty && !req.shutdown {
                req = handle.req_cv.wait(req).unwrap_or_else(|e| e.into_inner());
            }
            if req.shutdown {
                break;
            }
            req.dirty = false;
            (req.pts, req.canvas_w, req.canvas_h, req.has_request)
        };
        if !has_req || cw <= 0 || ch <= 0 {
            continue;
        }
        if p.is_closing.load(Ordering::Acquire) || p.abort_requested.load(Ordering::Acquire) {
            break;
        }
        if let Ok(mut sub) = p.sub_mtx.lock() {
            let (has_sub, rgba_ptr, w, h, serial) = sub.update_subtitle_rgba(pts, cw, ch);
            let bounds = if has_sub { sub.get_vertical_bounds() } else { None };
            let mut ready = handle.ready_mtx.lock().unwrap_or_else(|e| e.into_inner());
            if serial != ready.serial {
                ready.has_sub = has_sub;
                ready.w = if has_sub { w } else { 0 };
                ready.h = if has_sub { h } else { 0 };
                ready.bounds = bounds;
                if has_sub && !rgba_ptr.is_null() && w > 0 && h > 0 {
                    let needed = (w as usize) * (h as usize) * 4;
                    if ready.rgba.len() != needed {
                        ready.rgba.resize(needed, 0);
                    }
                    let src = unsafe { std::slice::from_raw_parts(rgba_ptr, needed) };
                    ready.rgba.copy_from_slice(src);
                }
                ready.serial = serial;
            } else {
                ready.bounds = bounds;
            }
        }
    }
}

pub(crate) fn start_and_prewarm(player: *mut DKPlayer) {
    if !player.is_null() {
        let _ = get_or_spawn(player);
    }
}

pub(crate) fn nudge(player: *mut DKPlayer) {
    let Some(handle) = find_handle(player) else { return };
    let mut req = handle.req_mtx.lock().unwrap_or_else(|e| e.into_inner());
    if !req.shutdown && req.has_request {
        req.dirty = true;
        handle.req_cv.notify_one();
    }
}

pub(crate) unsafe fn sync_subtitle_rgba(
    player: *mut DKPlayer,
    pts: f64,
    canvas_w: i32,
    canvas_h: i32,
    last_serial: u64,
    cb: DKSubtitleRgbaCallback,
    context: *mut c_void,
) {
    let Some(cb_fn) = cb else { return };
    let handle = get_or_spawn(player);
    {
        let mut req = handle.req_mtx.lock().unwrap_or_else(|e| e.into_inner());
        if !req.shutdown {
            req.pts = pts;
            req.canvas_w = canvas_w;
            req.canvas_h = canvas_h;
            req.has_request = true;
            req.dirty = true;
            handle.req_cv.notify_one();
        }
    }
    let ready = handle.ready_mtx.lock().unwrap_or_else(|e| e.into_inner());
    if ready.serial != last_serial {
        if ready.has_sub && !ready.rgba.is_empty() && ready.w > 0 && ready.h > 0 {
            cb_fn(ready.rgba.as_ptr(), ready.w, ready.h, ready.serial, context);
        } else {
            cb_fn(ptr::null(), 0, 0, ready.serial, context);
        }
    }
}

pub(crate) fn get_vertical_bounds(player: *mut DKPlayer) -> Option<Option<(i32, i32, i32)>> {
    let handle = find_handle(player)?;
    let ready = handle.ready_mtx.lock().unwrap_or_else(|e| e.into_inner());
    Some(ready.bounds)
}

pub(crate) fn shutdown(player: *mut DKPlayer) {
    let key = player as usize;
    let handle = {
        let mut reg = registry().lock().unwrap_or_else(|e| e.into_inner());
        reg.iter()
            .position(|(k, _)| *k == key)
            .map(|idx| reg.swap_remove(idx).1)
    };
    let Some(handle) = handle else { return };
    {
        let mut req = handle.req_mtx.lock().unwrap_or_else(|e| e.into_inner());
        req.shutdown = true;
        handle.req_cv.notify_all();
    }
    if let Ok(mut th) = handle.thread.lock() {
        if let Some(j) = th.take() {
            let _ = j.join();
        }
    };
}
