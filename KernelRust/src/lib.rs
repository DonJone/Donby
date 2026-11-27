pub mod abi;
pub mod clock;
pub mod dovi;
pub mod ffi;
pub mod net;
pub mod subtitle;
pub mod vad;

mod audio;
mod c_api;
mod c_api_net;
mod demux;
mod lifecycle;
mod player;
mod tracks;
mod video;

pub use c_api::*;
pub use c_api_net::*;
pub use player::DKPlayer;

use std::ffi::{c_char, c_int, c_void, CString};
use std::ptr;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::{Mutex, OnceLock};

static LOG_CALLBACK: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
static LIVE_PLAYERS: OnceLock<Mutex<Vec<usize>>> = OnceLock::new();

pub(crate) fn live_players() -> &'static Mutex<Vec<usize>> {
    LIVE_PLAYERS.get_or_init(|| Mutex::new(Vec::new()))
}

pub(crate) fn set_log_callback_ptr(ptr_val: *mut c_void) {
    LOG_CALLBACK.store(ptr_val, Ordering::Release);
}

pub(crate) fn emit_log(level: c_int, msg: &str) {
    let raw = LOG_CALLBACK.load(Ordering::Acquire);
    if raw.is_null() {
        return;
    }
    if let Ok(cstr) = CString::new(msg) {
        let cb: unsafe extern "C" fn(c_int, *const c_char) = unsafe { std::mem::transmute(raw) };
        unsafe { cb(level, cstr.as_ptr()) };
    }
}

#[no_mangle]
pub unsafe extern "C" fn dk_rust_forward_ffmpeg_log(level: c_int, message: *const c_char) {
    let raw = LOG_CALLBACK.load(Ordering::Acquire);
    if raw.is_null() || message.is_null() {
        return;
    }
    let cb: unsafe extern "C" fn(c_int, *const c_char) = std::mem::transmute(raw);
    cb(level, message);
}

pub(crate) struct ReaderGuard<'a> {
    pub(crate) player: Option<&'a DKPlayer>,
}

impl<'a> ReaderGuard<'a> {
    pub(crate) unsafe fn acquire(raw: *mut DKPlayer) -> Self {
        if raw.is_null() {
            return Self { player: None };
        }
        let Ok(reg) = live_players().lock() else {
            return Self { player: None };
        };
        if !reg.contains(&(raw as usize)) {
            return Self { player: None };
        }
        let p = &*raw;
        if p.is_closing.load(Ordering::Acquire) || p.abort_requested.load(Ordering::Acquire) {
            return Self { player: None };
        }
        p.in_flight_readers.fetch_add(1, Ordering::AcqRel);
        Self { player: Some(p) }
    }
}

impl Drop for ReaderGuard<'_> {
    fn drop(&mut self) {
        if let Some(p) = self.player {
            p.in_flight_readers.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

pub(crate) fn normalize_path_or_url(in_url: &str) -> String {
    let s = in_url.strip_prefix("file://").unwrap_or(in_url);
    if !s.contains('%') {
        return s.to_owned();
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex_str) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(val) = u8::from_str_radix(hex_str, 16) {
                    out.push(val);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub(crate) fn redact_url_for_log(raw: &str) -> String {
    let base = match raw.find('?') {
        Some(q) => format!("{}?<REDACTED>", &raw[..q]),
        None => raw.to_owned(),
    };
    if let Some(scheme) = base.find("://") {
        let host_start = scheme + 3;
        return match base[host_start..].find('/') {
            Some(rel_slash) => format!("{}<HOST>{}", &base[..host_start], &base[host_start + rel_slash..]),
            None => format!("{}<HOST>", &base[..host_start]),
        };
    }
    base
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_redaction_strips_host_and_query_secrets() {
        assert_eq!(
            redact_url_for_log("https://secret.example.com:8443/emby/videos/123/stream.mkv?api_key=TOPSECRET"),
            "https://<HOST>/emby/videos/123/stream.mkv?<REDACTED>"
        );
        assert_eq!(
            normalize_path_or_url("file:///Users/don/%E6%B5%8B%E8%AF%95.mkv"),
            "/Users/don/测试.mkv"
        );
    }
}
