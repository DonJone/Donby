use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::time::Instant;

static EPOCH: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

#[inline]
pub fn steady_now_ns() -> i64 {
    let base = EPOCH.get_or_init(Instant::now);
    base.elapsed().as_nanos() as i64
}

#[inline]
pub fn elapsed_since_ns(start_ns: i64) -> f64 {
    if start_ns <= 0 {
        return 0.0;
    }
    let diff = steady_now_ns() - start_ns;
    if diff > 0 {
        (diff as f64) * 1e-9
    } else {
        0.0
    }
}

#[inline]
pub fn load_f64(atom: &AtomicU64) -> f64 {
    f64::from_bits(atom.load(Ordering::Acquire))
}

#[inline]
pub fn store_f64(atom: &AtomicU64, val: f64) {
    atom.store(val.to_bits(), Ordering::Release);
}

/// Lock-free master A/V clock state shared between AudioQueue, CVDisplayLink, and demux/seek threads.
pub struct ClockState {
    pub current_pos_bits: AtomicU64,
    pub audio_clock_base_pts_bits: AtomicU64,
    pub audio_clock_base_sample_time: AtomicI64,
    pub audio_underrun_samples: AtomicI64,
    pub audio_consecutive_underrun_samples: AtomicI64,
    pub audio_clock_calibrated: AtomicBool,
    pub fallback_audio_clock_bits: AtomicU64,
    pub fallback_clock_ns: AtomicI64,
    pub ext_clock_base_pts_bits: AtomicU64,
    pub ext_clock_start_ns: AtomicI64,
}

impl Default for ClockState {
    fn default() -> Self {
        Self {
            current_pos_bits: AtomicU64::new(0.0f64.to_bits()),
            audio_clock_base_pts_bits: AtomicU64::new((-1.0f64).to_bits()),
            audio_clock_base_sample_time: AtomicI64::new(0),
            audio_underrun_samples: AtomicI64::new(0),
            audio_consecutive_underrun_samples: AtomicI64::new(0),
            audio_clock_calibrated: AtomicBool::new(false),
            fallback_audio_clock_bits: AtomicU64::new(0.0f64.to_bits()),
            fallback_clock_ns: AtomicI64::new(0),
            ext_clock_base_pts_bits: AtomicU64::new(0.0f64.to_bits()),
            ext_clock_start_ns: AtomicI64::new(0),
        }
    }
}

impl ClockState {
    pub fn reset_to(&self, pts: f64) {
        let now = steady_now_ns();
        store_f64(&self.current_pos_bits, pts);
        store_f64(&self.audio_clock_base_pts_bits, pts);
        store_f64(&self.fallback_audio_clock_bits, pts);
        store_f64(&self.ext_clock_base_pts_bits, pts);
        self.audio_clock_base_sample_time.store(0, Ordering::Release);
        self.audio_underrun_samples.store(0, Ordering::Release);
        self.audio_consecutive_underrun_samples.store(0, Ordering::Release);
        self.audio_clock_calibrated.store(false, Ordering::Release);
        self.fallback_clock_ns.store(now, Ordering::Release);
        self.ext_clock_start_ns.store(now, Ordering::Release);
    }
}

pub struct SpeedTracker {
    last_bytes: i64,
    last_time: Instant,
    instant_mbs: f64,
}

impl Default for SpeedTracker {
    fn default() -> Self {
        Self {
            last_bytes: 0,
            last_time: Instant::now(),
            instant_mbs: 0.0,
        }
    }
}

impl SpeedTracker {
    pub fn reset(&mut self, cur_bytes: i64) {
        self.last_bytes = cur_bytes;
        self.last_time = Instant::now();
        self.instant_mbs = 0.0;
    }

    pub fn sample(&mut self, cur_bytes: i64) -> f64 {
        let now = Instant::now();
        let dt = now.duration_since(self.last_time).as_secs_f64();
        if dt >= 0.25 {
            let delta = (cur_bytes - self.last_bytes).max(0);
            let current_mbs = (delta as f64 / (1024.0 * 1024.0)) / dt;
            let prev = self.instant_mbs;
            self.instant_mbs = if delta > 0 {
                if prev > 0.0 { prev * 0.35 + current_mbs * 0.65 } else { current_mbs }
            } else if dt > 0.6 {
                0.0
            } else {
                prev * 0.25
            };
            self.last_bytes = cur_bytes;
            self.last_time = now;
        }
        self.instant_mbs.max(0.0)
    }
}
