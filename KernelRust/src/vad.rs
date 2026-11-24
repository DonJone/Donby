use std::collections::VecDeque;

pub const VAD_SAMPLE_RATE: usize = 16_000;
pub const VAD_RING_MAX_SAMPLES: usize = 60 * VAD_SAMPLE_RATE;

/// Contiguous recent 16kHz mono speech-focused PCM ring for Silero VAD subtitle-audio alignment.
pub struct VadAudioRing {
    samples: VecDeque<f32>,
    end_pts: f64,
    decim_accum: f32,
    decim_count: usize,
}

impl Default for VadAudioRing {
    fn default() -> Self {
        Self {
            samples: VecDeque::with_capacity(VAD_RING_MAX_SAMPLES),
            end_pts: -1.0,
            decim_accum: 0.0,
            decim_count: 0,
        }
    }
}

impl VadAudioRing {
    pub fn clear(&mut self) {
        self.samples.clear();
        self.end_pts = -1.0;
        self.decim_accum = 0.0;
        self.decim_count = 0;
    }

    /// Decimates 48kHz speech-weighted mono PCM (3:1 with remainder carryover) into 16kHz.
    pub fn push_mono_48k(&mut self, mono_48k: &[f32], chunk_start_pts: f64, has_valid_pts: bool) {
        if mono_48k.is_empty() {
            return;
        }
        if has_valid_pts && chunk_start_pts >= 0.0 && self.end_pts >= 0.0 && (chunk_start_pts - self.end_pts).abs() > 0.35 {
            self.samples.clear();
            self.decim_accum = 0.0;
            self.decim_count = 0;
        }
        let mut accum = self.decim_accum;
        let mut cnt = self.decim_count;
        let mut pushed = 0usize;
        for &s in mono_48k {
            accum += s;
            cnt += 1;
            if cnt == 3 {
                if self.samples.len() == VAD_RING_MAX_SAMPLES {
                    self.samples.pop_front();
                }
                self.samples.push_back(accum * (1.0 / 3.0));
                accum = 0.0;
                cnt = 0;
                pushed += 1;
            }
        }
        self.decim_accum = accum;
        self.decim_count = cnt;

        if has_valid_pts && chunk_start_pts >= 0.0 {
            let consumed_48k = mono_48k.len().saturating_sub(cnt);
            self.end_pts = chunk_start_pts + (consumed_48k as f64) / 48_000.0;
        } else if self.end_pts >= 0.0 && pushed > 0 {
            self.end_pts += (pushed as f64) / (VAD_SAMPLE_RATE as f64);
        }
    }

    pub fn available_and_start_pts(&self) -> (usize, f64) {
        let avail = self.samples.len();
        let start_pts = if avail > 0 && self.end_pts >= 0.0 {
            self.end_pts - (avail as f64) / (VAD_SAMPLE_RATE as f64)
        } else {
            0.0
        };
        (avail, start_pts)
    }

    /// Copies up to `out.len()` most-recent 16kHz samples and returns `(copied_count, start_pts)`.
    pub fn copy_recent(&self, out: &mut [f32]) -> (usize, f64) {
        if self.samples.is_empty() || out.is_empty() || self.end_pts < 0.0 {
            return (0, 0.0);
        }
        let n = self.samples.len().min(out.len());
        let skip = self.samples.len() - n;
        for (dst, &src) in out[..n].iter_mut().zip(self.samples.iter().skip(skip)) {
            *dst = src;
        }
        let start_pts = self.end_pts - (n as f64 / VAD_SAMPLE_RATE as f64);
        (n, start_pts)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decimates_48k_mono_to_16k_and_resets_on_discontinuity() {
        let mut ring = VadAudioRing::default();
        let mono = [0.78f32; 6]; // 6 samples @ 48kHz -> 2 samples @ 16kHz
        ring.push_mono_48k(&mono, 10.0, true);
        let mut out = [0.0f32; 8];
        let (n, start_pts) = ring.copy_recent(&mut out);
        assert_eq!(n, 2);
        assert!((out[0] - 0.78).abs() < 1e-5);
        assert!((out[1] - 0.78).abs() < 1e-5);
        assert!((start_pts - 10.0).abs() < 1e-6);

        // Jump > 0.35s clears stale pre-seek samples
        ring.push_mono_48k(&[0.30f32; 3], 25.0, true);
        let (n2, start2) = ring.copy_recent(&mut out);
        assert_eq!(n2, 1);
        assert!((out[0] - 0.30).abs() < 1e-5);
        assert!((start2 - 25.0).abs() < 1e-6);
    }
}
