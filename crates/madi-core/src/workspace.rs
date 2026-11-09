//! Saved-meeting rollup. The native calendar supplies whole weeks ago so local
//! week starts and daylight-saving transitions are not approximated as seconds.
use crate::transcript::Line;
use serde::Serialize;
use std::collections::BTreeSet;
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Stats {
    pub meeting_count: usize,
    pub total_seconds: f64,
    pub total_words: usize,
    pub speaker_sum: usize,
    pub this_week_count: usize,
    pub weekly_trend: [usize; 6],
    pub avg_seconds: f64,
    pub avg_speakers: f64,
}
impl Stats {
    pub fn add(&mut self, lines: &[Line], weeks_ago: i64) {
        self.meeting_count += 1;
        self.total_seconds += lines.last().map_or(0.0, |line| line.end.max(0.0));
        self.total_words += lines.iter().map(|line| line.words.len()).sum::<usize>();
        self.speaker_sum += lines
            .iter()
            .map(|line| line.speaker)
            .filter(|id| *id >= 0 && *id != 255)
            .collect::<BTreeSet<_>>()
            .len();
        if weeks_ago == 0 {
            self.this_week_count += 1;
        }
        if (0..6).contains(&weeks_ago) {
            self.weekly_trend[5 - weeks_ago as usize] += 1;
        }
        self.avg_seconds = self.total_seconds / self.meeting_count as f64;
        self.avg_speakers = self.speaker_sum as f64 / self.meeting_count as f64;
    }
}
pub fn is_summary_stem(stem: &str) -> bool {
    stem.nfc().collect::<String>().ends_with(" 요약")
}
