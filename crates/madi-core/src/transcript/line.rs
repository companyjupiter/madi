use super::{Word, whitespace_and_newline};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Line {
    pub id: Uuid,
    pub speaker: i64,
    pub start: f64,
    pub end: f64,
    pub words: Vec<Word>,
    pub overlap_speakers: Vec<i64>,
    pub speaker_margin: f64,
    pub translations: BTreeMap<String, String>,
    pub stale_translations: BTreeMap<String, String>,
    pub edited_translations: BTreeSet<String>,
    pub suppressed_translations: BTreeSet<String>,
    pub edited_text: Option<String>,
}
impl Line {
    pub(super) fn new(word: Word, speaker: i64, margin: f64) -> Self {
        Self {
            id: word.id,
            speaker,
            start: word.t0,
            end: word.t1,
            words: vec![word],
            overlap_speakers: Vec::new(),
            speaker_margin: margin,
            translations: BTreeMap::new(),
            stale_translations: BTreeMap::new(),
            edited_translations: BTreeSet::new(),
            suppressed_translations: BTreeSet::new(),
            edited_text: None,
        }
    }
    pub fn joined_text(&self) -> String {
        let mut text = String::new();
        for word in &self.words {
            if !text.is_empty()
                && !matches!(
                    word.text.graphemes(true).next(),
                    Some("," | "." | "!" | "?" | "…")
                )
            {
                text.push(' ');
            }
            text.push_str(&word.text);
        }
        text
    }
    pub fn text(&self) -> String {
        self.edited_text
            .clone()
            .unwrap_or_else(|| self.joined_text())
    }
    pub fn is_edited(&self) -> bool {
        self.edited_text.is_some()
    }
    pub fn status(
        &self,
        active_languages: &[String],
        live_tail: bool,
        translate_busy: bool,
    ) -> SegmentStatus {
        if live_tail {
            SegmentStatus::Transcribing
        } else if translate_busy
            && active_languages.iter().any(|lang| {
                !self.translations.contains_key(lang)
                    && !self.suppressed_translations.contains(lang)
            })
        {
            SegmentStatus::Translating
        } else {
            SegmentStatus::Completed
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SegmentStatus {
    Transcribing,
    Translating,
    Completed,
}

pub fn text_revision(text: &str) -> u64 {
    text.trim_matches(whitespace_and_newline)
        .bytes()
        .fold(14_695_981_039_346_656_037, |hash, byte| {
            (hash ^ byte as u64).wrapping_mul(1_099_511_628_211)
        })
}
