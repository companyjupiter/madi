//! The shipping Markdown representation and its intentionally lossy reopen path.
//! Reopened Markdown cannot recover original per-word timing or confidence.
use super::{Line, Word, whitespace, whitespace_and_newline};
use regex::Regex;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::LazyLock,
};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

pub struct Parsed {
    pub lines: Vec<Line>,
    pub names: BTreeMap<i64, String>,
}

fn name(speaker: i64, names: &BTreeMap<i64, String>) -> String {
    if speaker == 255 {
        "미확인".into()
    } else {
        names
            .get(&speaker)
            .cloned()
            .unwrap_or_else(|| format!("Speaker {speaker}"))
    }
}
fn timecode(time: f64) -> String {
    // Native String(format: "%02d:%02d", ...) consumes 32-bit format operands.
    let seconds = time as i64;
    format!("{:02}:{:02}", (seconds / 60) as i32, (seconds % 60) as i32)
}
pub fn markdown(lines: &[Line], names: &BTreeMap<i64, String>, summary: Option<&str>) -> String {
    let mut output = "# Transcript\n\n".to_owned();
    if let Some(summary) =
        summary.filter(|text| !text.trim_matches(whitespace_and_newline).is_empty())
    {
        output.push_str(&format!("## 회의 요약\n\n{summary}\n\n---\n\n"));
    }
    output.push_str("> *기울임* 표시된 단어는 인식 신뢰도가 낮습니다 — 검토 권장.\n\n");
    for line in lines {
        let body = if line.is_edited() {
            line.text()
        } else {
            render_words(&line.words)
        };
        output.push_str(&format!(
            "- **[{}] {}** {}",
            timecode(line.start),
            name(line.speaker, names),
            body
        ));
        for speaker in &line.overlap_speakers {
            output.push_str(&format!(" ⟨+{} 겹침⟩", name(*speaker, names)));
        }
        output.push('\n');
        // Swift String ordering compares canonically equivalent scalar content.
        let mut translations: Vec<_> = line.translations.iter().collect();
        translations.sort_by_cached_key(|(language, _)| language.nfc().collect::<String>());
        for (language, text) in translations {
            output.push_str(&format!(
                "  - [번역:{language}] {}\n",
                text.replace('\n', " ")
            ));
        }
    }
    output
}
fn render_words(words: &[Word]) -> String {
    let mut output = String::new();
    for (index, word) in words.iter().enumerate() {
        if index > 0
            && !matches!(
                word.text.graphemes(true).next(),
                Some("," | "." | "!" | "?" | "…")
            )
        {
            output.push(' ');
        }
        let trimmed = word.text.trim_matches(whitespace);
        if word.conf < 0.55 && !trimmed.is_empty() {
            output.push('*');
            output.push_str(trimmed);
            output.push('*');
        } else {
            output.push_str(&word.text);
        }
    }
    output
}
pub fn plain_text(lines: &[Line], names: &BTreeMap<i64, String>) -> String {
    lines
        .iter()
        .map(|line| {
            format!(
                "[{}] {}: {}\n",
                timecode(line.start),
                name(line.speaker, names),
                line.text()
            )
        })
        .collect()
}

static BULLET: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^- \*\*\[(\d+):(\d{2})\] (.+?)\*\* ?(.*)$").unwrap());
static TRANSLATION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^  - \[번역:([^\]]+)\] ?(.*)$").unwrap());
static SPEAKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^Speaker (\d+)$").unwrap());
static OVERLAP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*⟨\+[^⟩]*⟩").unwrap());

fn normalized(text: &str) -> String {
    text.nfc().collect()
}
fn speaker_number(name: &str) -> Option<i64> {
    SPEAKER.captures(name)?.get(1)?.as_str().parse().ok()
}

