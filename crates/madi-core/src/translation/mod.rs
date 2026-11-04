//! Shipping translation queue, prompt and response policies. Transcript revision
//! acceptance remains the session owner's responsibility.
pub mod cache;
pub mod client;
pub mod committed;
pub mod output;
use crate::{
    personal_vocabulary::canonically_equal as equal,
    transcript::{Uuid, lowercase},
};
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Interim,
    #[default]
    Committed,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Turn {
    pub id: Uuid,
    pub lang: String,
    pub source: String,
    pub prompt: String,
    pub prefix: Option<String>,
    pub body: Option<String>,
    pub retries: i64,
    pub kind: Kind,
    #[serde(default)]
    pub reserved: bool,
    pub forced: Option<String>,
    pub example_target: Option<String>,
    pub example_source: Option<String>,
}

#[derive(Default, Debug)]
pub struct Queue {
    pub turns: Vec<Turn>,
}
#[derive(Debug, Serialize)]
pub struct Enqueued {
    pub accepted: bool,
    pub displaced: Vec<Turn>,
}
impl Queue {
    pub fn has_committed(&self) -> bool {
        self.turns.iter().any(|t| t.kind == Kind::Committed)
    }
    fn remove(&mut self, predicate: impl Fn(&Turn) -> bool) -> Vec<Turn> {
        let mut removed = Vec::new();
        let mut kept = Vec::new();
        for turn in self.turns.drain(..) {
            if predicate(&turn) {
                removed.push(turn);
            } else {
                kept.push(turn);
            }
        }
        self.turns = kept;
        removed
    }
    pub fn enqueue(&mut self, turn: Turn, block_interim: bool, replace_existing: bool) -> Enqueued {
        if turn.kind == Kind::Interim && !turn.reserved && (block_interim || self.has_committed()) {
            return Enqueued {
                accepted: false,
                displaced: Vec::new(),
            };
        }
        let mut displaced = if turn.kind == Kind::Committed {
            self.remove(|t| t.kind == Kind::Interim && !t.reserved)
        } else {
            Vec::new()
        };
        if !replace_existing
            && self
                .turns
                .iter()
                .any(|t| t.id == turn.id && equal(&t.lang, &turn.lang))
        {
            return Enqueued {
                accepted: false,
                displaced,
            };
        }
        displaced.extend(self.remove(|t| t.id == turn.id && equal(&t.lang, &turn.lang)));
        self.turns.push(turn);
        Enqueued {
            accepted: true,
            displaced,
        }
    }
    fn next_index(&self) -> Option<usize> {
        self.turns
            .iter()
            .rposition(|t| t.reserved)
            .or_else(|| self.turns.iter().rposition(|t| t.kind == Kind::Committed))
            .or_else(|| self.turns.len().checked_sub(1))
    }
    pub fn next(&self) -> Option<&Turn> {
        self.next_index().map(|i| &self.turns[i])
    }
    pub fn pop_next(&mut self) -> Option<Turn> {
        self.next_index().map(|i| self.turns.remove(i))
    }
    pub fn shed_oldest(&mut self, cap: usize) -> Vec<Turn> {
        if cap == 0 || self.turns.len() <= cap {
            Vec::new()
        } else {
            self.turns.drain(..self.turns.len() - cap).collect()
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct Example {
    pub source: String,
    pub target: String,
}
pub fn count(text: &str) -> usize {
    text.graphemes(true).count()
}
pub fn prefix(text: &str, length: usize) -> String {
    text.graphemes(true).take(length).collect()
}
pub fn canonical(text: &str) -> String {
    text.nfc().collect()
}
pub fn starts_with(text: &str, start: &str) -> bool {
    equal(&prefix(text, count(start)), start)
}

/// Swift Character properties classify the leading scalar of a grapheme. The
/// complete grapheme remains its comparison key, including combining marks.
pub fn letter_or_number(character: &str) -> bool {
    character
        .chars()
        .next()
        .is_some_and(|c| c.is_alphabetic() || c.is_numeric())
}
fn revision_key(text: &str) -> String {
    lowercase(text)
        .graphemes(true)
        .filter(|c| letter_or_number(c))
        .collect()
}
pub fn usable_example(example: Option<&Example>, text: &str, max_chars: usize) -> Option<Example> {
    let ex = example?;
    if ex.source.is_empty()
        || ex.target.is_empty()
        || count(&ex.source) > max_chars
        || count(&ex.target) > max_chars
        || ex.source.contains('\n')
        || ex.target.contains('\n')
        || equal(&ex.source, text)
    {
        return None;
    }
    let a = revision_key(&ex.source);
    let b = revision_key(text);
    if starts_with(&a, &b) || starts_with(&b, &a) {
        None
    } else {
        Some(ex.clone())
    }
}
pub fn body(text: &str, example: Option<&Example>, anchor: &str) -> String {
    let example = example.map_or_else(
        || format!("Hello => {anchor}"),
        |e| format!("{} => {}", e.source, e.target),
    );
    format!("{example} . {text} =>")
}
pub fn committed_targets(
    requested: &[String],
    priority: Option<&str>,
    backlog: usize,
    threshold: usize,
) -> (Vec<String>, Vec<String>) {
    if threshold > 0
        && backlog >= threshold
        && requested.len() > 1
        && let Some(p) = priority
        && requested.iter().any(|t| equal(t, p))
    {
        return (
            vec![p.into()],
            requested.iter().filter(|t| !equal(t, p)).cloned().collect(),
        );
    }
    (requested.to_vec(), Vec::new())
}
pub fn adaptive_guarantee(base: f64, backlog: usize) -> Option<f64> {
    if base.is_nan() || base <= 0.0 {
        None
    } else if backlog <= 2 {
        Some(base)
    } else if backlog <= 6 {
        Some(base * 2.0)
    } else {
        None
    }
}
