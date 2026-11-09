//! SessionController.pipeline and ContentView's transcript-tail presentation.
use crate::preferences::UILanguage;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ViewPhase {
    #[default]
    Idle,
    CountingDown {
        remaining: u32,
    },
    EngineStarting,
    Ready,
    Recording,
    Paused,
    Flushing,
    Processing,
    Done,
    Error {
        message: String,
    },
}
impl ViewPhase {
    pub fn is_busy(&self) -> bool {
        !matches!(self, Self::Idle | Self::Done | Self::Error { .. })
    }
    pub fn is_recording(&self) -> bool {
        matches!(self, Self::Recording | Self::Paused)
    }
}
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Signals {
    pub phase: ViewPhase,
    pub language_corrections_pending: usize,
    pub reconciling: bool,
    pub chunks_done: i64,
    pub chunks_total: i64,
    pub translate_backlog: usize,
    pub translate_queued_lines: usize,
    pub translate_queue_depth: usize,
    pub mic_silent: bool,
    pub segments_in_flight: usize,
    pub backfill_remaining: usize,
    pub capture_ended_reason: Option<String>,
    pub coverage_gaps: Vec<f64>,
    pub hang_recoveries: usize,
}
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Pipeline {
    #[default]
    Idle,
    Listening,
    Transcribing,
    FileTranscribing {
        percent: Option<i64>,
    },
    Diarizing,
    Correcting {
        count: usize,
    },
    Translating {
        count: usize,
    },
    TranslatingBacklogged {
        count: usize,
    },
    Completed,
    Backfilling {
        count: usize,
    },
    Error {
        message: String,
    },
}
pub fn pipeline(s: &Signals) -> Pipeline {
    if let ViewPhase::Error { message } = &s.phase {
        return Pipeline::Error {
            message: message.clone(),
        };
    }
    if s.language_corrections_pending > 0 {
        return Pipeline::Correcting {
            count: s.language_corrections_pending,
        };
    }
    if s.reconciling {
        return Pipeline::Diarizing;
    }
    if s.phase == ViewPhase::Processing {
        return Pipeline::FileTranscribing {
            percent: (s.chunks_total > 0)
                .then(|| (s.chunks_done as f64 / s.chunks_total as f64 * 100.0) as i64),
        };
    }
    if s.translate_backlog > 0 {
        return Pipeline::TranslatingBacklogged {
            count: s.translate_queued_lines.max(s.translate_queue_depth.min(1)),
        };
    }
    if s.translate_queue_depth > 0 {
        return Pipeline::Translating {
            count: s.translate_queued_lines.max(1),
        };
    }
    if s.phase == ViewPhase::Recording {
        return if s.mic_silent {
            Pipeline::Idle
        } else if s.segments_in_flight > 0 {
            Pipeline::Transcribing
        } else {
            Pipeline::Listening
        };
    }
    if s.phase == ViewPhase::Done {
        return if s.backfill_remaining > 0 {
            Pipeline::Backfilling {
                count: s.backfill_remaining,
            }
        } else {
            Pipeline::Completed
        };
    }
    Pipeline::Idle
}
fn localized(language: UILanguage, ko: &str, en: &str, ja: Option<&str>) -> String {
    match language {
        UILanguage::Ko => ko,
        UILanguage::En => en,
        UILanguage::Ja => ja.unwrap_or(en),
    }
    .into()
}
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Presentation {
    pub pipeline: Pipeline,
    pub warning: Option<String>,
    pub activity: Option<String>,
    pub gap_times: Vec<String>,
}
pub fn presentation(s: &Signals, language: UILanguage) -> Presentation {
    let l = |ko: &str, en: &str, ja: Option<&str>| localized(language, ko, en, ja);
    let pipeline = pipeline(s);
    let activity = match &pipeline {
        Pipeline::Diarizing => Some(l(
            "AI가 화자·언어를 검토하는 중",
            "AI is reviewing speakers & language",
            None,
        )),
        Pipeline::Correcting { count: n } => Some(l(
            &format!("언어 교정 재전사 {n}줄 남음"),
            &format!("Language re-transcribe · {n} lines left"),
            Some(&format!("言語修正の再文字起こし · 残り{n}行")),
        )),
        Pipeline::FileTranscribing { percent: Some(n) } => Some(l(
            &format!("파일 전사 중 · {n}%"),
            &format!("Transcribing file · {n}%"),
            Some(&format!("ファイル文字起こし中 · {n}%")),
        )),
        Pipeline::FileTranscribing { percent: None } => {
            Some(l("파일 전사 중", "Transcribing file", None))
        }
        Pipeline::Translating { count: n } => Some(l(
            &format!("번역 중 · {n}줄 대기"),
            &format!("Translating · {n} queued"),
            Some(&format!("翻訳中 · {n}行待機")),
        )),
        Pipeline::TranslatingBacklogged { .. } => Some(l(
            "말이 빨라 번역이 밀렸어요 · 정지 후 자동으로 채워요",
            "Translation is behind fast speech · fills in after you stop",
            None,
        )),
        Pipeline::Transcribing => Some(l("전사 중", "Transcribing", None)),
        Pipeline::Listening => Some(l("듣는 중", "Listening", None)),
        Pipeline::Backfilling { count: n } => Some(l(
            &format!("번역 채우는 중 · {n}줄 남음"),
            &format!("Filling in translations · {n} left"),
            Some(&format!("翻訳を補完中 · 残り{n}行")),
        )),
        Pipeline::Idle | Pipeline::Completed | Pipeline::Error { .. } => None,
    };
    let (warning, gap_times) = if s.mic_silent {
        (
            Some(l(
                "소리가 감지되지 않아요 — 마이크를 확인해주세요",
                "No sound detected — check your microphone",
                None,
            )),
            vec![],
        )
    } else {
        let mut parts = s.capture_ended_reason.iter().cloned().collect::<Vec<_>>();
        let n = s.coverage_gaps.len();
        if n > 0 {
            parts.push(l(
                &format!("누락 의심 {n}구간"),
                &format!("{n} suspected gaps"),
                Some(&format!("欠落の疑い {n}区間")),
            ));
        }
        let n = s.hang_recoveries;
        if n > 0 {
            parts.push(l(
                &format!("복구 {n}회"),
                &format!("{n} recoveries"),
                Some(&format!("復旧 {n}回")),
            ));
        }
        let mut gaps = s.coverage_gaps.clone();
        gaps.sort_by(f64::total_cmp);
        let times = gaps
            .into_iter()
            .map(|secs| {
                let s = secs as i64;
                format!("{}:{:02}", s / 60, s % 60)
            })
            .collect();
        ((!parts.is_empty()).then(|| parts.join(" · ")), times)
    };
    Presentation {
        pipeline,
        warning,
        activity,
        gap_times,
    }
}

