//! Stateful stdout line contract from the shipping EngineProtocol.swift.
//! Framing, stdout/JSONL barriers and process lifetime are separate adapters.
use crate::swift_number::double;
use crate::translate::{foundation_whitespace, foundation_whitespace_and_newline};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug, PartialEq)]
pub struct SpeakerLabel {
    pub time: f64,
    pub id: i64,
    pub duration: f64,
    pub margin: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Ready,
    WordSectionBegin,
    Word {
        t0: f64,
        t1: f64,
        text: String,
        confidence: f64,
    },
    Speaker(SpeakerLabel),
    SpeakerFix(SpeakerLabel),
    SpeakerOverlap(SpeakerLabel),
    SpeakerOverlapReset,
    SpeakerName {
        id: i64,
        name: String,
    },
    FlushEnd,
    ProgressTotal(i64),
    ProgressChunk(i64),
    LanguageDetected(i64),
    Partial {
        t0: f64,
        text: String,
    },
    SegmentEnd,
    PreviewBegin,
    PreviewWord {
        t0: f64,
        t1: f64,
        text: String,
    },
    PreviewPartial(String),
    PreviewEnd,
    Other(String),
}

#[derive(Default)]
pub struct Decoder {
    in_words: bool,
    in_preview: bool,
}

impl Decoder {
    pub fn decode(&mut self, raw: &str) -> Event {
        let line = raw.trim_matches(foundation_whitespace_and_newline);
        if line == "<<PREVIEW_BEGIN>>" {
            self.in_preview = true;
            self.in_words = false;
            return Event::PreviewBegin;
        }
        if line == "<<PREVIEW_END>>" {
            self.in_preview = false;
            self.in_words = false;
            return Event::PreviewEnd;
        }
        let partial = line.strip_prefix("«partial ").and_then(|rest| {
            let (time, text) = rest.split_once("» ")?;
            Some((double(time)?, text))
        });
        if self.in_preview {
            if line.starts_with("=== WORD TIMESTAMPS") {
                self.in_words = true;
            } else if line.starts_with("=== ") {
                self.in_words = false;
            } else if let Some((_, text)) = partial {
                return Event::PreviewPartial(text.into());
            } else if self.in_words
                && line.starts_with('[')
                && let Some(Event::Word { t0, t1, text, .. }) = parse_word(line)
            {
                return Event::PreviewWord { t0, t1, text };
            }
            // No speaker, language, progress or flush control may escape a
            // preview lane, including controls introduced by a future engine.
            return Event::Other(line.into());
        }
        if line.starts_with("[stream] ready") {
            return Event::Ready;
        }
        match line {
            "<<FLUSH_END>>" => return Event::FlushEnd,
            "<<SEG_END>>" => return Event::SegmentEnd,
            "SPKOVRESET" => return Event::SpeakerOverlapReset,
            _ => {}
        }
        if line.starts_with("[8] audio:")
            && let Some((_, rest)) = line.split_once("→ ")
            && let Some(count) = integer_prefix(rest)
        {
            return Event::ProgressTotal(count);
        }
        if let Some(rest) = line.strip_prefix("[perf] chunk ")
            && let Some(count) = integer_prefix(rest)
        {
            return Event::ProgressChunk(count);
        }
        for prefix in ["[lang] locked token ", "[lang] detected token "] {
            if let Some(rest) = line.strip_prefix(prefix)
                && let Some(token) = integer_prefix(rest)
            {
                return Event::LanguageDetected(token);
            }
        }
        if line.starts_with("=== WORD TIMESTAMPS") {
            self.in_words = true;
            return Event::WordSectionBegin;
        }
        if line.starts_with("=== ") {
            self.in_words = false;
            return Event::Other(line.into());
        }
        if let Some(rest) = line.strip_prefix("SPKNAME ")
            && let Some((id, name)) = rest.split_once(' ')
            && let Ok(id) = id.parse()
        {
            let name = name.trim_matches(foundation_whitespace);
            if !name.is_empty() {
                return Event::SpeakerName {
                    id,
                    name: name.into(),
                };
            }
        }
        if let Some((t0, text)) = partial {
            return Event::Partial {
                t0,
                text: text.into(),
            };
        }
        if let Some(label) = parse_speaker(line, "SPKFIX") {
            return Event::SpeakerFix(label);
        }
        if let Some(label) = parse_speaker(line, "SPKOV") {
            return Event::SpeakerOverlap(label);
        }
        if let Some(label) = parse_speaker(line, "SPK") {
            return Event::Speaker(label);
        }
        if self.in_words
            && line.starts_with('[')
            && let Some(word) = parse_word(line)
        {
            return word;
        }
        Event::Other(line.into())
    }
}

