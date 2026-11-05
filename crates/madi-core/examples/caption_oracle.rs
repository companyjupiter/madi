//! JSON driver for unchanged Swift CaptionView projection comparison.
use madi_core::{
    caption::{self, Audience, Context},
    preferences::UILanguage,
    settings::CaptionSettings,
    transcript::{Line, Uuid},
};
use serde::Deserialize;
use std::{collections::BTreeMap, io};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputLine {
    text: String,
    end: f64,
    speaker: i64,
    margin: f64,
    translations: BTreeMap<String, String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    audience: Audience,
    targets: Vec<String>,
    settings: CaptionSettings,
    ui_language: UILanguage,
    partial: String,
    interim: BTreeMap<String, String>,
    source: String,
    names: BTreeMap<i64, String>,
    numbers: BTreeMap<i64, u64>,
    level: f32,
    lines: Vec<InputLine>,
}
fn main() {
    let cases: Vec<Case> = serde_json::from_reader(io::stdin()).unwrap();
    let result: Vec<_> = cases
        .into_iter()
        .map(|c| {
            let lines: Vec<_> = c
                .lines
                .into_iter()
                .enumerate()
                .map(|(index, l)| Line {
                    id: Uuid::from_u128(index as u128),
                    speaker: l.speaker,
                    start: 0.0,
                    end: l.end,
                    words: vec![],
                    overlap_speakers: vec![],
                    speaker_margin: l.margin,
                    translations: l.translations,
                    stale_translations: Default::default(),
                    edited_translations: Default::default(),
                    suppressed_translations: Default::default(),
                    edited_text: Some(l.text),
                })
                .collect();
            caption::project(
                &Context {
                    audience: c.audience,
                    targets: &c.targets,
                    settings: &c.settings,
                    ui_language: c.ui_language,
                    partial: &c.partial,
                    interim_translations: &c.interim,
                    interim_source: &c.source,
                    names: &c.names,
                    numbers: &c.numbers,
                    level: c.level,
                },
                lines.iter(),
            )
        })
        .collect();
    serde_json::to_writer(io::stdout(), &result).unwrap();
}
