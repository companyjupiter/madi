//! Meeting-title policy from the shipping TitleGenerator.swift.
//! The host supplies its native alphanumeric classifier; this module does no IO.
use crate::transcript::{whitespace, whitespace_and_newline};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

pub const MAX_LENGTH: usize = 24;

pub fn prompt(transcript: &str) -> String {
    format!(
        "다음 회의록을 대표하는 짧은 제목을 한 줄로만 답하세요. 24자 이내, 명사구로. 따옴표·마침표·설명 없이 제목만. 회의록: {transcript}"
    )
}

fn collapse(text: &str) -> String {
    text.graphemes(true)
        .collect::<Vec<_>>()
        .split(|g| g.chars().next().is_some_and(char::is_whitespace))
        .filter(|part| !part.is_empty())
        .map(|part| part.concat())
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches(whitespace)
        .to_owned()
}

pub fn sanitize_with(raw: &str, alphanumeric: fn(char) -> bool) -> Option<String> {
    // Swift splits Characters, so CRLF is a single nonmatching grapheme here.
    let graphemes: Vec<_> = raw.graphemes(true).collect();
    let mut text = graphemes
        .split(|g| *g == "\n" || *g == "\r")
        .map(|line| line.concat().trim_matches(whitespace).to_owned())
        .find(|line| !line.is_empty())?;
    for label in ["제목:", "제목 :", "title:", "title :"] {
        let count = label.graphemes(true).count();
        let prefix: String = text.graphemes(true).take(count).collect();
        // Swift prefix equality is canonical; preserve the original remainder.
        if prefix.to_lowercase().nfc().eq(label.chars()) {
            text = text
                .graphemes(true)
                .skip(count)
                .collect::<String>()
                .trim_matches(whitespace)
                .to_owned();
            break;
        }
    }
    text.retain(|c| !"*_`#~".contains(c));
    text = collapse(&text);
    text.retain(|c| !"/\\:*?\"<>|\0".contains(c));
    text = text
        .trim_matches(|c| {
            whitespace_and_newline(c) || "\"'“”‘’`«»()[]{}<>.,!?;:…-–—~*_#/\\　".contains(c)
        })
        .to_owned();
    text = collapse(&text);
    if text.graphemes(true).count() > MAX_LENGTH {
        text = text
            .graphemes(true)
            .take(MAX_LENGTH)
            .collect::<String>()
            .trim_matches(whitespace)
            .to_owned();
    }
    (!text.is_empty() && text.chars().any(alphanumeric)).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removes_wrapping_and_path_separators_without_changing_korean() {
        assert_eq!(
            sanitize_with("제목: **분기 / 예산: 검토**", char::is_alphanumeric).as_deref(),
            Some("분기 예산 검토")
        );
        assert_eq!(sanitize_with("\"../:*?\"", char::is_alphanumeric), None);
        assert_eq!(
            sanitize_with("\n\n주간 회의\n설명", char::is_alphanumeric).as_deref(),
            Some("주간 회의")
        );
    }

    #[test]
    fn caps_extended_graphemes_and_preserves_decomposed_text() {
        let value = format!("{}z", "한👩‍💻".repeat(20));
        let result = sanitize_with(&value, char::is_alphanumeric).unwrap();
        assert_eq!(result, "한👩‍💻".repeat(12));
        assert_eq!(
            sanitize_with("제목: 한글", char::is_alphanumeric).as_deref(),
            Some("한글")
        );
    }
}
