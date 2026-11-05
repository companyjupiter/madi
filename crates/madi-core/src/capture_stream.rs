//! Shipping AudioCapture's post-converter path. Inputs are mono PCM16 at 16 kHz.
//! The caller serializes input and controls; this type performs no device or IO work.
use crate::{segmenter, setup::AudioSource};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

pub const SAMPLE_RATE: u32 = 16_000;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Configuration {
    pub source: AudioSource,
    pub segment_seconds: f64,
    pub overlap_seconds: f64,
    pub first_segment_seconds: f64,
    pub preview_seconds: f64,
    pub preview_enabled: bool,
}
impl Default for Configuration {
    fn default() -> Self {
        Self {
            source: AudioSource::Mic,
            segment_seconds: 10.0,
            overlap_seconds: 3.0,
            first_segment_seconds: 1.5,
            preview_seconds: 1.0,
            preview_enabled: false,
        }
    }
}
impl Configuration {
    /// SessionController.start() derives the windows after multi-target policy.
    pub fn from_settings(
        settings: &crate::settings::Settings,
        setup: &crate::setup::SetupState,
    ) -> Self {
        let window = settings.effective_window_seconds(setup);
        Self {
            source: setup.audio_source,
            segment_seconds: window,
            first_segment_seconds: window.min(1.5),
            overlap_seconds: (window * 0.3).clamp(1.0, 3.0),
            preview_enabled: settings.live_preview_enabled,
            ..Self::default()
        }
    }
    fn window(&self) -> segmenter::Configuration {
        segmenter::Configuration {
            sample_rate: SAMPLE_RATE,
            segment_seconds: self.segment_seconds,
            overlap_seconds: self.overlap_seconds,
            first_segment_seconds: self.first_segment_seconds,
            ..segmenter::Configuration::default()
        }
    }
    fn validate(&self) -> Result<(), &'static str> {
        self.window().validate()?;
        let interval = self.preview_seconds * f64::from(SAMPLE_RATE);
        if !interval.is_finite() || interval < 1.0 || interval >= i64::MAX as f64 {
            return Err("invalid preview interval");
        }
        Ok(())
    }
}

#[derive(Debug, PartialEq)]
pub enum Output {
    Level(f32),
    Segment {
        index: usize,
        segment: segmenter::Segment,
    },
    Preview {
        slot: u8,
        offset: f64,
        samples: Vec<i16>,
    },
}

pub struct CaptureStream {
    configuration: Configuration,
    segmenter: segmenter::Segmenter,
    mic_pending: VecDeque<i16>,
    system_pending: VecDeque<i16>,
    accepts_samples: bool,
    paused: bool,
    segment_index: usize,
    samples_since_preview: usize,
    preview_slot: u8,
}
impl CaptureStream {
    pub fn new(configuration: Configuration) -> Result<Self, &'static str> {
        configuration.validate()?;
        Ok(Self {
            segmenter: segmenter::Segmenter::new(configuration.window())?,
            configuration,
            mic_pending: VecDeque::new(),
            system_pending: VecDeque::new(),
            accepts_samples: false,
            paused: false,
            segment_index: 0,
            samples_since_preview: 0,
            preview_slot: 0,
        })
    }
    /// Call before starting native inputs: mic PCM may precede system readiness.
    /// A fresh instance per session matches SessionController.resetSessionData.
    pub fn start(&mut self) {
        self.reset_segmenter();
        self.mic_pending.clear();
        self.system_pending.clear();
        self.accepts_samples = true;
    }
    pub fn configure(&mut self, configuration: Configuration) -> Result<(), &'static str> {
        configuration.validate()?;
        self.segmenter.configure(configuration.window())?;
        self.configuration = configuration;
        Ok(())
    }
    pub fn pause(&mut self) {
        self.paused = true;
    }
    pub fn resume(&mut self) {
        self.paused = false;
    }
    pub fn ingest(&mut self, samples: &[i16], microphone: bool) -> Vec<Output> {
        let mut output = Vec::new();
        if !self.accepts_samples {
            return output;
        }
        if self.configuration.source != AudioSource::Both {
            self.consume(samples, rms_level(samples), &mut output);
            return output;
        }
        if self.paused {
            self.mic_pending.clear();
            self.system_pending.clear();
            return vec![Output::Level(0.0)];
        }
        if microphone {
            self.mic_pending.extend(samples);
        } else {
            self.system_pending.extend(samples);
        }
        let stall = SAMPLE_RATE as usize * 2;
        let solo = if self.mic_pending.len() > stall && self.system_pending.is_empty() {
            Some(self.mic_pending.drain(..).collect::<Vec<_>>())
        } else if self.system_pending.len() > stall && self.mic_pending.is_empty() {
            Some(self.system_pending.drain(..).collect::<Vec<_>>())
        } else {
            None
        };
        if let Some(samples) = solo {
            self.consume(&samples, rms_level(&samples), &mut output);
            return output;
        }
        let count = self.mic_pending.len().min(self.system_pending.len());
        if count > 0 {
            let mixed: Vec<_> = self
                .mic_pending
                .drain(..count)
                .zip(self.system_pending.drain(..count))
                .map(|(mic, system)| {
                    (i32::from(mic) + i32::from(system)).clamp(-32768, 32767) as i16
                })
                .collect();
            self.consume(&mixed, rms_level(&mixed), &mut output);
        }
        output
    }
    /// Invoke only after native input has stopped and accepted PCM is drained.
    /// Tail outputs must reach the engine before the lifecycle sends FLUSH.
    pub fn stop(&mut self) -> Vec<Output> {
        self.paused = false;
        self.accepts_samples = false;
        let mut output = Vec::new();
        if self.configuration.source == AudioSource::Both {
            let tail: Vec<_> = if self.mic_pending.len() >= self.system_pending.len() {
                self.mic_pending.drain(..).collect()
            } else {
                self.system_pending.drain(..).collect()
            };
            if !tail.is_empty() {
                self.consume(&tail, 0.0, &mut output);
            }
            self.mic_pending.clear();
            self.system_pending.clear();
        }
        if let Some(segment) = self.segmenter.flush() {
            self.emit_segment(segment, &mut output);
        }
        output
    }
    /// Failed/cancelled admission produces no tail and rejects late callbacks.
    pub fn abort(&mut self) -> Vec<Output> {
        self.paused = false;
        self.accepts_samples = false;
        self.mic_pending.clear();
        self.system_pending.clear();
        self.reset_segmenter();
        self.samples_since_preview = 0;
        vec![Output::Level(0.0)]
    }
    fn reset_segmenter(&mut self) {
        self.segmenter = segmenter::Segmenter::new(self.configuration.window())
            .expect("validated configuration");
        self.segment_index = 0;
    }
    fn emit_segment(&mut self, segment: segmenter::Segment, output: &mut Vec<Output>) {
        output.push(Output::Segment {
            index: self.segment_index,
            segment,
        });
        self.segment_index += 1;
    }
    fn consume(&mut self, samples: &[i16], level: f32, output: &mut Vec<Output>) {
        if self.paused {
            output.push(Output::Level(0.0));
            return;
        }
        output.push(Output::Level(level));
        for segment in self.segmenter.push(samples) {
            self.emit_segment(segment, output);
            self.samples_since_preview = 0;
        }
        if self.configuration.preview_enabled {
            // The source counts this WHOLE input after a cut, not only the remainder.
            self.samples_since_preview += samples.len();
            let interval = (self.configuration.preview_seconds * f64::from(SAMPLE_RATE)) as usize;
            if self.samples_since_preview >= interval
                && self.segmenter.pending_count() > interval / 2
            {
                self.samples_since_preview = 0;
                self.preview_slot = (self.preview_slot + 1) % 3;
                let (offset, samples) = self.segmenter.preview_window();
                output.push(Output::Preview {
                    slot: self.preview_slot,
                    offset,
                    samples,
                });
            }
        }
    }
}

