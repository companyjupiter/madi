//! Shipping ReviewController policy and TranscriptView's word presentation.
use crate::transcript::{Line, Uuid, whitespace};
use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
pub enum Command {
    Visibility { visible: bool },
    Toggle,
    Jump { delta: i64 },
    Stop,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Span {
    pub line_id: Uuid,
    pub word_index: usize,
    pub text: String,
    pub t0: f64,
    pub t1: f64,
}
pub fn queue<'a>(lines: impl IntoIterator<Item = &'a Line>, threshold: f64) -> Vec<Span> {
    lines
        .into_iter()
        .flat_map(|line| {
            line.words
                .iter()
                .enumerate()
                .filter_map(move |(word_index, word)| {
                    let text = word.text.trim_matches(whitespace);
                    (word.conf < threshold && !text.is_empty()).then(|| Span {
                        line_id: line.id,
                        word_index,
                        text: text.into(),
                        t0: word.t0,
                        t1: word.t1,
                    })
                })
        })
        .collect()
}
/// Attributed detail text uses word POSITION, not accumulated text length, when
/// adding spaces. That distinction matters after an empty first word.
pub fn word_spacing(line: &Line) -> Vec<bool> {
    line.words
        .iter()
        .enumerate()
        .map(|(i, word)| {
            i > 0
                && !matches!(
                    word.text.graphemes(true).next(),
                    Some("," | "." | "!" | "?" | "…")
                )
        })
        .collect()
}
pub fn wrapped(index: usize, delta: i64, count: usize) -> usize {
    if count == 0 {
        return 0;
    }
    ((index as i128 + i128::from(delta)).rem_euclid(count as i128)) as usize
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Controller {
    pub is_listening: bool,
    pub index: usize,
    pub queue: Vec<Span>,
}
impl Controller {
    pub fn refresh(&mut self, queue: Vec<Span>) {
        self.queue = queue;
        if self.queue.is_empty() {
            self.index = 0;
            self.is_listening = false;
        } else if self.index >= self.queue.len() {
            self.index = self.queue.len() - 1;
        }
    }
    pub fn current(&self) -> Option<&Span> {
        self.queue.get(self.index)
    }
    pub fn stop(&mut self) {
        self.is_listening = false;
    }
    pub fn toggle_listening(&mut self, can_play: bool) -> Option<Span> {
        if self.is_listening {
            self.stop();
            return None;
        }
        if !can_play || self.queue.is_empty() {
            return None;
        }
        self.is_listening = true;
        self.current().cloned()
    }
    pub fn manual_jump(&mut self, delta: i64) {
        self.stop();
        self.index = wrapped(self.index, delta, self.queue.len());
    }
    pub fn advance(&mut self) -> Option<Span> {
        if !self.is_listening {
            return None;
        }
        if self.queue.is_empty() || self.index >= self.queue.len() - 1 {
            self.stop();
            return None;
        }
        self.index += 1;
        self.current().cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn span(index: usize) -> Span {
        Span {
            line_id: Uuid::from_u128(1),
            word_index: index,
            text: format!("word {index}"),
            t0: index as f64,
            t1: index as f64 + 0.2,
        }
    }
    #[test]
    fn listening_is_gated_finishes_without_wrap_and_manual_jump_stops_it() {
        let mut c = Controller::default();
        assert!(c.toggle_listening(true).is_none());
        c.refresh(vec![span(0), span(1)]);
        assert!(c.toggle_listening(false).is_none());
        assert_eq!(c.toggle_listening(true), Some(span(0)));
        assert_eq!(c.advance(), Some(span(1)));
        assert_eq!(c.advance(), None);
        assert!(!c.is_listening);
        assert_eq!(c.index, 1);
        assert_eq!(c.toggle_listening(true), Some(span(1)));
        c.manual_jump(1);
        assert_eq!(c.index, 0);
        assert!(!c.is_listening);
        c.manual_jump(-1);
        assert_eq!(c.index, 1);
        c.refresh(vec![span(0)]);
        assert_eq!(c.index, 0);
        c.toggle_listening(true);
        c.refresh(vec![]);
        assert!(!c.is_listening);
        assert!(c.current().is_none());
    }
}
