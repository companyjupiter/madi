//! TranslationOutputPolicy; cleanup changes control leakage and repeated loops,
//! while retry decisions remain conservative and source/target dependent.
use super::{canonical, count, letter_or_number, prefix};
use crate::{
    personal_vocabulary::canonically_equal as equal,
    transcript::{lowercase, trim_whitespace_and_newlines as trim, whitespace},
};
use std::collections::BTreeMap;
use unicode_segmentation::UnicodeSegmentation;

pub fn norm(value: &str) -> &str {
    value.trim_matches(|c| " \t\n.。!?！？\"'".contains(c))
}
pub fn token_cap(source: &str) -> usize {
    ((count(source) as f64 * 1.5) as usize + 24).clamp(48, 512)
}
pub fn expansion_factor(source: &str, target: Option<&str>) -> usize {
    let latin = [
        "English",
        "French",
        "German",
        "Spanish",
        "Italian",
        "Portuguese",
        "Vietnamese",
        "Indonesian",
        "Dutch",
    ];
    if !target.is_some_and(|t| latin.contains(&t)) {
        return 3;
    }
    let letters: Vec<_> = source.chars().filter(|c| c.is_alphabetic()).collect();
    let cjk = letters
        .iter()
        .filter(|&&c| matches!(c as u32,0xac00..=0xd7a3|0x4e00..=0x9fff|0x3040..=0x30ff))
        .count();
    if cjk * 2 > letters.len() { 7 } else { 3 }
}
pub fn runaway_limit(source: &str, target: Option<&str>) -> usize {
    (count(source) * expansion_factor(source, target)).max(80)
}
pub fn truncate_runaway(text: &str, limit: usize) -> String {
    if count(text) <= limit {
        return text.into();
    }
    let head = prefix(text, limit);
    let graphemes: Vec<_> = head.graphemes(true).collect();
    if let Some(cut) = graphemes
        .iter()
        .rposition(|s| [".", "?", "!", "。", "？", "！"].contains(s))
        && cut >= 8
    {
        return graphemes[..=cut].concat().trim_matches(whitespace).into();
    }
    head.trim_matches(whitespace).into()
}

pub fn clean(raw: &str) -> String {
    let mut text = trim(raw).to_owned();
    if let Some(close) = find_tag(&text, "</think>", true) {
        let suffix = trim(&text[close + 8..]);
        if suffix.is_empty() {
            text.replace_range(close..close + 8, "");
        } else {
            text = suffix.into();
        }
    }
    while let Some(open) = find_tag(&text, "<think>", false) {
        let end =
            find_tag(&text[open + 7..], "</think>", false).map_or(text.len(), |i| open + 7 + i + 8);
        text.replace_range(open..end, "");
    }
    trim(&collapse_sentences(&strip_prompt_marker_echo(&text))).into()
}

