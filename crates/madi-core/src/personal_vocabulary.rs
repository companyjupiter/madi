//! PersonalVocabulary.swift's conservative learning, substitution and prompt policy.
use crate::{
    glossary::{Entry, Glossary},
    transcript::{Line, lowercase, trim_whitespace_and_newlines},
};
use serde::Serialize;
use std::collections::BTreeSet;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

const HIGH_CONF_FLOOR: f64 = 0.8;
const MIN_LEN: usize = 3;
const PHONETIC_FLOOR: f64 = 0.92;
const PHONETIC_MIN_LEN: usize = 5;
const PARTICLES: &[&str] = &[
    "한테서",
    "이라고",
    "으로",
    "에게",
    "에서",
    "부터",
    "까지",
    "처럼",
    "보다",
    "께서",
    "한테",
    "이랑",
    "라고",
    "은",
    "는",
    "이",
    "가",
    "을",
    "를",
    "와",
    "과",
    "의",
    "에",
    "께",
    "로",
    "도",
    "만",
    "랑",
];
pub fn canonically_equal(a: &str, b: &str) -> bool {
    a.nfc().eq(b.nfc())
}
use canonically_equal as equal;
fn count(text: &str) -> usize {
    text.graphemes(true).count()
}
fn has_suffix(text: &str, suffix: &str) -> bool {
    text.nfc()
        .collect::<String>()
        .ends_with(&suffix.nfc().collect::<String>())
}
pub fn is_bias_script(term: &str) -> bool {
    let mut letters = 0;
    for scalar in term.chars().filter(|c| c.is_alphabetic()) {
        letters += 1;
        if !matches!(scalar as u32, 0xac00..=0xd7a3 | 0x1100..=0x11ff | 0x3130..=0x318f | 0xa960..=0xa97f | 0xd7b0..=0xd7ff)
        {
            return false;
        }
    }
    letters > 0
}
pub fn bias_terms(glossary: &Glossary) -> Vec<String> {
    if !glossary.enabled {
        return Vec::new();
    }
    let mut confirmed: Vec<_> = glossary
        .entries()
        .filter(|entry| {
            entry.hits >= glossary.min_hits
                && count(&entry.right) >= MIN_LEN
                && is_bias_script(&entry.right)
        })
        .collect();
    confirmed.sort_by(|a, b| {
        b.hits
            .cmp(&a.hits)
            .then_with(|| a.right.nfc().cmp(b.right.nfc()))
    });
    let mut seen = BTreeSet::new();
    let mut output = Vec::new();
    let mut chars = 0;
    for entry in confirmed {
        let term = trim_whitespace_and_newlines(&entry.right);
        if term.is_empty()
            || term.contains(' ')
            || !seen.insert(lowercase(term).nfc().collect::<String>())
        {
            continue;
        }
        let length = count(term) + 1;
        if chars + length > 900 {
            break;
        }
        output.push(term.into());
        chars += length;
        if output.len() >= 32 {
            break;
        }
    }
    output
}
pub fn surface_form(raw: &str) -> String {
    let punctuation = ",.!?…\"'`’”“()-—·:; ";
    lowercase(trim_whitespace_and_newlines(raw).trim_matches(|c: char| punctuation.contains(c)))
}
fn split_particle(surface: &str) -> (&str, Option<&'static str>) {
    let graphemes: Vec<_> = surface.grapheme_indices(true).collect();
    for &particle in PARTICLES {
        if has_suffix(surface, particle) {
            let length = graphemes.len().saturating_sub(count(particle));
            if length >= 2 {
                return (&surface[..graphemes[length].0], Some(particle));
            }
        }
    }
    (surface, None)
}
pub fn normalize(raw: &str) -> String {
    split_particle(&surface_form(raw)).0.into()
}
pub fn normalize_keys(raw: &str) -> Vec<String> {
    let surface = surface_form(raw);
    if surface.is_empty() {
        return Vec::new();
    }
    let (stem, particle) = split_particle(&surface);
    let mut keys = vec![surface.clone()];
    if particle.is_some() && !equal(stem, &surface) {
        keys.push(stem.into());
    }
    keys
}
#[derive(Debug, PartialEq, Serialize)]
pub struct Correction {
    pub wrong: String,
    pub right: String,
}
fn tokens(text: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    for grapheme in text.graphemes(true) {
        // Swift Character.isWhitespace examines the leading scalar, including
        // a space followed by a combining mark in the same grapheme.
        if grapheme.chars().next().is_some_and(char::is_whitespace) {
            if !current.is_empty() {
                result.push(std::mem::take(&mut current));
            }
        } else {
            current.push_str(grapheme);
        }
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}
pub fn diff(before: &str, after: &str) -> Vec<Correction> {
    let before = tokens(before);
    let after = tokens(after);
    if before.len() != after.len() || before.is_empty() {
        return Vec::new();
    }
    let mut result = Vec::new();
    for (before, after) in before.iter().zip(&after) {
        let before = surface_form(before);
        let after = surface_form(after);
        let (before_stem, before_particle) = split_particle(&before);
        let (after_stem, after_particle) = split_particle(&after);
        let shared = before_particle.is_some() && before_particle == after_particle;
        let wrong = if shared { before_stem } else { &before };
        let right = if shared { after_stem } else { &after };
        if !equal(&before, &after) && count(&before) >= MIN_LEN && !right.is_empty() {
            result.push(Correction {
                wrong: wrong.into(),
                right: right.into(),
            });
        }
    }
    result
}
pub fn match_token(raw: &str, rules: &[&Entry], glossary: &Glossary) -> Option<String> {
    let keys = normalize_keys(raw);
    let primary = keys.first()?;
    if count(primary) < MIN_LEN {
        return None;
    }
    let surface = surface_form(raw);
    let (stem, particle) = split_particle(&surface);
    for key in &keys {
        if let Some(entry) = glossary.exact(key) {
            if equal(key, stem)
                && let Some(particle) = particle
                && !has_suffix(&entry.right, particle)
            {
                return Some(format!("{}{particle}", entry.right));
            }
            return Some(entry.right.clone());
        }
    }
    if count(primary) < PHONETIC_MIN_LEN {
        return None;
    }
    let mut best: Option<(&str, f64)> = None;
    for entry in rules
        .iter()
        .filter(|entry| count(&entry.wrong) >= PHONETIC_MIN_LEN)
    {
        let score = jaro_winkler(primary, &entry.wrong);
        if score >= PHONETIC_FLOOR && best.is_none_or(|(_, previous)| score > previous) {
            best = Some((&entry.right, score));
        }
    }
    best.map(|(right, _)| right.into())
}
fn preserving_trailing_punctuation(original: &str, replacement: &str) -> String {
    let mut start = original.len();
    for (index, grapheme) in original.grapheme_indices(true).rev() {
        if ",.!?…\"'`’”“):;".contains(grapheme) {
            start = index;
        } else {
            break;
        }
    }
    format!("{replacement}{}", &original[start..])
}
pub fn correct_incoming_text(raw: &str, conf: f64, glossary: &Glossary) -> String {
    if !glossary.enabled || conf.partial_cmp(&HIGH_CONF_FLOOR) != Some(std::cmp::Ordering::Less) {
        return raw.into();
    }
    let rules = glossary.active_entries();
    if rules.is_empty() {
        return raw.into();
    }
    match match_token(raw, &rules, glossary) {
        Some(replacement) => preserving_trailing_punctuation(raw, &replacement),
        None => raw.into(),
    }
}
pub fn corrected_line_text(line: &Line, glossary: &Glossary) -> Option<String> {
    if !glossary.enabled || line.edited_text.is_some() {
        return None;
    }
    let rules = glossary.active_entries();
    if rules.is_empty() {
        return None;
    }
    let mut changed = false;
    let mut output = String::new();
    for word in &line.words {
        let mut text = word.text.clone();
        if word.conf < HIGH_CONF_FLOOR
            && let Some(replacement) = match_token(&word.text, &rules, glossary)
        {
            text = preserving_trailing_punctuation(&word.text, &replacement);
            changed = true;
        }
        if !output.is_empty()
            && !matches!(
                text.graphemes(true).next(),
                Some("," | "." | "!" | "?" | "…")
            )
        {
            output.push(' ');
        }
        output.push_str(&text);
    }
    changed.then_some(output)
}
pub fn jaro_winkler(a: &str, b: &str) -> f64 {
    if equal(a, b) {
        return 1.0;
    }
    let first: Vec<_> = a.graphemes(true).collect();
    let second: Vec<_> = b.graphemes(true).collect();
    if first.is_empty() || second.is_empty() {
        return 0.0;
    }
    let distance = first.len().max(second.len()) as isize / 2 - 1;
    let mut first_matches = vec![false; first.len()];
    let mut second_matches = vec![false; second.len()];
    let mut matches = 0;
    for (i, first_value) in first.iter().enumerate() {
        let low = (i as isize - distance).max(0) as usize;
        let high = (i as isize + distance + 1)
            .min(second.len() as isize)
            .max(0) as usize;
        for j in low..high {
            if !second_matches[j] && equal(first_value, second[j]) {
                first_matches[i] = true;
                second_matches[j] = true;
                matches += 1;
                break;
            }
        }
    }
    if matches == 0 {
        return 0.0;
    }
    let mut transpositions = 0.0;
    let mut k = 0;
    for (i, matched) in first_matches.iter().enumerate() {
        if *matched {
            while !second_matches[k] {
                k += 1;
            }
            if !equal(first[i], second[k]) {
                transpositions += 1.0;
            }
            k += 1;
        }
    }
    let matches = matches as f64;
    let jaro = (matches / first.len() as f64
        + matches / second.len() as f64
        + (matches - transpositions / 2.0) / matches)
        / 3.0;
    let prefix = first
        .iter()
        .zip(&second)
        .take(4)
        .take_while(|(a, b)| equal(a, b))
        .count();
    jaro + prefix as f64 * 0.1 * (1.0 - jaro)
}
