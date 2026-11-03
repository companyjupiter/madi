//! Native transcript assembly and identity, ported from the shipping Swift store.
pub mod archive;
pub mod export;
mod line;
mod speakers;
mod store;
pub mod word_merger;
pub use line::{Line, SegmentStatus, text_revision};
use serde::{Deserialize, Serialize};
pub use speakers::{SpeakerNumbers, UNKNOWN_SPEAKER};
pub use store::{Features, TranscriptStore};
use uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Word {
    pub id: Uuid,
    pub t0: f64,
    pub t1: f64,
    pub text: String,
    pub conf: f64,
}
impl Word {
    pub fn new(t0: f64, t1: f64, text: String, conf: f64) -> Self {
        Self {
            id: Uuid::new_v4(),
            t0,
            t1,
            text,
            conf,
        }
    }
}

/// Foundation CharacterSet.whitespacesAndNewlines (includes U+200B, unlike
/// Unicode White_Space). Keep the original text itself unnormalized.
pub(crate) fn whitespace_and_newline(c: char) -> bool {
    matches!(c, '\u{9}'..='\u{d}' | '\u{20}' | '\u{85}' | '\u{a0}' | '\u{1680}' |
        '\u{2000}'..='\u{200b}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}')
}

pub fn trim_whitespace_and_newlines(text: &str) -> &str {
    text.trim_matches(whitespace_and_newline)
}

/// Swift's default lowercased() uses noncontextual scalar mappings. Rust's
/// str::to_lowercase applies the final-sigma rule (ΟΣ -> ος), which would turn
/// two distinct source seam keys into a duplicate. Keep οσ like the native oracle.
pub(crate) fn lowercase(text: &str) -> String {
    text.chars().flat_map(char::to_lowercase).collect()
}

pub(crate) fn whitespace(c: char) -> bool {
    whitespace_and_newline(c)
        && !matches!(
            c,
            '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
        )
}
