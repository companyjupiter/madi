//! CaptionOverlay's source/translation pairing and viewer-language projection.
//! The shipping host disables interim translation; the pairing rules remain
//! explicit so a future producer cannot show a translation over newer speech.
use crate::{
    preferences::UILanguage,
    settings::CaptionSettings,
    setup::sorted_targets,
    transcript::{Line, SpeakerNumbers, UNKNOWN_SPEAKER},
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Audience {
    Staff,
    Patient,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Live,
    Translating,
    Waiting,
}
impl Status {
    pub fn text(self, language: Option<&str>) -> &'static str {
        let values = match language {
            Some("English") => ["listening", "translating…", "waiting for speech…"],
            Some("Japanese") => ["認識中", "翻訳中…", "音声を待っています…"],
            Some("Chinese") => ["识别中", "翻译中…", "正在等待语音…"],
            _ => ["진행 중", "번역 중…", "음성을 기다리는 중…"],
        };
        values[match self {
            Self::Live => 0,
            Self::Translating => 1,
            Self::Waiting => 2,
        }]
    }
}
pub struct Context<'a> {
    pub audience: Audience,
    pub targets: &'a [String],
    pub settings: &'a CaptionSettings,
    pub ui_language: UILanguage,
    pub partial: &'a str,
    pub interim_translations: &'a BTreeMap<String, String>,
    pub interim_source: &'a str,
    pub names: &'a BTreeMap<i64, String>,
    pub numbers: &'a BTreeMap<i64, u64>,
    pub level: f32,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Caption {
    pub translation: String,
    pub original: String,
    pub provisional: bool,
    pub speaker: Option<i64>,
    pub margin: f64,
    pub age: f64,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Projection {
    pub language: Option<String>,
    pub caption: Option<Caption>,
    pub status: Status,
    pub status_text: String,
    pub waiting_text: String,
    pub header: String,
    pub speaker_label: Option<String>,
    pub preview: Option<String>,
    pub meter: [bool; 5],
}
fn pick<'a>(values: &'a BTreeMap<String, String>, language: Option<&str>) -> Option<&'a str> {
    let text = language
        .and_then(|l| values.get(l))
        .or_else(|| values.values().next())?;
    (!text.is_empty()).then_some(text.as_str())
}
pub fn language(
    audience: Audience,
    targets: &[String],
    settings: &CaptionSettings,
) -> Option<String> {
    let targets = sorted_targets(targets.iter().cloned());
    match audience {
        Audience::Staff => targets.first().cloned(),
        Audience::Patient => settings
            .patient_lang_override
            .clone()
            .or_else(|| targets.iter().find(|t| t.as_str() != "Korean").cloned())
            .or_else(|| targets.first().cloned()),
    }
}
pub fn project<'a>(
    context: &Context<'_>,
    mut lines: impl DoubleEndedIterator<Item = &'a Line>,
) -> Projection {
    let language = language(context.audience, context.targets, context.settings);
    let last = lines.next_back();
    let latest = last
        .filter(|l| !l.translations.is_empty())
        .or_else(|| lines.rev().find(|l| !l.translations.is_empty()));
    let interim = pick(context.interim_translations, language.as_deref());
    let caption = if let Some(text) = interim.filter(|_| !context.partial.is_empty()) {
        Some(Caption {
            translation: text.into(),
            original: if context.interim_source.is_empty() {
                context.partial
            } else {
                context.interim_source
            }
            .into(),
            provisional: true,
            speaker: None,
            margin: 1.0,
            age: 0.0,
        })
    } else if let Some(text) = interim.filter(|_| {
        !context.interim_source.is_empty() && last.is_none_or(|l| l.translations.is_empty())
    }) {
        Some(Caption {
            translation: text.into(),
            original: context.interim_source.into(),
            provisional: true,
            speaker: None,
            margin: 1.0,
            age: 0.0,
        })
    } else {
        latest.and_then(|line| {
            pick(&line.translations, language.as_deref()).map(|text| Caption {
                translation: text.into(),
                original: line.text(),
                provisional: false,
                speaker: Some(line.speaker),
                margin: line.speaker_margin,
                age: last.map_or(line.end, |l| l.end) - line.end,
            })
        })
    };
    let status = if caption.as_ref().is_some_and(|c| c.provisional) {
        Status::Live
    } else if !context.partial.is_empty() {
        Status::Translating
    } else {
        Status::Waiting
    };
    let speaker_label = caption
        .as_ref()
        .and_then(|c| c.speaker.map(|id| (c, id)))
        .filter(|_| !context.names.is_empty())
        .map(|(c, id)| {
            if id == UNKNOWN_SPEAKER {
                return "미확인".into();
            }
            if let Some(name) = context.names.get(&id).filter(|n| !n.is_empty()) {
                return name.clone();
            }
            if SpeakerNumbers::is_deciding(c.margin, c.age) {
                return match context.ui_language {
                    UILanguage::Ko => "화자분리중…",
                    UILanguage::En => "Separating speakers…",
                    UILanguage::Ja => "話者分離中…",
                }
                .into();
            }
            let number = context
                .numbers
                .get(&id)
                .map_or(id.to_string(), ToString::to_string);
            format!(
                "{} {number}",
                match context.ui_language {
                    UILanguage::Ko => "화자",
                    UILanguage::En => "Speaker",
                    UILanguage::Ja => "話者",
                }
            )
        });
    let title = if context.ui_language == UILanguage::Ko {
        "실시간 자막"
    } else {
        "Live captions"
    };
    Projection {
        header: format!(
            "{title}{}",
            language
                .as_ref()
                .map_or(String::new(), |l| format!(" · {l}"))
        ),
        status_text: status.text(language.as_deref()).into(),
        waiting_text: Status::Waiting.text(language.as_deref()).into(),
        preview: (caption.is_none() && !context.partial.is_empty()).then(|| context.partial.into()),
        meter: std::array::from_fn(|i| f64::from(context.level) * 5.0 > i as f64),
        language,
        caption,
        status,
        speaker_label,
    }
}
