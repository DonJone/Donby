use crate::abi::DKPlayerState;
use crate::ffi::{dk_shim_aq_pause, dk_shim_aq_start_only};
use crate::player::DKPlayer;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread::{self, JoinHandle};

#[derive(Copy, Clone, PartialEq, Eq)]
enum AqOp {
    None,
    Pause,
    Resume,
}

struct AudioControlInner {
    pending_op: AqOp,
    busy: bool,
    shutdown: bool,
}

struct AudioControlHandle {
    mtx: Mutex<AudioControlInner>,
    cv: Condvar,
    thread: Mutex<Option<JoinHandle<()>>>,
}

static AQ_CONTROLS: OnceLock<Mutex<Vec<(usize, Arc<AudioControlHandle>)>>> = OnceLock::new();

fn registry() -> &'static Mutex<Vec<(usize, Arc<AudioControlHandle>)>> {
    AQ_CONTROLS.get_or_init(|| Mutex::new(Vec::new()))
}

fn get_or_spawn(player: &DKPlayer) -> Arc<AudioControlHandle> {
    let key = player as *const DKPlayer as usize;
    let mut reg = registry().lock().unwrap_or_else(|e| e.into_inner());
    if let Some((_, h)) = reg.iter().find(|(k, _)| *k == key) {
        return Arc::clone(h);
    }
    let handle = Arc::new(AudioControlHandle {
        mtx: Mutex::new(AudioControlInner {
            pending_op: AqOp::None,
            busy: false,
            shutdown: false,
        }),
        cv: Condvar::new(),
        thread: Mutex::new(None),
    });
    let worker_handle = Arc::clone(&handle);
    let spawned = thread::Builder::new()
        .name("donby-aq-ctrl".to_string())
        .spawn(move || worker_loop(key, worker_handle))
        .ok();
    if let Ok(mut th) = handle.thread.lock() {
        *th = spawned;
    }
    reg.push((key, Arc::clone(&handle)));
    handle
}

fn find_handle(player: &DKPlayer) -> Option<Arc<AudioControlHandle>> {
    let key = player as *const DKPlayer as usize;
    let reg = registry().lock().unwrap_or_else(|e| e.into_inner());
    reg.iter().find(|(k, _)| *k == key).map(|(_, h)| Arc::clone(h))
}

fn worker_loop(p_addr: usize, handle: Arc<AudioControlHandle>) {
    let p = unsafe { &*(p_addr as *const DKPlayer) };
    loop {
        let op = {
            let mut inner = handle.mtx.lock().unwrap_or_else(|e| e.into_inner());
            while matches!(inner.pending_op, AqOp::None) && !inner.shutdown {
                inner = handle.cv.wait(inner).unwrap_or_else(|e| e.into_inner());
            }
            if inner.shutdown {
                break;
            }
            let taken = std::mem::replace(&mut inner.pending_op, AqOp::None);
            inner.busy = true;
            taken
        };

        while p.audio_queue_starting.load(Ordering::Acquire) {
            thread::yield_now();
        }
        if !p.abort_requested.load(Ordering::Acquire)
            && !p.is_closing.load(Ordering::Acquire)
            && p.audio_queue_started.load(Ordering::Acquire)
        {
            let aq = p.audio_queue_ptr.load(Ordering::Acquire);
            if !aq.is_null() {
                match op {
                    AqOp::Pause => {
                        if p.get_state() == DKPlayerState::Paused {
                            unsafe { dk_shim_aq_pause(aq) };
                        }
                    }
                    AqOp::Resume => {
                        if p.get_state() == DKPlayerState::Playing && !p.is_seeking() {
                            let _ = unsafe { dk_shim_aq_start_only(aq) };
                        }
                    }
                    AqOp::None => {}
                }
            }
        }

        let mut inner = handle.mtx.lock().unwrap_or_else(|e| e.into_inner());
        inner.busy = false;
        handle.cv.notify_all();
    }
}

pub(crate) fn enqueue_pause(player: &DKPlayer) {
    let handle = get_or_spawn(player);
    let mut inner = handle.mtx.lock().unwrap_or_else(|e| e.into_inner());
    if !inner.shutdown {
        inner.pending_op = AqOp::Pause;
        handle.cv.notify_one();
    }
}

pub(crate) fn enqueue_resume(player: &DKPlayer) {
    let handle = get_or_spawn(player);
    let mut inner = handle.mtx.lock().unwrap_or_else(|e| e.into_inner());
    if !inner.shutdown {
        inner.pending_op = AqOp::Resume;
        handle.cv.notify_one();
    }
}

pub(crate) fn barrier(player: &DKPlayer) {
    let Some(handle) = find_handle(player) else { return };
    let mut inner = handle.mtx.lock().unwrap_or_else(|e| e.into_inner());
    inner.pending_op = AqOp::None;
    while inner.busy {
        inner = handle.cv.wait(inner).unwrap_or_else(|e| e.into_inner());
    }
}

pub(crate) fn shutdown(player: &DKPlayer) {
    let key = player as *const DKPlayer as usize;
    let handle = {
        let mut reg = registry().lock().unwrap_or_else(|e| e.into_inner());
        reg.iter()
            .position(|(k, _)| *k == key)
            .map(|idx| reg.swap_remove(idx).1)
    };
    let Some(handle) = handle else { return };
    {
        let mut inner = handle.mtx.lock().unwrap_or_else(|e| e.into_inner());
        inner.pending_op = AqOp::None;
        inner.shutdown = true;
        handle.cv.notify_all();
        while inner.busy {
            inner = handle.cv.wait(inner).unwrap_or_else(|e| e.into_inner());
        }
    }
    if let Ok(mut th) = handle.thread.lock() {
        if let Some(j) = th.take() {
            let _ = j.join();
        }
    };
}
