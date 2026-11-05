//! WordMerger.swift overlap deduplication, held-word replacement and stable IDs.
use super::{Word, lowercase, whitespace_and_newline};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

pub struct WordMerger {
    pub eps: f64,
    committed: Vec<Word>,
    held: Option<Word>,
    emitted: f64,
    segment: Vec<Word>,
    pub seam_duplicates_dropped: u64,
    pub same_instant_duplicates_dropped: u64,
}
impl Default for WordMerger {
    fn default() -> Self {
        Self {
            eps: 0.05,
            committed: Vec::new(),
            held: None,
            emitted: 0.0,
            segment: Vec::new(),
            seam_duplicates_dropped: 0,
            same_instant_duplicates_dropped: 0,
        }
    }
}
impl WordMerger {
    pub fn committed(&self) -> &[Word] {
        &self.committed
    }
    pub fn held_word(&self) -> Option<&Word> {
        self.held.as_ref()
    }
    pub fn held_word_id(&self) -> Option<Uuid> {
        self.held.as_ref().map(|word| word.id)
    }
    pub fn committed_end(&self) -> f64 {
        self.emitted
    }
    pub fn add(&mut self, word: Word) {
        self.segment.push(word);
    }
    pub fn segment_break(&mut self) {
        self.merge(false);
    }
    pub fn finish(&mut self) {
        self.merge(true);
    }

    pub fn display_words(&self, from: usize) -> Vec<Word> {
        let mut out = self.committed[from.min(self.committed.len())..].to_vec();
        let mut live: Vec<_> = self
            .segment
            .iter()
            .filter(|word| word.t0 >= self.emitted - self.eps)
            .cloned()
            .collect();
        if let Some(held) = &self.held {
            if Self::replaces_held(held, &live, self.eps) {
                live.retain(|word| word.t1 > held.t0 + self.eps);
                if let Some(first) = live.first_mut() {
                    first.id = held.id;
                } else {
                    out.push(held.clone());
                }
            } else {
                out.push(held.clone());
            }
        }
        if out
            .last()
            .zip(live.first())
            .is_some_and(|(last, first)| Self::is_seam_duplicate(first, last))
        {
            live.remove(0);
        }
        out.extend(live);
        out
    }
    fn suffix_start(&self, since: f64) -> usize {
        let mut i = self.committed.len();
        while i > 0 && self.committed[i - 1].t0 >= since {
            i -= 1;
        }
        i
    }
    pub fn committed_since(&self, since: f64) -> &[Word] {
        &self.committed[self.suffix_start(since)..]
    }
    pub fn displayed_since(&self, since: f64) -> Vec<Word> {
        self.display_words(self.suffix_start(since))
            .into_iter()
            .filter(|word| word.t0 >= since)
            .collect()
    }
    pub fn is_tail_stub(word: &Word) -> bool {
        word.t1 - word.t0 < 0.06 && word.conf < 0.35
    }
    pub fn replaces_held(held: &Word, incoming: &[Word], eps: f64) -> bool {
        incoming.first().is_some_and(|first| {
            first.t0 <= held.t1 + eps || (Self::is_tail_stub(held) && first.t0 - held.t1 < 0.3)
        })
    }
    fn merge(&mut self, final_pass: bool) {
        let mut incoming: Vec<_> = std::mem::take(&mut self.segment)
            .into_iter()
            .filter(|word| word.t0 >= self.emitted - self.eps)
            .collect();
        if let Some(held) = self.held.take() {
            if !Self::replaces_held(&held, &incoming, self.eps) {
                self.commit(held);
            } else {
                incoming.retain(|word| word.t1 > held.t0 + self.eps);
                let Some(first) = incoming.first_mut() else {
                    // Preserve the source's all-stray early return, including
                    // final-pass behavior; a missing re-decode never erases ID.
                    self.held = Some(held);
                    return;
                };
                first.id = held.id;
            }
        }
        if incoming.is_empty() {
            return;
        }
        if self
            .committed
            .last()
            .is_some_and(|last| Self::is_seam_duplicate(&incoming[0], last))
        {
            self.seam_duplicates_dropped += 1;
            self.emitted = self.emitted.max(incoming[0].t1);
            incoming.remove(0);
        }
        if incoming.len() >= 2
            && Self::is_seam_duplicate(&incoming[1], &incoming[0])
            && (incoming[1].t1 - incoming[1].t0 < 0.12 || incoming[1].t0 < incoming[0].t1 - 0.05)
        {
            self.seam_duplicates_dropped += 1;
            incoming.remove(1);
        }
        if incoming.is_empty() {
            return;
        }
        if !final_pass {
            self.held = incoming.pop();
        }
        for word in incoming {
            self.commit(word);
        }
        if final_pass && let Some(held) = self.held.take() {
            self.commit(held);
        }
    }
    fn seam_key(word: &Word) -> String {
        // Swift Character.isLetter/isNumber inspect the first scalar of each
        // extended grapheme cluster; retaining whole clusters preserves marks.
        // https://github.com/swiftlang/swift/blob/main/stdlib/public/core/CharacterProperties.swift
        lowercase(&word.text)
            .graphemes(true)
            .filter(|cluster| {
                cluster
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_alphabetic() || c.is_numeric())
            })
            .collect::<String>()
            .nfc()
            .collect()
    }
    fn is_seam_duplicate(word: &Word, previous: &Word) -> bool {
        let key = Self::seam_key(word);
        !key.is_empty() && key == Self::seam_key(previous) && word.t0 - previous.t1 < 0.6
    }
    fn same_instant_duplicate(&self, word: &Word) -> bool {
        self.committed.last().is_some_and(|last| {
            let key = Self::seam_key(word);
            !key.is_empty() && key == Self::seam_key(last) && (word.t0 - last.t0).abs() < 0.1
        })
    }
    fn norm_word(word: &Word) -> String {
        lowercase(word.text.trim_matches(whitespace_and_newline))
            .nfc()
            .collect()
    }
    fn runaway_repeat(&self, word: &Word) -> bool {
        let mut history: Vec<_> = self.committed[self.committed.len().saturating_sub(30)..]
            .iter()
            .map(Self::norm_word)
            .collect();
        history.push(Self::norm_word(word));
        let n = history.len();
        for width in 1..=6 {
            if n < 2 * width {
                continue;
            }
            let mut repetitions = 1;
            let mut i = n - width;
            while i >= width && history[i - width..i] == history[i..i + width] {
                repetitions += 1;
                i -= width;
            }
            if repetitions > 4 {
                return true;
            }
        }
        false
    }
    fn commit(&mut self, word: Word) {
        if self.same_instant_duplicate(&word) {
            self.same_instant_duplicates_dropped += 1;
            self.emitted = self.emitted.max(word.t1);
            return;
        }
        if self.runaway_repeat(&word) {
            self.emitted = self.emitted.max(word.t1);
            return;
        }
        self.emitted = self.emitted.max(word.t1);
        self.committed.push(word);
    }
}
