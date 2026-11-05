//! SessionController's combined display pass and stable-line scan policy.
use crate::{
    glossary::Glossary,
    korean_numbers,
    personal_vocabulary::{canonically_equal, corrected_line_text},
    transcript::{Line, TranscriptStore, Uuid},
};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Default)]
pub struct TextPasses {
    user_edited: BTreeSet<Uuid>,
    // Retain the post-pass text, equivalent to the Swift hash gate without
    // introducing process-random hash values into portable state.
    stable_text: BTreeMap<Uuid, String>,
}
impl TextPasses {
    pub fn reset(&mut self) {
        *self = Self::default();
    }
    pub fn mark_user_edited(&mut self, id: Uuid) {
        self.user_edited.insert(id);
    }

    fn apply(&self, store: &mut TranscriptStore, line: &Line, glossary: Option<&Glossary>) {
        if self.user_edited.contains(&line.id) {
            return;
        }
        let before = line.text();
        let corrected = glossary.and_then(|value| corrected_line_text(line, value));
        let text = korean_numbers::format(corrected.as_deref().unwrap_or(&before));
        if !canonically_equal(&before, &text) {
            store.edit_line(line.id, &text, None);
        }
    }

    /// Finalization sweeps all lines even with no translation targets, and
    /// bypasses the stable cache so a newly enabled glossary can still apply.
    pub fn finalize(&self, store: &mut TranscriptStore, glossary: Option<&Glossary>) {
        for line in store.lines().to_vec() {
            self.apply(store, &line, glossary);
        }
    }

    /// This is the pre-translation part of translateStableLines. The tail is
    /// excluded, held-ending rows wait while preview is nonempty, and ordinary
    /// word events visit at most 32 rows. Translation itself remains separate.
    pub fn stable(
        &mut self,
        store: &mut TranscriptStore,
        glossary: Option<&Glossary>,
        translation_enabled: bool,
        partial: &str,
        including_last: bool,
    ) {
        if !translation_enabled {
            return;
        }
        let lines = store.lines();
        let mut end = if including_last {
            lines.len()
        } else {
            lines.len().saturating_sub(1)
        };
        if !including_last
            && !partial.is_empty()
            && let Some(held) = store.held_word()
            && let Some(index) = lines[..end]
                .iter()
                .rposition(|line| line.words.last().is_some_and(|word| word.id == held.id))
        {
            end = index;
        }
        let start = if including_last {
            0
        } else {
            end.saturating_sub(32)
        };
        // Release the store's immutable borrow before edit_line mutates it.
        let candidates = lines[start..end].to_vec();
        for line in candidates {
            let before = line.text();
            if self
                .stable_text
                .get(&line.id)
                .is_some_and(|text| canonically_equal(text, &before))
            {
                continue;
            }
            self.apply(store, &line, glossary);
            let after = store
                .lines()
                .iter()
                .find(|current| current.id == line.id)
                .map(Line::text)
                .unwrap_or(before);
            self.stable_text.insert(line.id, after);
        }
    }
}
