//! Port of the shipped Swift TranslateStreamParser, including accumulated deltas.
//! Incomplete UTF-8 is held until a later read; pipe read boundaries are arbitrary.

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Ready,
    PrefixReady(i64),
    Capabilities(Vec<String>),
    ReplyDelta(String),
    TurnComplete(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Control,
    Reply,
    AfterReplyNewline,
}

/// Foundation changed String(data:encoding:.utf8) between macOS releases.
/// Keep the compatibility choice explicit instead of changing golden events.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Utf8BomPolicy {
    Preserve,
    StripLeading,
}

impl Utf8BomPolicy {
    pub(crate) fn apply(self, text: &str) -> &str {
        match self {
            Self::Preserve => text,
            Self::StripLeading => text.strip_prefix('\u{feff}').unwrap_or(text),
        }
    }
}

pub struct TranslateStreamParser {
    buffer: Vec<u8>,
    reply: Vec<u8>,
    state: State,
    preserve_newlines: bool,
    bom_policy: Utf8BomPolicy,
}

impl Default for TranslateStreamParser {
    fn default() -> Self {
        Self::new(false)
    }
}

impl TranslateStreamParser {
    const GENERATION_MARKER: &'static [u8] = b"[perf] generation";

    pub fn new(preserve_newlines: bool) -> Self {
        Self::with_bom_policy(preserve_newlines, Utf8BomPolicy::StripLeading)
    }

    pub fn with_bom_policy(preserve_newlines: bool, bom_policy: Utf8BomPolicy) -> Self {
        Self {
            buffer: Vec::new(),
            reply: Vec::new(),
            state: State::Control,
            preserve_newlines,
            bom_policy,
        }
    }

    pub fn ingest(&mut self, chunk: &[u8]) -> Vec<Event> {
        self.buffer.extend_from_slice(chunk);
        let mut events = Vec::new();
        loop {
            match self.state {
                State::Control => {
                    let Some(newline) = self.buffer.iter().position(|&b| b == b'\n') else {
                        break;
                    };
                    let line: Vec<u8> = self.buffer.drain(..=newline).collect();
                    if let Some(event) = self.handle_control(&line[..newline]) {
                        events.push(event);
                    }
                }
                State::Reply => {
                    if let Some(newline) = self.buffer.iter().position(|&b| b == b'\n') {
                        self.reply.extend_from_slice(&self.buffer[..newline]);
                        self.buffer.drain(..=newline);
                        self.state = State::AfterReplyNewline;
                    } else {
                        if self.buffer.is_empty() {
                            break;
                        }
                        self.reply.append(&mut self.buffer);
                        if let Some(text) =
                            decode_stable_prefix_with_policy(&self.reply, self.bom_policy)
                            && !text.is_empty()
                        {
                            events.push(Event::ReplyDelta(text.to_owned()));
                        }
                        break;
                    }
                }
                State::AfterReplyNewline => {
                    if self.buffer.len() >= Self::GENERATION_MARKER.len() {
                        if self.buffer.starts_with(Self::GENERATION_MARKER) {
                            self.state = State::Control;
                        } else {
                            self.continue_reply();
                        }
                    } else if self.buffer.contains(&b'\n') {
                        self.continue_reply();
                    } else {
                        break;
                    }
                }
            }
        }
        events
    }

    fn continue_reply(&mut self) {
        self.reply
            .push(if self.preserve_newlines { b'\n' } else { b' ' });
        self.state = State::Reply;
    }

    fn handle_control(&mut self, line: &[u8]) -> Option<Event> {
        let decoded = std::str::from_utf8(line).ok()?;
        let mut text = self.bom_policy.apply(decoded);
        while let Some(rest) = text.strip_prefix('>') {
            text = rest.trim_matches(foundation_whitespace);
        }
        if text == "READY" {
            return Some(Event::Ready);
        }
        if let Some(caps) = text.strip_prefix("[caps] ") {
            return Some(Event::Capabilities(
                caps.split(' ')
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned)
                    .collect(),
            ));
        }
        if text.starts_with("PFX_OK ")
            && let Some(slot) = text.split(' ').filter(|s| !s.is_empty()).nth(1)
            && let Ok(slot) = slot.parse()
        {
            return Some(Event::PrefixReady(slot));
        }
        if text.starts_with("[perf] prefill") {
            self.state = State::Reply;
            self.reply.clear();
        } else if text.starts_with("[perf] generation") {
            let text = decode_stable_prefix_with_policy(&self.reply, self.bom_policy)
                .unwrap_or("")
                .trim_matches(foundation_whitespace_and_newline)
                .to_owned();
            self.reply.clear();
            return Some(Event::TurnComplete(text));
        }
        None
    }
}

