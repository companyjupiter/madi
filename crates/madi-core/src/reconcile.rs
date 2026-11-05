//! Conservative TranscriptReconciler grammar and SummaryEngine batch policy.
pub mod audio;
use crate::transcript::{lowercase, trim_whitespace_and_newlines, whitespace};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Merge {
    pub from: i64,
    pub into: i64,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Relabel {
    pub line: usize,
    pub speaker: i64,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LanguageFlag {
    pub line: usize,
    pub lang: String,
}
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub merges: Vec<Merge>,
    pub relabels: Vec<Relabel>,
    pub language_flags: Vec<LanguageFlag>,
}
impl Plan {
    pub fn is_empty(&self) -> bool {
        self.merges.is_empty() && self.relabels.is_empty() && self.language_flags.is_empty()
    }
}

pub const INSTRUCTION: &str = concat!(
    "다음은 화자별로 라벨된 대화 전사다. △는 화자 판정 불확실, ◇는 디코드 저신뢰/구제 발생 줄이다. 명백히 잘못된 것만 아래 문법으로 한 줄씩 교정하라. ",
    "확실하지 않으면 아무것도 출력하지 마라. 문법: ",
    "MERGE <없앨화자> <남길화자> (같은 사람이면 첫째를 둘째로 합침) / ",
    "RELABEL <줄번호> <화자> (그 줄이 다른 화자면) / ",
    "LANG <줄번호> <ko|en|ja|zh> (그 줄이 다른 언어인데 잘못 받아써졌으면). ",
    "예: MERGE 1 3 / RELABEL 5 2 / LANG 4 ja. 교정 없으면 OK 한 줄."
);

pub fn prompt_input<'a>(
    lines: impl IntoIterator<Item = (i64, &'a str)>,
    speaker_name: impl Fn(i64) -> String,
    uncertain: &BTreeSet<usize>,
    language_risk: &BTreeSet<usize>,
) -> String {
    let mut out = String::new();
    for (i, (speaker, text)) in lines.into_iter().enumerate() {
        out.push_str(&format!(
            "{}{}{} [S{}·{}] {}\n",
            i + 1,
            if uncertain.contains(&i) { "△" } else { "" },
            if language_risk.contains(&i) {
                "◇"
            } else {
                ""
            },
            speaker,
            speaker_name(speaker),
            text
        ));
    }
    out
}

// Swift String.split operates on Characters, including CRLF as one Character.
// A slash/space with an attached combining mark is not the slash/space delimiter.
fn split_characters(text: &str, separator: impl Fn(&str) -> bool) -> Vec<&str> {
    let mut start = 0;
    let mut parts = Vec::new();
    for (at, grapheme) in text.grapheme_indices(true) {
        if separator(grapheme) {
            if start < at {
                parts.push(&text[start..at]);
            }
            start = at + grapheme.len();
        }
    }
    if start < text.len() {
        parts.push(&text[start..]);
    }
    parts
}

pub fn prompt_batches(numbered: &str, budget: i64) -> Vec<String> {
    if budget <= 0 {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut current = String::new();
    for row in split_characters(numbered, |g| g == "\n") {
        let bounded: String = row.graphemes(true).take(budget as usize).collect();
        let candidate = if current.is_empty() {
            bounded.clone()
        } else {
            format!("{current}\n{bounded}")
        };
        if candidate.graphemes(true).count() > budget as usize && !current.is_empty() {
            out.push(std::mem::replace(&mut current, bounded));
        } else {
            current = candidate;
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

fn upper(text: &str) -> String {
    // Swift equality is canonically equivalent (e.g. the Kelvin sign in OK).
    text.to_uppercase().nfc().collect()
}
fn language_name(code: &str) -> Option<&'static str> {
    match lowercase(code).nfc().collect::<String>().as_str() {
        "ko" | "korean" | "한국어" => Some("Korean"),
        "en" | "english" | "영어" => Some("English"),
        "ja" | "japanese" | "일본어" => Some("Japanese"),
        "zh" | "chinese" | "중국어" => Some("Chinese"),
        _ => None,
    }
}
pub fn language_token(name: &str) -> Option<i64> {
    match name.nfc().collect::<String>().as_str() {
        "Korean" => Some(50264),
        "English" => Some(50259),
        "Japanese" => Some(50266),
        "Chinese" => Some(50260),
        _ => None,
    }
}
pub fn language_flag_allowed(name: &str, session_token: Option<i64>) -> bool {
    session_token.is_none() || language_token(name) == session_token
}

pub fn parse(
    reply: &str,
    speakers: &BTreeSet<i64>,
    line_count: i64,
    max_corrections: i64,
    relabel_allowed: Option<&BTreeSet<usize>>,
) -> Plan {
    let mut plan = Plan::default();
    let (mut sources, mut targets, mut relabeled, mut langged) = (
        BTreeSet::new(),
        BTreeSet::new(),
        BTreeSet::new(),
        BTreeSet::new(),
    );
    let mut accepted = 0;
    for raw in split_characters(reply, |g| {
        matches!(
            g,
            "/" | "\n" | "\r" | "\r\n" | "\u{b}" | "\u{c}" | "\u{85}" | "\u{2028}" | "\u{2029}"
        )
    }) {
        if accepted >= max_corrections {
            break;
        }
        let line = raw.trim_matches(whitespace);
        if line.is_empty() || upper(line) == "OK" {
            continue;
        }
        let tokens = split_characters(line, |g| g == " " || g == "\t");
        if tokens.len() < 3 {
            continue;
        }
        let Ok(first) = tokens[1].parse::<i64>() else {
            continue;
        };
        match upper(tokens[0]).as_str() {
            "MERGE" => {
                let Ok(second) = tokens[2].parse::<i64>() else {
                    continue;
                };
                if first == second
                    || !speakers.contains(&first)
                    || !speakers.contains(&second)
                    || sources.contains(&first)
                    || targets.contains(&first)
                    || sources.contains(&second)
                {
                    continue;
                }
                sources.insert(first);
                targets.insert(second);
                plan.merges.push(Merge {
                    from: first,
                    into: second,
                });
            }
            "RELABEL" => {
                let Ok(speaker) = tokens[2].parse::<i64>() else {
                    continue;
                };
                if first < 1 || first > line_count || !speakers.contains(&speaker) {
                    continue;
                }
                let line = (first - 1) as usize;
                if relabeled.contains(&line)
                    || relabel_allowed.is_some_and(|allowed| !allowed.contains(&line))
                {
                    continue;
                }
                relabeled.insert(line);
                plan.relabels.push(Relabel { line, speaker });
            }
            "LANG" => {
                if first < 1 || first > line_count {
                    continue;
                }
                let Some(lang) = language_name(tokens[2]) else {
                    continue;
                };
                let line = (first - 1) as usize;
                if !langged.insert(line) {
                    continue;
                }
                plan.language_flags.push(LanguageFlag {
                    line,
                    lang: lang.into(),
                });
            }
            _ => continue,
        }
        accepted += 1;
    }
    plan
}

/// SummaryEngine keeps successful non-OK parts in callback order, including
/// after queued requests complete with nil. All empty/failed parts yield OK.
#[derive(Default)]
pub struct Replies {
    remaining: usize,
    parts: Vec<String>,
}
impl Replies {
    pub fn new(count: usize) -> Self {
        Self {
            remaining: count,
            parts: Vec::new(),
        }
    }
    pub fn pending(&self) -> usize {
        self.remaining
    }
    pub fn complete(&mut self, text: Option<&str>) -> Option<String> {
        if self.remaining == 0 {
            return None;
        }
        let out = trim_whitespace_and_newlines(text.unwrap_or_default());
        if !out.is_empty() && upper(out) != "OK" {
            self.parts.push(out.into());
        }
        self.remaining -= 1;
        (self.remaining == 0).then(|| {
            if self.parts.is_empty() {
                "OK".into()
            } else {
                self.parts.join("\n")
            }
        })
    }
}
