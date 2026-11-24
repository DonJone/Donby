use std::collections::VecDeque;

pub const VAD_SAMPLE_RATE: usize = 16_000;
pub const VAD_RING_MAX_SAMPLES: usize = 60 * VAD_SAMPLE_RATE;

/// Contiguous recent 16kHz mono speech-focused PCM ring for Silero VAD subtitle-audio alignment.
pub struct VadAudioRing {
    samples: VecDeque<f32>,
    end_pts: f64,
    decim_accum: f32,
    decim_count: u8,
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

    /// Decimates 48kHz interleaved float32 PCM (3:1 with remainder carryover) into 16kHz mono.
    /// On >=3-channel surround (FL, FR, FC, ...), weights center channel 0.78*FC + 0.11*(FL+FR).
    pub fn push_48k_interleaved(&mut self, pcm: &[f32], channels: usize, chunk_end_pts: f64) {
        if channels == 0 || pcm.len() < channels {
            return;
        }
        let frames = pcm.len() / channels;
        let chunk_dur = frames as f64 / 48_000.0;
        if self.end_pts >= 0.0 && (chunk_end_pts - chunk_dur - self.end_pts).abs() > 0.35 {
            self.samples.clear();
            self.decim_accum = 0.0;
            self.decim_count = 0;
        }
        for f in 0..frames {
            let base = f * channels;
            let mono = if channels >= 3 {
                0.78 * pcm[base + 2] + 0.11 * (pcm[base] + pcm[base + 1])
            } else if channels == 2 {
                0.5 * (pcm[base] + pcm[base + 1])
            } else {
                pcm[base]
            };
            self.decim_accum += mono;
            self.decim_count += 1;
            if self.decim_count == 3 {
                if self.samples.len() == VAD_RING_MAX_SAMPLES {
                    self.samples.pop_front();
                }
                self.samples.push_back(self.decim_accum * (1.0 / 3.0));
                self.decim_accum = 0.0;
                self.decim_count = 0;
            }
        }
        self.end_pts = chunk_end_pts;
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
    fn decimates_48k_5_1_to_16k_center_weighted_and_tracks_pts() {
        let mut ring = VadAudioRing::default();
        // 6 frames of 6ch (5.1) @ 48kHz -> 2 samples @ 16kHz; FL=0, FR=0, FC=1.0 -> mono=0.78
        let mut pcm = vec![0.0f32; 6 * 6];
        for f in 0..6 {
            pcm[f * 6 + 2] = 1.0;
        }
        ring.push_48k_interleaved(&pcm, 6, 10.0);
        let mut out = [0.0f32; 8];
        let (n, start_pts) = ring.copy_recent(&mut out);
        assert_eq!(n, 2);
        assert!((out[0] - 0.78).abs() < 1e-5);
        assert!((out[1] - 0.78).abs() < 1e-5);
        assert!((start_pts - (10.0 - 2.0 / 16_000.0)).abs() < 1e-6);
    }
}