pub fn rms_level(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let mut sum = 0.0_f64;
    for sample in samples {
        let value = f64::from(*sample) / 32768.0;
        sum += value * value;
    }
    (1.0_f64.min((sum / samples.len() as f64).sqrt() * 3.0)) as f32
}

#[cfg(test)]
mod tests {
    use super::*;
    fn mixed() -> CaptureStream {
        let mut stream = CaptureStream::new(Configuration {
            source: AudioSource::Both,
            ..Configuration::default()
        })
        .unwrap();
        stream.start();
        stream
    }
    #[test]
    fn mixing_saturates_and_final_tail_preserves_unmatched_source() {
        let mut stream = mixed();
        assert!(stream.ingest(&[32767, -32768, 100, 7], true).is_empty());
        stream.ingest(&[1, -1, -50], false);
        let output = stream.stop();
        let Output::Segment { segment, .. } = output.last().unwrap() else {
            panic!()
        };
        assert_eq!(segment.samples, [32767, -32768, 50, 7]);
        assert_eq!(segment.offset, 0.0);
        assert!(stream.stop().is_empty());
        assert!(stream.ingest(&[99], true).is_empty());
    }
    #[test]
    fn solo_stall_is_strictly_greater_than_two_seconds() {
        let mut stream = mixed();
        assert!(stream.ingest(&[200; 32_000], false).is_empty());
        assert!(!stream.ingest(&[200], false).is_empty());
        assert!(stream.system_pending.is_empty());
    }
    #[test]
    fn paused_delivery_drops_both_queues_but_pause_alone_keeps_tail() {
        let mut stream = mixed();
        stream.ingest(&[1, 2], true);
        stream.pause();
        let tail = stream.stop();
        assert!(matches!(&tail[1], Output::Segment { segment, .. } if segment.samples == [1, 2]));
        stream.start();
        stream.ingest(&[3], false);
        stream.pause();
        assert_eq!(stream.ingest(&[4], true), vec![Output::Level(0.0)]);
        stream.resume();
        assert!(stream.stop().is_empty());
    }
    #[test]
    fn abort_has_no_tail_and_rejects_late_pcm() {
        let mut stream = mixed();
        stream.ingest(&[1; 100], true);
        assert_eq!(stream.abort(), vec![Output::Level(0.0)]);
        assert!(stream.ingest(&[1; 100], false).is_empty());
        assert!(stream.stop().is_empty());
    }
    #[test]
    fn whole_push_counts_toward_preview_after_cut_and_rotates_slots() {
        let mut stream = CaptureStream::new(Configuration {
            preview_enabled: true,
            ..Configuration::default()
        })
        .unwrap();
        stream.start();
        let first = stream.ingest(&[3000; 32_001], true);
        assert!(
            matches!(first.last(), Some(Output::Preview { slot: 1, samples, .. }) if samples.len() == 32_001)
        );
        let slots: Vec<_> = (0..3)
            .flat_map(|_| stream.ingest(&[3000; 16_000], true))
            .filter_map(|out| {
                if let Output::Preview { slot, .. } = out {
                    Some(slot)
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(slots, [2, 0, 1]);
    }
}
