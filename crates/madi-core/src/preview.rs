//! Shipping PreviewEngine, PreviewTrim and InterimSourceGate policy. Provisional
//! words never enter TranscriptStore, exports, or archives.
use madi_protocol::transcribe::Event;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

fn whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}
fn words(text: &str) -> Vec<&str> {
    // Swift splits Character(" "), preserving tabs/newlines inside a word.
    let mut result = Vec::new();
    let mut start = 0;
    for (index, grapheme) in text.grapheme_indices(true) {
        if grapheme == " " {
            if start < index {
                result.push(&text[start..index]);
            }
            start = index + 1;
        }
    }
    if start < text.len() {
        result.push(&text[start..]);
    }
    result
}
fn equal(a: &str, b: &str) -> bool {
    a.nfc().eq(b.nfc())
}
fn strip_prefix<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let count = prefix.graphemes(true).count();
    let cut = text
        .grapheme_indices(true)
        .nth(count)
        .map_or(text.len(), |(i, _)| i);
    equal(&text[..cut], prefix).then_some(&text[cut..])
}
pub fn forced_prefix(committed: &[String], gate: &str) -> String {
    let joined = committed.join(" ");
    let base = joined.trim_matches(whitespace);
    let gate = gate.trim_matches(whitespace);
    if base.is_empty() || strip_prefix(gate, base).is_some_and(|tail| !tail.is_empty()) {
        gate.into()
    } else {
        base.into()
    }
}
pub fn trim_by_count(text: &str, count: usize) -> String {
    if count == 0 {
        return text.into();
    }
    words(text)
        .into_iter()
        .skip(count)
        .collect::<Vec<_>>()
        .join(" ")
}
pub fn visible_tail(words: &[String], forced: &str) -> String {
    let mut text = String::new();
    for word in words {
        if !text.is_empty()
            && !word
                .graphemes(true)
                .next()
                .is_some_and(|c| [",", ".", "!", "?", "…"].contains(&c))
        {
            text.push(' ');
        }
        text.push_str(word);
    }
    let forced = forced.trim_matches(whitespace);
    if forced.is_empty() {
        return text;
    }
    match strip_prefix(&text, forced) {
        Some(tail) => tail.trim_matches(whitespace).into(),
        None => trim_by_count(&text, self::words(forced).len()),
    }
}
pub fn bounded_partial(text: &str) -> bool {
    !text.is_empty() && text.graphemes(true).count() <= 512
}

#[derive(Debug)]
pub struct SourceGate {
    pub max_stall: usize,
    pub fast_first: bool,
    previous: Vec<String>,
    committed: Vec<String>,
    provisional: String,
    stall: usize,
}
impl Default for SourceGate {
    fn default() -> Self {
        Self {
            max_stall: 3,
            fast_first: true,
            previous: Vec::new(),
            committed: Vec::new(),
            provisional: String::new(),
            stall: 0,
        }
    }
}
impl SourceGate {
    pub fn commit(&mut self, hypothesis: &str) -> String {
        let current: Vec<String> = words(hypothesis).into_iter().map(str::to_owned).collect();
        if self.previous.is_empty() {
            if self.fast_first {
                self.provisional = hypothesis.into();
            }
            self.previous = current;
            return self.provisional.clone();
        }
        let norm = |word: &str| {
            word.trim_matches(|c| " ,.!?…\"'".contains(c))
                .to_lowercase()
        };
        let agreed = self
            .previous
            .iter()
            .zip(&current)
            .take_while(|(a, b)| equal(&norm(a), &norm(b)))
            .count();
        if agreed > self.committed.len() {
            self.committed
                .extend_from_slice(&current[self.committed.len()..agreed]);
            self.stall = 0;
        } else {
            self.stall += 1;
            if self.stall >= self.max_stall && current.len() > self.committed.len() {
                self.committed
                    .extend_from_slice(&current[self.committed.len()..]);
                self.stall = 0;
            }
        }
        self.previous = current;
        if self.committed.is_empty() {
            self.provisional.clone()
        } else {
            self.provisional.clear();
            self.committed_text()
        }
    }
    pub fn committed_text(&self) -> String {
        self.committed.join(" ")
    }
    pub fn reset(&mut self) {
        self.previous.clear();
        self.committed.clear();
        self.provisional.clear();
        self.stall = 0;
    }
}