/// Clock and scheduling belong to the native owner. This is the original 3s
/// polling decision with a strict >15s silence threshold and paused-time reset.
#[derive(Debug)]
pub struct SilenceWatch {
    last_audible: f64,
    pub silent: bool,
}
impl SilenceWatch {
    pub fn new(now: f64) -> Self {
        Self {
            last_audible: now,
            silent: false,
        }
    }
    pub fn level(&mut self, level: f32, now: f64) {
        if level > 0.02 {
            self.last_audible = now;
        }
    }
    pub fn tick(&mut self, phase: &ViewPhase, now: f64) -> bool {
        match phase {
            ViewPhase::Recording => self.silent = now - self.last_audible > 15.0,
            ViewPhase::Paused => {
                self.last_audible = now;
                self.silent = false;
            }
            _ => {
                self.silent = false;
                return false;
            }
        }
        true
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn silence_uses_raw_level_strict_boundaries_and_paused_poll_resets_time() {
        let mut watch = SilenceWatch::new(0.0);
        assert!(watch.tick(&ViewPhase::Recording, 15.0));
        assert!(!watch.silent);
        watch.level(0.02, 15.5);
        watch.tick(&ViewPhase::Recording, 18.0);
        assert!(watch.silent);
        watch.level(0.021, 18.0);
        assert!(watch.silent); // publication waits for the poll
        watch.tick(&ViewPhase::Recording, 21.0);
        assert!(!watch.silent);
        watch.tick(&ViewPhase::Paused, 60.0);
        watch.tick(&ViewPhase::Recording, 75.0);
        assert!(!watch.silent);
        watch.tick(&ViewPhase::Recording, 78.0);
        assert!(watch.silent);
        assert!(!watch.tick(&ViewPhase::Flushing, 79.0));
        assert!(!watch.silent);
    }
}
