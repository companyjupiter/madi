use super::{
    Line, SpeakerNumbers, UNKNOWN_SPEAKER, Word, lowercase, text_revision, whitespace,
    whitespace_and_newline, word_merger::WordMerger,
};
use madi_protocol::transcribe::{Event, SpeakerLabel};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;
mod grouping;

#[derive(Clone, Debug)]
pub struct Features {
    pub join_same_speaker_neighbors: bool,
    pub settled_ledger: bool,
    pub turn_head_adoption: bool,
    pub speaker_island_absorption: bool,
    pub weak_label_continuation: f64,
    pub min_seconds_to_number: f64,
}
impl Default for Features {
    fn default() -> Self {
        Self {
            join_same_speaker_neighbors: true,
            settled_ledger: true,
            turn_head_adoption: true,
            speaker_island_absorption: false,
            weak_label_continuation: 0.0,
            min_seconds_to_number: 10.0,
        }
    }
}
impl Features {
    pub fn for_language(token: Option<u32>) -> Self {
        let selected_non_english = token.is_some_and(|token| token != 50259);
        Self {
            speaker_island_absorption: selected_non_english,
            weak_label_continuation: if selected_non_english { 0.2 } else { 0.0 },
            ..Self::default()
        }
    }
}
#[derive(Clone)]
struct TranslationRecord {
    text: String,
    source_revision: u64,
    user_edited: bool,
}