/// Latest-only scheduling. A native owner admits the returned job atomically
/// against its committed queue; a rejected admission is put back with retry().
pub struct Scheduler<T> {
    started: bool,
    admitted: bool,
    in_flight: bool,
    latest: Option<(T, f64)>,
    building: Vec<String>,
    forced: String,
}
impl<T> Default for Scheduler<T> {
    fn default() -> Self {
        Self {
            started: false,
            admitted: true,
            in_flight: false,
            latest: None,
            building: Vec::new(),
            forced: String::new(),
        }
    }
}
impl<T> Scheduler<T> {
    pub fn start(&mut self) {
        self.started = true;
    }
    pub fn feed(&mut self, wav: T, offset: f64) {
        if self.started {
            self.latest = Some((wav, offset));
        }
    }
    pub fn set_admitted(&mut self, admitted: bool) {
        self.admitted = admitted;
    }
    pub fn take_ready(&mut self) -> Option<(T, f64)> {
        if !self.started || !self.admitted || self.in_flight {
            return None;
        }
        let job = self.latest.take()?;
        self.in_flight = true;
        self.building.clear();
        self.forced.clear();
        Some(job)
    }
    pub fn submitted(&mut self, forced: String) {
        self.forced = forced;
    }
    pub fn retry(&mut self, job: (T, f64)) {
        self.in_flight = false;
        self.latest = Some(job);
    }
    pub fn stop(&mut self) {
        self.started = false;
        self.admitted = true;
        self.in_flight = false;
        self.latest = None;
        self.building.clear();
    }
    /// None = committed event. Some(None) = consumed preview control/word.
    /// Some(Some(text)) = completed preview, ready for the 512-character gate.
    pub fn consume(&mut self, event: &Event) -> Option<Option<String>> {
        match event {
            Event::PreviewBegin => self.building.clear(),
            Event::PreviewWord { text, .. } => {
                let text = text.trim_matches(whitespace);
                if !text.is_empty() {
                    self.building.push(text.into());
                }
            }
            Event::PreviewPartial(_) => (),
            Event::PreviewEnd => {
                let text =
                    (!self.building.is_empty()).then(|| visible_tail(&self.building, &self.forced));
                self.building.clear();
                self.in_flight = false;
                return Some(text);
            }
            _ => return None,
        }
        Some(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn provisional_opening_is_not_a_forced_prefix_and_stall_escape_resets() {
        let mut gate = SourceGate::default();
        assert_eq!(
            gate.commit("Hello. today is cloud"),
            "Hello. today is cloud"
        );
        assert_eq!(gate.committed_text(), "");
        assert_eq!(gate.commit("hello today is clear"), "hello today is");
        for text in ["new one", "new two", "new three four five"] {
            gate.commit(text);
        }
        assert_eq!(gate.committed_text(), "hello today is five");
        gate.reset();
        assert_eq!(gate.committed_text(), "");
    }
    #[test]
    fn only_latest_admitted_preview_is_decoded_and_never_consumes_commit_events() {
        let mut lane = Scheduler::default();
        lane.feed(0, 0.);
        lane.start();
        assert!(lane.take_ready().is_none());
        lane.set_admitted(false);
        lane.feed(1, 1.);
        lane.feed(2, 2.);
        assert!(lane.take_ready().is_none());
        lane.set_admitted(true);
        assert_eq!(lane.take_ready(), Some((2, 2.)));
        lane.submitted("kept".into());
        lane.feed(3, 3.);
        lane.feed(4, 4.);
        assert!(lane.take_ready().is_none());
        assert_eq!(lane.consume(&Event::SegmentEnd), None);
        lane.consume(&Event::PreviewWord {
            t0: 0.,
            t1: 0.1,
            text: "kept".into(),
        });
        lane.consume(&Event::PreviewWord {
            t0: 0.2,
            t1: 0.3,
            text: "new".into(),
        });
        assert_eq!(lane.consume(&Event::PreviewEnd), Some(Some("new".into())));
        assert_eq!(lane.take_ready(), Some((4, 4.)));
        lane.stop();
        assert!(lane.take_ready().is_none());
    }
}