pub(crate) fn foundation_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{00a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

pub(crate) fn foundation_whitespace_and_newline(c: char) -> bool {
    foundation_whitespace(c)
        || matches!(
            c,
            '\n' | '\r' | '\u{000b}' | '\u{000c}' | '\u{0085}' | '\u{2028}' | '\u{2029}'
        )
}

pub fn decode_stable_prefix(bytes: &[u8]) -> Option<&str> {
    decode_stable_prefix_with_policy(bytes, Utf8BomPolicy::StripLeading)
}

fn decode_stable_prefix_with_policy(bytes: &[u8], policy: Utf8BomPolicy) -> Option<&str> {
    if let Ok(text) = std::str::from_utf8(bytes) {
        return Some(policy.apply(text));
    }
    for back in 1..=3.min(bytes.len()) {
        if let Ok(text) = std::str::from_utf8(&bytes[..bytes.len() - back]) {
            return Some(policy.apply(text));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn foundation_bom_compatibility_is_explicit_and_never_strips_a_trailing_bom() {
        for policy in [Utf8BomPolicy::Preserve, Utf8BomPolicy::StripLeading] {
            let mut parser = TranslateStreamParser::with_bom_policy(true, policy);
            let bytes = "[perf] prefill\n\u{feff}한글\u{feff}\n[perf] generation\n";
            let events = parser.ingest(bytes.as_bytes());
            let expected = if policy == Utf8BomPolicy::Preserve {
                "\u{feff}한글\u{feff}"
            } else {
                "한글\u{feff}"
            };
            assert_eq!(events.last(), Some(&Event::TurnComplete(expected.into())));
        }
    }

    #[test]
    fn capabilities_prefix_and_split_unicode_stream() {
        let mut p = TranslateStreamParser::default();
        assert_eq!(
            p.ingest(b"[caps] fp max\nREADY\n>PFX_OK 2 40\n"),
            vec![
                Event::Capabilities(vec!["fp".into(), "max".into()]),
                Event::Ready,
                Event::PrefixReady(2)
            ]
        );
        assert!(p.ingest(b"[perf] prefill: 10 tok in 1ms\n").is_empty());
        assert!(p.ingest(&[0xea, 0xb0]).is_empty());
        assert_eq!(p.ingest(&[0x80]), vec![Event::ReplyDelta("가".into())]);
        assert_eq!(
            p.ingest(b"\n[perf] generation: 1 tok in 1ms\n> "),
            vec![Event::TurnComplete("가".into())]
        );
    }

    #[test]
    fn skipped_turn_does_not_wedge_the_next_turn() {
        let mut p = TranslateStreamParser::default();
        assert_eq!(
            p.ingest(b"> [warn] oversized input\n[perf] generation: 0 tok in 0ms\n> "),
            vec![Event::TurnComplete(String::new())]
        );
        assert_eq!(
            p.ingest(b"[chat] 1 tokens\n[perf] prefill: 1 tok\nHello\n[perf] generation: 1 tok\n"),
            vec![Event::TurnComplete("Hello".into())]
        );
    }

    #[test]
    fn newline_policy_and_every_marker_split() {
        for preserve in [false, true] {
            let stream = "[perf] prefill: 1 tok\n첫 줄\n둘째 줄\n[perf] generation: 2 tok\n";
            let expected = if preserve {
                "첫 줄\n둘째 줄"
            } else {
                "첫 줄 둘째 줄"
            };
            for split in 0..=stream.len() {
                let mut p = TranslateStreamParser::new(preserve);
                let mut events = p.ingest(&stream.as_bytes()[..split]);
                events.extend(p.ingest(&stream.as_bytes()[split..]));
                let completed: Vec<_> = events
                    .into_iter()
                    .filter(|e| matches!(e, Event::TurnComplete(_)))
                    .collect();
                assert_eq!(
                    completed,
                    vec![Event::TurnComplete(expected.into())],
                    "split {split}"
                );
            }
        }
    }

    #[test]
    fn invalid_utf8_is_not_silently_replaced() {
        assert_eq!(decode_stable_prefix(b"ok\xf0\x9f"), Some("ok"));
        assert_eq!(decode_stable_prefix(b"ok\xffmore"), None);
        assert_eq!(decode_stable_prefix(b"\xef\xbb\xbfhello"), Some("hello"));
    }
}
