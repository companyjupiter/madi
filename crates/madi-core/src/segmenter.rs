//! PCM windowing from the unchanged macOS Segmenter.swift.
//! This owns samples, not audio devices, files, clocks or engine delivery.
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Configuration {
    pub sample_rate: u32,
    pub segment_seconds: f64,
    pub overlap_seconds: f64,
    pub first_segment_seconds: f64,
    pub early_flush_silence_seconds: f64,
    pub early_flush_min_body_seconds: f64,
}
impl Default for Configuration {
    fn default() -> Self {
        Self {
            sample_rate: 16_000,
            segment_seconds: 10.0,
            overlap_seconds: 3.0,
            first_segment_seconds: 10.0,
            early_flush_silence_seconds: 0.7,
            early_flush_min_body_seconds: 2.5,
        }
    }
}
impl Configuration {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.sample_rate < 100 {
            return Err("sample rate must provide a nonzero 10 ms hop");
        }
        for (seconds, minimum) in [
            (self.segment_seconds, 1),
            (self.first_segment_seconds, 1),
            (self.overlap_seconds, 0),
        ] {
            let count = self.samples(seconds)?;
            if seconds < 0.0 || count < minimum {
                return Err("invalid window or overlap length");
            }
        }
        self.samples(self.early_flush_silence_seconds)?;
        self.samples(self.early_flush_min_body_seconds)?;
        Ok(())
    }
    fn samples(&self, seconds: f64) -> Result<i64, &'static str> {
        let count = seconds * f64::from(self.sample_rate);
        if !count.is_finite() || count < i64::MIN as f64 || count >= i64::MAX as f64 {
            return Err("sample count is not a finite signed integer");
        }
        Ok(count as i64) // Swift Int(Double) truncates toward zero.
    }
    fn count(&self, seconds: f64) -> usize {
        self.samples(seconds).expect("validated configuration") as usize
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Segment {
    pub offset: f64,
    pub samples: Vec<i16>,
    pub body_count: usize,
    pub had_speech: bool,
}
pub struct Segmenter {
    configuration: Configuration,
    pending: VecDeque<i16>,
    overlap_tail: Vec<i16>,
    emitted_body: usize,
    segments_emitted: usize,
    hop_remainder: Vec<i16>,
    trailing_silence: usize,
    window_had_speech: bool,
    window_peak_mean: f64,
}
impl Segmenter {
    pub fn new(configuration: Configuration) -> Result<Self, &'static str> {
        configuration.validate()?;
        Ok(Self {
            configuration,
            pending: VecDeque::new(),
            overlap_tail: Vec::new(),
            emitted_body: 0,
            segments_emitted: 0,
            hop_remainder: Vec::new(),
            trailing_silence: 0,
            window_had_speech: false,
            window_peak_mean: 0.0,
        })
    }
    /// Mirrors changing Swift's tunable properties. The sample rate is fixed
    /// by the instance; creating a new instance resets the audio timeline.
    pub fn configure(&mut self, configuration: Configuration) -> Result<(), &'static str> {
        configuration.validate()?;
        if configuration.sample_rate != self.configuration.sample_rate {
            return Err("sample rate cannot change within a stream");
        }
        self.configuration = configuration;
        Ok(())
    }
    fn next_body_len(&self) -> usize {
        self.configuration.count(if self.segments_emitted == 0 {
            self.configuration.first_segment_seconds
        } else {
            self.configuration.segment_seconds
        })
    }
    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }
    fn offset(&self) -> f64 {
        self.emitted_body.saturating_sub(self.overlap_tail.len()) as f64
            / f64::from(self.configuration.sample_rate)
    }
    pub fn preview_window(&self) -> (f64, Vec<i16>) {
        (
            self.offset(),
            self.overlap_tail
                .iter()
                .chain(self.pending.iter())
                .copied()
                .collect(),
        )
    }
    pub fn push(&mut self, frames: &[i16]) -> Vec<Segment> {
        self.pending.extend(frames);
        // Preserve the source's whole-push analysis BEFORE any cuts. Reordering
        // per-window analysis changes hadSpeech and early-cut behavior.
        self.analyze(frames);
        let mut output = Vec::new();
        while self.pending.len() >= self.next_body_len() {
            output.push(self.cut(self.next_body_len()));
        }
        let config = &self.configuration;
        if output.is_empty()
            && config.early_flush_silence_seconds > 0.0
            && self.window_had_speech
            && self.pending.len() as i64
                >= config
                    .samples(config.early_flush_min_body_seconds)
                    .expect("validated")
            && self.trailing_silence as i64
                >= config
                    .samples(config.early_flush_silence_seconds)
                    .expect("validated")
            && self.trailing_silence < self.pending.len()
        {
            output.push(self.cut(self.pending.len()));
        }
        output
    }
    fn analyze(&mut self, frames: &[i16]) {
        if self.configuration.early_flush_silence_seconds <= 0.0 {
            return;
        }
        let mut buffer = std::mem::take(&mut self.hop_remainder);
        buffer.extend_from_slice(frames);
        let hop = self.configuration.sample_rate as usize / 100;
        let mut chunks = buffer.chunks_exact(hop);
        for chunk in &mut chunks {
            let sum: i64 = chunk.iter().map(|value| i64::from(*value).abs()).sum();
            let mean = sum as f64 / hop as f64;
            if mean > self.window_peak_mean {
                self.window_peak_mean = mean;
            }
            let threshold = 200.0_f64.max(0.15 * self.window_peak_mean);
            if mean < threshold {
                self.trailing_silence += hop;
            } else {
                self.trailing_silence = 0;
                self.window_had_speech = true;
            }
        }
        self.hop_remainder = chunks.remainder().to_vec();
    }
    pub fn flush(&mut self) -> Option<Segment> {
        if self.pending.is_empty() {
            None
        } else {
            Some(self.cut(self.pending.len()))
        }
    }
    fn cut(&mut self, body_len: usize) -> Segment {
        let body: Vec<_> = self.pending.drain(..body_len).collect();
        let segment = Segment {
            offset: self.offset(),
            samples: self
                .overlap_tail
                .iter()
                .chain(body.iter())
                .copied()
                .collect(),
            body_count: body.len(),
            had_speech: self.configuration.early_flush_silence_seconds <= 0.0
                || self.window_had_speech,
        };
        self.emitted_body += body.len();
        let tail_start = body
            .len()
            .saturating_sub(self.configuration.count(self.configuration.overlap_seconds));
        self.overlap_tail = body[tail_start..].to_vec();
        self.segments_emitted += 1;
        // Deliberately do not reset peak, trailing silence or partial hop: the
        // current Swift source keeps them across cuts, despite its broad comment.
        self.window_had_speech = self.trailing_silence < self.pending.len();
        segment
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn short_first_window_overlap_preview_and_final_tail_preserve_pcm() {
        let config = Configuration {
            sample_rate: 100,
            segment_seconds: 0.05,
            first_segment_seconds: 0.03,
            overlap_seconds: 0.02,
            early_flush_silence_seconds: 0.0,
            ..Configuration::default()
        };
        let mut stream = Segmenter::new(config).unwrap();
        let segments = stream.push(&(0..12).collect::<Vec<_>>());
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0].samples, vec![0, 1, 2]);
        assert_eq!(segments[1].samples, vec![1, 2, 3, 4, 5, 6, 7]);
        assert_eq!(
            (
                segments[1].body_count,
                segments[1].offset,
                segments[1].had_speech
            ),
            (5, 0.01, true)
        );
        assert_eq!(stream.preview_window(), (0.06, vec![6, 7, 8, 9, 10, 11]));
        let tail = stream.flush().unwrap();
        assert_eq!(
            (tail.body_count, tail.offset, tail.samples),
            (4, 0.06, vec![6, 7, 8, 9, 10, 11])
        );
        assert!(stream.flush().is_none());
    }
    #[test]
    fn adaptive_peak_is_retained_after_a_short_first_cut() {
        let config = Configuration {
            sample_rate: 100,
            first_segment_seconds: 1.0,
            ..Configuration::default()
        };
        let mut stream = Segmenter::new(config).unwrap();
        assert!(stream.push(&[3000; 100])[0].had_speech);
        assert!(stream.push(&[220; 300]).is_empty());
        assert!(stream.push(&[0; 100]).is_empty());
        assert!(!stream.flush().unwrap().had_speech);
    }
    #[test]
    fn exact_adaptive_floor_counts_as_speech_and_closes_after_silence() {
        let config = Configuration {
            sample_rate: 100,
            first_segment_seconds: 10.0,
            ..Configuration::default()
        };
        let mut stream = Segmenter::new(config).unwrap();
        assert!(stream.push(&[200; 300]).is_empty());
        let closed = stream.push(&[0; 70]);
        assert_eq!(closed.len(), 1);
        assert_eq!(closed[0].body_count, 370);
        assert!(closed[0].had_speech);
    }
    #[test]
    fn invalid_configuration_is_rejected_without_losing_buffered_audio() {
        let mut stream = Segmenter::new(Configuration::default()).unwrap();
        stream.push(&[-32768, 32767]);
        for seconds in [0.0, -1.0, f64::NAN, f64::INFINITY, f64::MAX] {
            let config = Configuration {
                first_segment_seconds: seconds,
                ..Configuration::default()
            };
            assert!(stream.configure(config).is_err());
            assert_eq!(stream.preview_window().1, [-32768, 32767]);
        }
        assert!(
            Segmenter::new(Configuration {
                sample_rate: 99,
                ..Configuration::default()
            })
            .is_err()
        );
        assert!(
            Segmenter::new(Configuration {
                overlap_seconds: -1.0,
                ..Configuration::default()
            })
            .is_err()
        );
    }
}