/// Synchronous source-of-truth model. The host schedules pending display and
/// speaker-fix work at the original 33/50 ms cadence, then publishes snapshots.
pub struct TranscriptStore {
    pub features: Features,
    lines: Vec<Line>,
    display_lines: Vec<Line>,
    pub display_revision: u64,
    pub render_pending: bool,
    pub speaker_fix_pending: bool,
    pub speaker_numbers: SpeakerNumbers,
    merger: WordMerger,
    speakers: Vec<SpeakerLabel>,
    fixes: Vec<SpeakerLabel>,
    overlaps: Vec<SpeakerLabel>,
    lookup: Option<Arc<LabelLookup>>,
    frozen_count: usize,
    frozen_word_count: usize,
    break_decided: BTreeSet<Uuid>,
    break_after: BTreeSet<Uuid>,
    translations: BTreeMap<Uuid, BTreeMap<String, TranslationRecord>>,
    edits: BTreeMap<Uuid, String>,
    edited_row_words: BTreeMap<Uuid, BTreeSet<Uuid>>,
    sentence_breaks: BTreeSet<Uuid>,
    suppressed: BTreeMap<Uuid, BTreeMap<String, u64>>,
    speaker_merges: BTreeMap<i64, i64>,
    speaker_overrides: BTreeMap<Uuid, i64>,
    finalized: bool,
    namespace_broken: bool,
    pub same_speaker_joins: u64,
    pub speaker_fix_rebuilds: u64,
    pub island_absorptions: u64,
    pub weak_label_continuations: u64,
}
impl Default for TranscriptStore {
    fn default() -> Self {
        Self::new(Features::default())
    }
}
impl TranscriptStore {
    pub fn new(features: Features) -> Self {
        Self {
            features,
            lines: Vec::new(),
            display_lines: Vec::new(),
            display_revision: 0,
            render_pending: false,
            speaker_fix_pending: false,
            speaker_numbers: SpeakerNumbers::default(),
            merger: WordMerger::default(),
            speakers: Vec::new(),
            fixes: Vec::new(),
            overlaps: Vec::new(),
            lookup: None,
            frozen_count: 0,
            frozen_word_count: 0,
            break_decided: BTreeSet::new(),
            break_after: BTreeSet::new(),
            translations: BTreeMap::new(),
            edits: BTreeMap::new(),
            edited_row_words: BTreeMap::new(),
            sentence_breaks: BTreeSet::new(),
            suppressed: BTreeMap::new(),
            speaker_merges: BTreeMap::new(),
            speaker_overrides: BTreeMap::new(),
            finalized: false,
            namespace_broken: false,
            same_speaker_joins: 0,
            speaker_fix_rebuilds: 0,
            island_absorptions: 0,
            weak_label_continuations: 0,
        }
    }
    pub fn lines(&self) -> &[Line] {
        &self.lines
    }
    pub fn display_lines(&self) -> &[Line] {
        &self.display_lines
    }
    pub fn flush_render(&mut self) {
        self.render_pending = false;
        self.flush_display_now();
    }
    fn flush_display_now(&mut self) {
        self.display_lines.clone_from(&self.lines);
        self.display_revision = self.display_revision.wrapping_add(1);
    }
    pub fn reset(&mut self) {
        self.lines.clear();
        self.merger = WordMerger::default();
        self.speakers.clear();
        self.fixes.clear();
        self.overlaps.clear();
        self.lookup = None;
        self.translations.clear();
        self.edits.clear();
        self.edited_row_words.clear();
        self.suppressed.clear();
        self.sentence_breaks.clear();
        self.break_decided.clear();
        self.break_after.clear();
        self.speaker_merges.clear();
        self.speaker_overrides.clear();
        self.speaker_numbers.reset();
        self.frozen_count = 0;
        self.frozen_word_count = 0;
        self.finalized = false;
        self.namespace_broken = false;
        self.flush_display_now();
    }
    pub fn load(&mut self, lines: Vec<Line>) {
        self.reset();
        self.lines = lines;
        self.speaker_numbers
            .assign_all(self.lines.iter().map(|line| line.speaker));
        for line in &self.lines {
            if !line.translations.is_empty() {
                let revision = text_revision(&line.text());
                self.translations.insert(
                    line.id,
                    line.translations
                        .iter()
                        .map(|(lang, text)| {
                            (
                                lang.clone(),
                                TranslationRecord {
                                    text: text.clone(),
                                    source_revision: revision,
                                    user_edited: true,
                                },
                            )
                        })
                        .collect(),
                );
            }
        }
        self.flush_display_now();
    }
    pub fn held_word(&self) -> Option<&Word> {
        self.merger.held_word()
    }
    pub fn committed_end(&self) -> f64 {
        self.merger.committed_end()
    }
    pub fn committed_words(&self, since: f64) -> &[Word] {
        self.merger.committed_since(since)
    }
    pub fn displayed_words(&self, since: f64) -> Vec<Word> {
        self.merger.displayed_since(since)
    }
    pub fn mark_diar_namespace_broken(&mut self) {
        self.namespace_broken = true;
    }
    pub fn source_revision(&self, id: Uuid) -> Option<u64> {
        self.lines
            .iter()
            .find(|line| line.id == id)
            .map(|line| text_revision(&line.text()))
    }
    pub fn set_translation(
        &mut self,
        id: Uuid,
        lang: String,
        text: &str,
        source_revision: Option<u64>,
        user_edited: bool,
    ) -> bool {
        let Some(index) = self.lines.iter().position(|line| line.id == id) else {
            return false;
        };
        let current = text_revision(&self.lines[index].text());
        if source_revision.is_some_and(|revision| revision != current) {
            return false;
        }
        let text = text.trim_matches(whitespace_and_newline);
        if text.is_empty() {
            return false;
        }
        self.translations.entry(id).or_default().insert(
            lang.clone(),
            TranslationRecord {
                text: text.into(),
                source_revision: current,
                user_edited,
            },
        );
        let line = &mut self.lines[index];
        line.translations.insert(lang.clone(), text.into());
        line.stale_translations.remove(&lang);
        if user_edited {
            line.edited_translations.insert(lang);
        } else {
            line.edited_translations.remove(&lang);
        }
        self.render_pending = true;
        true
    }
    pub fn suppress_translation(
        &mut self,
        id: Uuid,
        lang: String,
        source_revision: Option<u64>,
    ) -> bool {
        let Some(index) = self.lines.iter().position(|line| line.id == id) else {
            return false;
        };
        let current = text_revision(&self.lines[index].text());
        if source_revision.is_some_and(|revision| revision != current)
            || self
                .translations
                .get(&id)
                .and_then(|records| records.get(&lang))
                .is_some_and(|record| record.user_edited)
        {
            return false;
        }
        if let Some(records) = self.translations.get_mut(&id)
            && records.remove(&lang).is_some()
        {
            self.lines[index].translations.remove(&lang);
        }
        self.suppressed
            .entry(id)
            .or_default()
            .insert(lang.clone(), current);
        self.lines[index].suppressed_translations.insert(lang);
        self.render_pending = true;
        true
    }
    pub fn valid_translation_languages(&self, id: Uuid, source_revision: u64) -> BTreeSet<String> {
        self.translations
            .get(&id)
            .into_iter()
            .flat_map(|records| records.iter())
            .filter(|(_, record)| record.source_revision == source_revision)
            .map(|(lang, _)| lang.clone())
            .collect()
    }
    pub fn prune_translations(
        &mut self,
        id: Uuid,
        targets: &BTreeSet<String>,
        source_revision: u64,
    ) -> BTreeSet<String> {
        if let Some(records) = self.translations.get_mut(&id) {
            let count = records.len();
            records.retain(|lang, _| targets.contains(lang));
            if records.len() != count {
                if let Some(index) = self.lines.iter().position(|line| line.id == id) {
                    self.refresh_translation_overlay(index);
                }
                self.render_pending = true;
            }
        }
        self.valid_translation_languages(id, source_revision)
    }
    pub fn cosmetically_equal(a: &str, b: &str) -> bool {
        fn form(text: &str) -> String {
            lowercase(text)
                .chars()
                .filter(|c| !whitespace_and_newline(*c))
                .collect::<String>()
                .graphemes(true)
                .filter(|cluster| {
                    !",.!?…。、·:;'\"“”‘’()–—-«»"
                        .graphemes(true)
                        .any(|punctuation| punctuation == *cluster)
                })
                .collect::<String>()
                .nfc()
                .collect()
        }
        form(a) == form(b)
    }
    fn rebind_translations(&mut self, index: usize) {
        let id = self.lines[index].id;
        let revision = text_revision(&self.lines[index].text());
        if let Some(records) = self.translations.get_mut(&id) {
            for record in records.values_mut() {
                record.source_revision = revision;
            }
        }
        if let Some(verdicts) = self.suppressed.get_mut(&id) {
            for verdict in verdicts.values_mut() {
                *verdict = revision;
            }
        }
    }
    pub fn edit_line(&mut self, id: Uuid, text: &str, expected_revision: Option<u64>) -> bool {
        let text = text.trim_matches(whitespace_and_newline);
        if text.is_empty() {
            return false;
        }
        let Some(index) = self.lines.iter().position(|line| line.id == id) else {
            return false;
        };
        let before = self.lines[index].text();
        if expected_revision.is_some_and(|revision| revision != text_revision(&before)) {
            return false;
        }
        if before.nfc().eq(text.nfc()) {
            return true;
        }
        let cosmetic = Self::cosmetically_equal(&before, text);
        self.edits.insert(id, text.into());
        self.edited_row_words.insert(
            id,
            self.lines[index].words.iter().map(|word| word.id).collect(),
        );
        self.lines[index].edited_text = Some(text.into());
        if cosmetic {
            self.rebind_translations(index);
        }
        self.refresh_translation_overlay(index);
        self.render_pending = true;
        true
    }
    pub fn edit_word(&mut self, id: Uuid, word_index: usize, text: &str) -> bool {
        let Some(index) = self.lines.iter().position(|line| line.id == id) else {
            return false;
        };
        let text = text.trim_matches(whitespace);
        if text.is_empty() || word_index >= self.lines[index].words.len() {
            return false;
        }
        let before = self.lines[index].text();
        self.lines[index].words[word_index].text = text.into();
        self.lines[index].words[word_index].conf = 1.0;
        let after = self.lines[index].joined_text();
        self.lines[index].edited_text = Some(after.clone());
        self.edits.insert(id, after.clone());
        self.edited_row_words.insert(
            id,
            self.lines[index].words.iter().map(|word| word.id).collect(),
        );
        if Self::cosmetically_equal(&before, &after) {
            self.rebind_translations(index);
        }
        self.refresh_translation_overlay(index);
        self.render_pending = true;
        true
    }
    fn refresh_translation_overlay(&mut self, index: usize) {
        let line = &mut self.lines[index];
        let revision = text_revision(&line.text());
        line.translations.clear();
        line.stale_translations.clear();
        line.edited_translations.clear();
        if let Some(records) = self.translations.get(&line.id) {
            for (lang, record) in records {
                if record.source_revision == revision {
                    line.translations.insert(lang.clone(), record.text.clone());
                    if record.user_edited {
                        line.edited_translations.insert(lang.clone());
                    }
                } else {
                    line.stale_translations
                        .insert(lang.clone(), record.text.clone());
                }
            }
        }
        line.suppressed_translations = self
            .suppressed
            .get(&line.id)
            .into_iter()
            .flat_map(|records| records.iter())
            .filter(|(_, rev)| **rev == revision)
            .map(|(lang, _)| lang.clone())
            .collect();
    }
    fn resolved_speaker(&self, speaker: i64) -> i64 {
        let mut current = speaker;
        let mut seen = BTreeSet::new();
        while let Some(next) = self.speaker_merges.get(&current) {
            if !seen.insert(current) || *next == current {
                break;
            }
            current = *next;
        }
        current
    }
    pub fn merge_speaker(&mut self, from: i64, into: i64) {
        if from == into {
            return;
        }
        let target = self.resolved_speaker(into);
        self.speaker_merges.insert(from, target);
        let sources: Vec<_> = self
            .speaker_merges
            .iter()
            .filter(|(_, destination)| self.resolved_speaker(**destination) == target)
            .map(|(source, _)| *source)
            .collect();
        for source in sources {
            self.speaker_merges.insert(source, target);
        }
        self.speaker_numbers.merge(from, target);
        self.apply_speaker_overlays(0);
        self.join_same_speaker_neighbors();
    }
    pub fn relabel_speaker(&mut self, id: Uuid, speaker: i64) {
        self.speaker_overrides.insert(id, speaker);
        self.apply_speaker_overlays(0);
        self.join_same_speaker_neighbors();
    }
    pub fn has_speaker_corrections(&self) -> bool {
        !self.speaker_merges.is_empty() || !self.speaker_overrides.is_empty()
    }
    pub fn revert_speaker_corrections(&mut self) {
        self.speaker_merges.clear();
        self.speaker_overrides.clear();
        self.rebuild_from_current_labels();
    }
    fn apply_speaker_overlays(&mut self, from: usize) {
        for index in from..self.lines.len() {
            let speaker = self
                .speaker_overrides
                .get(&self.lines[index].id)
                .copied()
                .unwrap_or(self.lines[index].speaker);
            self.lines[index].speaker = self.resolved_speaker(speaker);
        }
        self.render_pending = true;
    }
    fn apply_overlays(&mut self, from: usize) {
        if from >= self.lines.len() {
            return;
        }
        for index in from..self.lines.len() {
            if let Some(edit) = self.edits.get(&self.lines[index].id) {
                self.lines[index].edited_text = Some(edit.clone());
            }
            self.refresh_translation_overlay(index);
        }
        self.apply_speaker_overlays(from);
    }
    pub fn ingest(&mut self, event: &Event) {
        match event {
            Event::WordSectionBegin => {
                self.merger.segment_break();
                self.rebuild_live();
            }
            Event::Word {
                t0,
                t1,
                text,
                confidence,
            } => self.ingest_word(Word::new(*t0, *t1, text.clone(), *confidence)),
            Event::Speaker(label) => {
                self.speakers.push(label.clone());
                self.lookup = None;
                self.rebuild_live();
            }
            Event::SpeakerFix(label) => {
                self.fixes.push(label.clone());
                let mut touched = false;
                for old in &mut self.speakers {
                    if (old.time - label.time).abs() < 0.11 {
                        old.id = label.id;
                        old.margin = label.margin;
                        touched = true;
                    }
                }
                if touched {
                    self.lookup = None;
                    self.speaker_fix_pending = true;
                }
            }
            Event::SpeakerOverlap(label) => {
                self.overlaps.push(label.clone());
                self.apply_overlaps(0);
                self.render_pending = true;
            }
            Event::SpeakerOverlapReset => {
                self.overlaps.clear();
                self.apply_overlaps(0);
                self.render_pending = true;
            }
            _ => (),
        }
    }
    pub fn ingest_word(&mut self, word: Word) {
        self.merger.add(word);
        self.rebuild_live();
    }
    pub fn flush_pending_speaker_fix_rebuild(&mut self) {
        if !self.speaker_fix_pending {
            return;
        }
        self.speaker_fix_pending = false;
        self.speaker_fix_rebuilds += 1;
        self.lookup = None;
        self.reassign_frozen_speakers();
        self.rebuild_from_current_labels();
        self.join_same_speaker_neighbors();
    }
    fn rebuild_from_current_labels(&mut self) {
        if self.finalized {
            self.finalize();
        } else {
            self.rebuild_live();
        }
    }
    fn apply_overlaps(&mut self, from: usize) {
        for line in self.lines.iter_mut().skip(from) {
            line.overlap_speakers.clear();
            for label in &self.overlaps {
                if label.id != line.speaker
                    && label.time + label.duration > line.start
                    && label.time < line.end
                    && !line.overlap_speakers.contains(&label.id)
                {
                    line.overlap_speakers.push(label.id);
                }
            }
        }
    }
}

