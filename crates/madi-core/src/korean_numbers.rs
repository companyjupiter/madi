//! Counter-anchored number formatting from KoreanNumberFormatter.swift.
//! Keep all five ambiguity guards and the original order of regex passes.
use regex::Regex;
use std::sync::LazyLock;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

const TENS: &[(&str, i64)] = &[
    ("열", 10),
    ("스물", 20),
    ("스무", 20),
    ("서른", 30),
    ("마흔", 40),
    ("쉰", 50),
    ("예순", 60),
    ("일흔", 70),
    ("여든", 80),
    ("아흔", 90),
];
const ONES: &[(&str, i64)] = &[
    ("한", 1),
    ("두", 2),
    ("세", 3),
    ("네", 4),
    ("다섯", 5),
    ("여섯", 6),
    ("일곱", 7),
    ("여덟", 8),
    ("아홉", 9),
];
const HARD: &str = "년대|개월|시간|년|월|일|시|분|초";
const SOFT: &str = "퍼센트|명|원|개|％|%|세|살|호";
const SINO: &str = "영공일이삼사오육륙칠팔구십백천만억";
static PATTERNS: LazyLock<[Regex; 3]> = LazyLock::new(|| {
    [
        format!("([{SINO}]+?)\\s?({HARD})"),
        format!("([{SINO}]{{2,}}?)\\s?({SOFT})"),
        format!("((?:열|스물|스무|서른|마흔|쉰|예순|일흔|여든|아흔)?(?:한|두|세|네|다섯|여섯|일곱|여덟|아홉)?)\\s?({HARD}|{SOFT})"),
    ].map(|pattern| Regex::new(&pattern).expect("constant Korean number pattern"))
});

/// Swift's Character dictionary compares canonically equivalent graphemes.
/// An out-of-range number is left unchanged instead of trapping as Swift Int does.
pub fn parse_sino(text: &str) -> Option<i64> {
    let (mut total, mut section, mut current) = (0_i64, 0_i64, 0_i64);
    for grapheme in text.graphemes(true) {
        let canonical: String = grapheme.nfc().collect();
        match canonical.as_str() {
            "영" | "공" => current = 0,
            "일" => current = 1,
            "이" => current = 2,
            "삼" => current = 3,
            "사" => current = 4,
            "오" => current = 5,
            "육" | "륙" => current = 6,
            "칠" => current = 7,
            "팔" => current = 8,
            "구" => current = 9,
            "십" | "백" | "천" => {
                let unit = match canonical.as_str() {
                    "십" => 10,
                    "백" => 100,
                    _ => 1000,
                };
                section = section.checked_add(current.max(1).checked_mul(unit)?)?;
                current = 0;
            }
            "만" | "억" => {
                let big = if canonical == "만" {
                    10_000
                } else {
                    100_000_000
                };
                section = section.checked_add(current)?;
                total = total.checked_add(section.max(1).checked_mul(big)?)?;
                section = 0;
                current = 0;
            }
            _ => return None,
        }
    }
    total.checked_add(section)?.checked_add(current)
}

/// Value and consumed Swift Character count; trailing text is not consumed.
pub fn parse_native(text: &str) -> (Option<i64>, usize) {
    let graphemes: Vec<_> = text.graphemes(true).collect();
    let (mut value, mut consumed) = (0, 0);
    for group in [TENS, ONES] {
        for &(word, number) in group {
            let count = word.graphemes(true).count();
            if consumed + count <= graphemes.len()
                && graphemes[consumed..consumed + count]
                    .concat()
                    .nfc()
                    .eq(word.nfc())
            {
                value += number;
                consumed += count;
                break;
            }
        }
    }
    ((consumed != 0).then_some(value), consumed)
}

fn hangul(ch: char) -> bool {
    ('가'..='힣').contains(&ch)
}

fn replace(text: &str, regex: &Regex, pass: usize) -> String {
    let mut replacements = Vec::new();
    let mut offset = 0;
    while let Some(captures) = regex.captures_at(text, offset) {
        let matched = captures.get(0).expect("whole match");
        // Rust regex has no lookbehind. Reject the start, then advance just one
        // scalar: consuming the rejected match would hide a later valid start
        // inside it (e.g. 가삼 일월 must still convert the 일월 suffix).
        if text[..matched.start()]
            .chars()
            .next_back()
            .is_some_and(|ch| hangul(ch) || ch.is_ascii_digit())
        {
            offset = matched.start()
                + text[matched.start()..]
                    .chars()
                    .next()
                    .expect("nonempty counter match")
                    .len_utf8();
            continue;
        }
        offset = matched.end();
        let span = &captures[1];
        let counter = &captures[2];
        let next = text[matched.end()..].chars().next();
        if span.is_empty() || next.is_some_and(|ch| matches!(ch, '오' | '옵' | '십' | '시')) {
            continue;
        }
        if counter == "시"
            && span.graphemes(true).count() == 1
            && next.is_some_and(|ch| hangul(ch) && !"에까부반쯤경로전후넘정간마대께도".contains(ch))
        {
            continue;
        }
        let value = match pass {
            0 if span == "이" => None,
            0 | 1 => parse_sino(span),
            _ => {
                let (value, consumed) = parse_native(span);
                value.filter(|_| consumed == span.graphemes(true).count())
            }
        };
        if let Some(value) = value {
            replacements.push((matched.range(), format!("{value}{counter}")));
        }
    }
    let mut out = text.to_owned();
    for (range, replacement) in replacements.into_iter().rev() {
        out.replace_range(range, &replacement);
    }
    out
}

pub fn format(text: &str) -> String {
    PATTERNS
        .iter()
        .enumerate()
        .fold(text.to_owned(), |out, (index, pattern)| {
            replace(&out, pattern, index)
        })
}