fn integer_prefix(text: &str) -> Option<i64> {
    // Character.isNumber checks the grapheme's leading numeric scalar, but
    // Int must parse the entire selected grapheme sequence (including marks).
    let end = text
        .grapheme_indices(true)
        .find(|(_, g)| !g.chars().next().is_some_and(char::is_numeric))
        .map(|(index, _)| index)
        .unwrap_or(text.len());
    text[..end].parse().ok()
}

pub fn parse_speaker(line: &str, tag: &str) -> Option<SpeakerLabel> {
    let mut parts = line
        .strip_prefix(tag)?
        .strip_prefix(' ')?
        .split(' ')
        .filter(|s| !s.is_empty());
    Some(SpeakerLabel {
        time: double(parts.next()?)?,
        id: parts.next()?.parse().ok()?,
        duration: parts.next().and_then(double).unwrap_or(1.5),
        margin: parts.next().and_then(double).unwrap_or(1.0),
    })
}

pub fn parse_word(line: &str) -> Option<Event> {
    let (bracket, tail) = line.strip_prefix('[')?.split_once(']')?;
    let mut body = tail.trim_matches(foundation_whitespace);
    let mut confidence = 1.0;
    if let Some((text, suffix)) = body.split_once("«conf ") {
        confidence = double(suffix.split('»').next()?).unwrap_or(1.0);
        body = text.trim_matches(foundation_whitespace);
    }
    let span = bracket.replace('s', "");
    // Swift split(maxSplits: 1) omits leading empty components: a leading
    // minus sign is dropped by the existing parser. Preserve that behavior.
    let span = span.trim_start_matches('-');
    let mut ends = span.splitn(2, '-').filter(|s| !s.is_empty());
    let t0 = double(ends.next()?)?;
    let t1 = ends.next().and_then(double).unwrap_or(t0);
    if body.is_empty() {
        return None;
    }
    Some(Event::Word {
        t0,
        t1,
        text: body.into(),
        confidence,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_quarantines_control_and_returns_to_committed_section() {
        let mut parser = Decoder::default();
        assert_eq!(parser.decode("<<PREVIEW_BEGIN>>"), Event::PreviewBegin);
        for control in [
            "[stream] ready",
            "SPK 0 7",
            "SPKFIX 0 7",
            "SPKOV 0 7",
            "SPKOVRESET",
            "<<FLUSH_END>>",
            "<<SEG_END>>",
            "[lang] locked token 50264",
        ] {
            assert_eq!(parser.decode(control), Event::Other(control.into()));
        }
        parser.decode("=== WORD TIMESTAMPS ===");
        assert_eq!(
            parser.decode("[0.1s-0.5s] 안녕 «conf 0.9»"),
            Event::PreviewWord {
                t0: 0.1,
                t1: 0.5,
                text: "안녕".into()
            }
        );
        parser.decode("<<PREVIEW_END>>");
        assert!(matches!(
            parser.decode("[1s-2s] not in a section"),
            Event::Other(_)
        ));
        parser.decode("=== WORD TIMESTAMPS ===");
        assert!(matches!(
            parser.decode("[1s-2s] committed"),
            Event::Word { .. }
        ));
        assert_eq!(parser.decode("<<FLUSH_END>>"), Event::FlushEnd);
    }

    #[test]
    fn both_language_versions_and_old_speaker_defaults_are_preserved() {
        let mut parser = Decoder::default();
        for line in [
            "[lang] locked token 50259 margin 2.60",
            "[lang] detected token 50259 (en)",
        ] {
            assert_eq!(parser.decode(line), Event::LanguageDetected(50259));
        }
        assert_eq!(
            parser.decode("SPKFIX 12.5 2 bad bad"),
            Event::SpeakerFix(SpeakerLabel {
                time: 12.5,
                id: 2,
                duration: 1.5,
                margin: 1.0
            })
        );
        assert_eq!(
            parser.decode("SPKNAME 2 김 부장"),
            Event::SpeakerName {
                id: 2,
                name: "김 부장".into()
            }
        );
    }
}