#[derive(Clone)]
struct LabelLookup {
    sorted: Vec<SpeakerLabel>,
    max_duration: f64,
}
impl LabelLookup {
    fn new(labels: &[SpeakerLabel]) -> Self {
        let mut sorted = labels.to_vec();
        sorted.sort_by(|a, b| {
            a.time
                .partial_cmp(&b.time)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        Self {
            sorted,
            max_duration: labels
                .iter()
                .fold(0.0_f64, |duration, label| duration.max(label.duration)),
        }
    }
    fn at(&self, time: f64) -> (i64, f64) {
        if self.sorted.is_empty() {
            return (0, 1.0);
        }
        let insertion = self.sorted.partition_point(|label| label.time <= time);
        let mut containing = None;
        for label in self.sorted[..insertion].iter().rev() {
            if time - label.time > self.max_duration {
                break;
            }
            if time >= label.time && time <= label.time + label.duration {
                containing = Some(label);
            }
        }
        if let Some(label) = containing {
            return (label.id, label.margin);
        }
        let mut best = insertion.min(self.sorted.len() - 1);
        if insertion > 0
            && (self.sorted[insertion - 1].time - time).abs()
                < (self.sorted[best].time - time).abs()
        {
            best = insertion - 1;
        }
        (self.sorted[best].id, 1.0)
    }
}