fn find_tag(text: &str, tag: &str, backwards: bool) -> Option<usize> {
    // Foundation range(of:) matches complete Characters. A tag followed by a
    // combining mark is user text, not a control frame ending inside a grapheme.
    let boundaries: Vec<_> = text
        .grapheme_indices(true)
        .map(|(i, _)| i)
        .chain(std::iter::once(text.len()))
        .collect();
    let mut matches = text.match_indices(tag).filter_map(|(i, _)| {
        (boundaries.binary_search(&i).is_ok() && boundaries.binary_search(&(i + tag.len())).is_ok())
            .then_some(i)
    });
    if backwards {
        matches.last()
    } else {
        matches.next()
    }
}
pub fn strip_prompt_marker_echo(raw: &str) -> String {
    let markers = [
        "Now",
        "now",
        "现在",
        "現在",
        "이제",
        "지금",
        "현재",
        "今",
        "いま",
        "Text",
        "텍스트",
        "文本",
        "Translation",
        "translation",
        "Translated",
        "翻译",
        "翻譯",
        "翻訳",
        "번역",
        "目标中文",
        "目标语言",
        "目標語言",
        "Chinese",
        "Korean",
        "Japanese",
        "English",
        "中文",
        "한국어",
        "日本語",
        "英语",
        "英語",
        "영어",
        "中国語",
        "韓国語",
    ];
    let mut text = raw.to_owned();
    loop {
        let t = trim(&text);
        let mut matched = None;
        'markers: for marker in markers {
            for colon in [":", "："] {
                let needle = format!("{marker}{colon}");
                if super::starts_with(t, &needle) {
                    matched = Some(t.graphemes(true).skip(count(&needle)).collect::<String>());
                    break 'markers;
                }
            }
        }
        if let Some(rest) = matched {
            text = rest;
            continue;
        }
        let mut chars = t.graphemes(true);
        if chars
            .next()
            .is_some_and(|c| [".", ";", "。", "；"].contains(&c))
            && chars.next().is_some_and(|c| c == " " || c == "\u{3000}")
        {
            text = chars.collect();
            continue;
        }
        if equal(
            &t.graphemes(true)
                .rev()
                .take(2)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect::<String>(),
            "=>",
        ) {
            text = t.graphemes(true).take(count(t) - 2).collect();
            continue;
        }
        let stripped = strip_inline_arrows(t);
        if !equal(&stripped, t) {
            text = stripped;
            continue;
        }
        return t.into();
    }
}
pub fn strip_inline_arrows(text: &str) -> String {
    let arrows = ["=>", "->", "→", "=>.", "->."];
    // Swift splits on Character(" "), retaining empty parts, not every space
    // scalar in a grapheme (e.g. space + combining mark).
    let mut parts = vec![String::new()];
    for c in text.graphemes(true) {
        if c == " " {
            parts.push(String::new());
        } else {
            parts.last_mut().unwrap().push_str(c);
        }
    }
    if !parts.iter().any(|s| arrows.contains(&s.as_str())) {
        return text.into();
    }
    let joined = parts
        .into_iter()
        .filter(|s| !arrows.contains(&s.as_str()))
        .collect::<Vec<_>>()
        .join(" ");
    // Foundation's replacement does not split a grapheme. In particular, the
    // second space in "  \u{301}" is part of the marked grapheme, not a match.
    let mut graphemes = joined.graphemes(true).peekable();
    let mut collapsed = String::new();
    while let Some(c) = graphemes.next() {
        collapsed.push_str(c);
        if c == " " && graphemes.peek() == Some(&" ") {
            graphemes.next();
        }
    }
    collapsed.trim_matches(whitespace).into()
}
fn echo_key(character: &str) -> Option<String> {
    letter_or_number(character).then(|| canonical(&lowercase(character)))
}
pub fn echo_keys(text: &str) -> Vec<String> {
    text.graphemes(true).filter_map(echo_key).collect()
}
pub fn strip_example_echo(text: &str, example: Option<&str>, source: &str) -> String {
    let Some(example) = example else {
        return text.into();
    };
    let keys = echo_keys(example);
    if keys.len() < 2 {
        return text.into();
    }
    let mut pos = 0;
    let mut offset = 0;
    for (index, c) in text.grapheme_indices(true) {
        if pos == keys.len() {
            break;
        }
        if let Some(key) = echo_key(c) {
            if key != keys[pos] {
                return text.into();
            }
            pos += 1;
        }
        offset = index + c.len();
    }
    if pos != keys.len() {
        return text.into();
    }
    let rest: String = text[offset..]
        .graphemes(true)
        .skip_while(|g| g.chars().all(|c| " \t\n.。,，;；:：!?！？…-—".contains(c)))
        .collect();
    let rest = trim(&rest);
    if !rest.is_empty() {
        return rest.into();
    }
    if keys.len() > 3 * echo_keys(source).len() + 6 {
        String::new()
    } else {
        text.into()
    }
}
pub fn may_be_example_echo(partial: &str, example: Option<&str>) -> bool {
    let Some(example) = example else {
        return false;
    };
    let p = echo_keys(partial);
    let e = echo_keys(example);
    !p.is_empty() && e.len() >= 2 && p.len() < e.len() && e.starts_with(&p)
}
pub fn similarity(a: &str, b: &str) -> f64 {
    let a = echo_keys(a);
    let b = echo_keys(b);
    if a.len() < 2 || b.len() < 2 {
        return if a == b { 1.0 } else { 0.0 };
    }
    fn grams(keys: &[String]) -> BTreeMap<String, usize> {
        let mut grams = BTreeMap::new();
        for pair in keys.windows(2) {
            *grams.entry(canonical(&pair.concat())).or_default() += 1;
        }
        grams
    }
    let ga = grams(&a);
    let gb = grams(&b);
    let common: usize = ga
        .iter()
        .map(|(g, &n)| n.min(*gb.get(g).unwrap_or(&0)))
        .sum();
    2.0 * common as f64 / (a.len() + b.len() - 2) as f64
}
pub fn is_example_replay(
    output: &str,
    example: Option<&str>,
    source: &str,
    example_source: Option<&str>,
) -> bool {
    let Some(example) = example else {
        return false;
    };
    if echo_keys(example).len() < 12
        || echo_keys(output).is_empty()
        || similarity(output, example) < 0.8
    {
        return false;
    }
    !example_source.is_some_and(|s| similarity(source, s) >= 0.5)
}
pub fn should_retry(output: &str, source: &str, target: &str) -> bool {
    let cleaned = clean(output);
    if cleaned.is_empty() {
        return !output.is_empty();
    }
    if equal(norm(&cleaned), norm(source)) {
        return true;
    }
    cleaned.chars().any(|c| match target {
        "Korean" => is_kana(c),
        "Japanese" => is_hangul(c),
        "Chinese" => is_hangul(c) || is_kana(c),
        "English" => is_hangul(c) || is_kana(c) || is_han(c),
        _ => false,
    })
}
pub fn source_language(text: &str) -> &'static str {
    if text.chars().any(is_hangul) {
        "Korean"
    } else if text.chars().any(is_kana) {
        "Japanese"
    } else if text.chars().any(is_han) {
        "Chinese"
    } else {
        "English"
    }
}
fn is_hangul(c: char) -> bool {
    matches!(c as u32,0x1100..=0x11ff|0x3130..=0x318f|0xa960..=0xa97f|0xac00..=0xd7ff)
}
fn is_kana(c: char) -> bool {
    matches!(c as u32,0x3040..=0x30ff|0x31f0..=0x31ff)
}
fn is_han(c: char) -> bool {
    matches!(c as u32,0x3400..=0x4dbf|0x4e00..=0x9fff|0xf900..=0xfaff)
}
fn collapse_sentences(text: &str) -> String {
    let mut units = Vec::new();
    let mut current = String::new();
    for c in text.chars() {
        current.push(c);
        if ".!?。！？".contains(c) {
            if !trim(&current).is_empty() {
                units.push(trim(&current).to_owned());
            }
            current.clear();
        }
    }
    if !trim(&current).is_empty() {
        units.push(trim(&current).to_owned());
    }
    let mut result = Vec::new();
    let mut i = 0;
    while i < units.len() {
        let mut end = i + 1;
        while end < units.len() && equal(norm(&units[end]), norm(&units[i])) {
            end += 1;
        }
        if end - i >= 3 {
            result.push(units[i].clone());
        } else {
            result.extend_from_slice(&units[i..end]);
        }
        i = end;
    }
    result.join(" ")
}