/// Newlines, canonical-equivalent names, reserved numeric/Unknown speaker IDs,
/// markup stripping and imported-translation ownership follow TranscriptArchive.
/// Integer overflow that would trap the native parser is rejected as no archive.
pub fn parse(text: &str) -> Option<Parsed> {
    struct Raw {
        start: f64,
        who: String,
        body: String,
        translations: BTreeMap<String, String>,
    }
    let mut raws: Vec<Raw> = Vec::new();
    let mut order = Vec::new();
    let mut seen = BTreeSet::new();
    let mut max_reserved = -1;
    for row in text.split([
        '\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
    ]) {
        if let Some(matched) = TRANSLATION.captures(row)
            && let Some(last) = raws.last_mut()
        {
            let key = matched[1].to_owned();
            let normalized_key = normalized(&key);
            // Dictionary replacement retains the first spelling of the key.
            let key = last
                .translations
                .keys()
                .find(|old| normalized(old) == normalized_key)
                .cloned()
                .unwrap_or(key);
            last.translations.insert(key, matched[2].into());
            continue;
        }
        let Some(matched) = BULLET.captures(row) else {
            continue;
        };
        let start = matched[1].parse::<f64>().unwrap_or(0.0) * 60.0
            + matched[2].parse::<f64>().unwrap_or(0.0);
        let who = matched[3].trim_matches(whitespace).to_owned();
        raws.push(Raw {
            start,
            who: who.clone(),
            body: matched[4].into(),
            translations: BTreeMap::new(),
        });
        if seen.insert(normalized(&who)) {
            order.push(who.clone());
        }
        if let Some(number) = speaker_number(&who) {
            max_reserved = max_reserved.max(number);
        }
    }
    if raws.is_empty() {
        return None;
    }
    let mut next = max_reserved.checked_add(1)?;
    let mut ids = BTreeMap::new();
    let mut names = BTreeMap::new();
    for who in order {
        let id = if normalized(&who) == "미확인" {
            255
        } else if let Some(number) = speaker_number(&who) {
            number
        } else {
            let id = next;
            next = next.checked_add(1)?;
            names.insert(id, who.clone());
            id
        };
        ids.insert(normalized(&who), id);
    }
    let mut lines = Vec::new();
    for (index, raw) in raws.iter().enumerate() {
        let end = raws
            .get(index + 1)
            .map_or(raw.start, |next| raw.start.max(next.start));
        let words = parse_words(&raw.body, raw.start);
        lines.push(Line {
            id: words
                .first()
                .map(|word| word.id)
                .unwrap_or_else(Uuid::new_v4),
            speaker: ids.get(&normalized(&raw.who)).copied().unwrap_or(0),
            start: raw.start,
            end,
            words,
            overlap_speakers: Vec::new(),
            speaker_margin: 1.0,
            translations: raw.translations.clone(),
            stale_translations: BTreeMap::new(),
            edited_translations: raw.translations.keys().cloned().collect(),
            suppressed_translations: BTreeSet::new(),
            edited_text: None,
        });
    }
    Some(Parsed { lines, names })
}
fn parse_words(body: &str, time: f64) -> Vec<Word> {
    let stripped = OVERLAP.replace_all(body, "");
    let mut result = Vec::new();
    // String.split(separator: " ") compares Characters (graphemes), not scalars.
    let mut token = String::new();
    let emit = |token: &mut String, result: &mut Vec<Word>| {
        // Native contains/replacingOccurrences do not split a combining
        // sequence such as asterisk + acute or the asterisk keycap emoji.
        let low = token.graphemes(true).any(|grapheme| grapheme == "*");
        let text: String = token
            .graphemes(true)
            .filter(|grapheme| *grapheme != "*")
            .collect();
        if !text.is_empty() {
            result.push(Word::new(time, time, text, if low { 0.3 } else { 1.0 }));
        }
        token.clear();
    };
    for grapheme in stripped.graphemes(true) {
        if grapheme == " " {
            emit(&mut token, &mut result);
        } else {
            token.push_str(grapheme);
        }
    }
    emit(&mut token, &mut result);
    result
}
