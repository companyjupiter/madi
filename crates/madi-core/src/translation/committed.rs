//! Committed-line scheduling from SessionController. The host owns the clock,
//! model admission and transport; this owner binds callbacks to source revisions.
use super::client::Effect;
use crate::{
    personal_vocabulary::canonically_equal,
    transcript::{Line, SpeakerNumbers, TranscriptStore, Uuid, text_revision, whitespace},
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use unicode_segmentation::UnicodeSegmentation;
#[cfg(test)]
mod tests;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Input {
    pub id: Uuid,
    pub speaker: i64,
    pub text: String,
    pub start: f64,
    pub end: f64,
    pub undecided: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Run {
    pub anchor: Uuid,
    pub members: Vec<Uuid>,
    pub text: String,
}
pub fn ends_sentence(text: &str) -> bool {
    text.trim_matches(whitespace)
        .graphemes(true)
        .next_back()
        .is_some_and(|last| ".?!。？！…".graphemes(true).any(|ch| ch == last))
}
pub fn is_fragment(text: &str, max_words: usize, soft_max_words: usize) -> bool {
    let mut in_word = false;
    let mut words = 0;
    for ch in text.graphemes(true) {
        if ch == " " || ch == "\n" {
            in_word = false;
        } else if !in_word {
            words += 1;
            in_word = true;
        }
    }
    words == 0 || words <= max_words || (words < soft_max_words && !ends_sentence(text))
}
pub fn runs(lines: &[Input], max_gap: f64, defer_trailing: bool) -> Vec<Run> {
    let mut out = Vec::new();
    let mut pending: Vec<&Input> = Vec::new();
    fn flush(pending: &mut Vec<&Input>, out: &mut Vec<Run>) {
        out.extend(pending.drain(..).map(|p| Run {
            anchor: p.id,
            members: Vec::new(),
            text: p.text.clone(),
        }));
    }
    for line in lines {
        if pending.last().is_some_and(|previous| {
            let joinable =
                (previous.undecided || line.undecided || previous.speaker == line.speaker)
                    && line.start - previous.end <= max_gap;
            !joinable
        }) {
            flush(&mut pending, &mut out);
        }
        let size: usize = pending
            .iter()
            .map(|p| p.text.graphemes(true).count() + 1)
            .sum();
        if size + line.text.graphemes(true).count() > 220 {
            flush(&mut pending, &mut out);
        }
        if is_fragment(&line.text, 2, 3) {
            pending.push(line);
        } else {
            let mut parts: Vec<&str> = pending.iter().map(|p| p.text.as_str()).collect();
            parts.push(&line.text);
            out.push(Run {
                anchor: line.id,
                members: pending.iter().map(|p| p.id).collect(),
                text: parts.join(" "),
            });
            pending.clear();
        }
    }
    if !defer_trailing {
        flush(&mut pending, &mut out);
    }
    out
}
pub fn script_language(text: &str) -> Option<&'static str> {
    let (mut hangul, mut kana, mut han, mut latin) = (0, 0, 0, 0);
    for ch in text.chars() {
        match ch as u32 {
            0xac00..=0xd7af | 0x1100..=0x11ff | 0x3130..=0x318f => hangul += 1,
            0x3040..=0x309f | 0x30a0..=0x30ff | 0x31f0..=0x31ff => kana += 1,
            0x4e00..=0x9fff | 0x3400..=0x4dbf => han += 1,
            0x41..=0x5a | 0x61..=0x7a => latin += 1,
            _ => (),
        }
    }
    if kana > 0 {
        Some("Japanese")
    } else if hangul > 0 && hangul >= han {
        Some("Korean")
    } else if han > 0 {
        Some("Chinese")
    } else if latin * 2 > hangul + kana + han + latin {
        Some("English")
    } else {
        None
    }
}
pub fn targets(text: &str, selected: &[String], language_token: Option<i64>) -> BTreeSet<String> {
    let source = script_language(text).or(match language_token {
        Some(50264) => Some("Korean"),
        Some(50259) => Some("English"),
        Some(50266) => Some("Japanese"),
        Some(50260) => Some("Chinese"),
        _ => None,
    });
    selected
        .iter()
        .filter(|lang| source != Some(lang.as_str()))
        .cloned()
        .collect()
}
#[derive(Clone, Debug)]
pub struct Request {
    pub id: Uuid,
    pub text: String,
    pub targets: Vec<String>,
    pub cacheable: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Key {
    id: Uuid,
    language: String,
    revision: u64,
}
#[derive(Default)]
pub struct Session {
    translated: BTreeMap<Uuid, u64>,
    coalesced: BTreeMap<Uuid, (String, u64)>,
    backlog: BTreeSet<Key>,
    backfill: BTreeSet<Key>,
    pub depth: usize,
    pub queued_lines: usize,
}
impl Session {
    pub fn backlog_lines(&self) -> usize {
        self.backlog
            .iter()
            .map(|key| key.id)
            .collect::<BTreeSet<_>>()
            .len()
    }
    pub fn backfill_remaining(&self) -> usize {
        self.backfill.len()
    }
    pub fn invalidate(&mut self, id: Uuid) {
        self.translated.remove(&id);
    }
    fn revision(&self, id: Uuid, source: &str) -> u64 {
        self.coalesced
            .get(&id)
            .filter(|(text, _)| canonically_equal(text, source))
            .map_or_else(|| text_revision(source), |(_, revision)| *revision)
    }
    pub fn handle(&mut self, store: &mut TranscriptStore, event: &Effect) {
        match event {
            Effect::Depth { turns, lines } => {
                self.depth = *turns;
                self.queued_lines = *lines;
            }
            Effect::Drop {
                id,
                language,
                source,
            } => {
                self.backlog.insert(Key {
                    id: *id,
                    language: language.clone(),
                    revision: self.revision(*id, source),
                });
            }
            Effect::Result(result) => {
                let revision = self.revision(result.id, &result.source);
                if result.text.is_empty() {
                    store.suppress_translation(result.id, result.language.clone(), Some(revision));
                } else {
                    store.set_translation(
                        result.id,
                        result.language.clone(),
                        &result.text,
                        Some(revision),
                        false,
                    );
                }
                let key = Key {
                    id: result.id,
                    language: result.language.clone(),
                    revision,
                };
                self.backlog.remove(&key);
                self.backfill.remove(&key);
            }
            // Shipping committed translationStreaming is false. Displaced
            // revisions are discarded; only shed requests enter the backlog.
            _ => (),
        }
    }
    pub fn line(
        &mut self,
        store: &mut TranscriptStore,
        line: &Line,
        selected: &[String],
        token: Option<i64>,
        available: bool,
        force: Option<&BTreeSet<String>>,
    ) -> Option<Request> {
        let text = line.text();
        let revision = text_revision(&text);
        let routed = targets(&text, selected, token);
        let requested = force.map_or_else(
            || routed.clone(),
            |force| force.intersection(&routed).cloned().collect(),
        );
        let existing = store.prune_translations(line.id, &routed, revision);
        let missing: Vec<_> = requested.difference(&existing).cloned().collect();
        if missing.is_empty() {
            self.translated.insert(line.id, revision);
            return None;
        }
        if (force.is_none() && self.translated.get(&line.id) == Some(&revision)) || !available {
            return None;
        }
        self.translated.insert(line.id, revision);
        Some(Request {
            id: line.id,
            text,
            targets: missing,
            cacheable: true,
        })
    }
    pub fn stable(
        &mut self,
        store: &mut TranscriptStore,
        selected: &[String],
        token: Option<i64>,
        partial: &str,
        including_last: bool,
        available: bool,
    ) -> Vec<Request> {
        if selected.is_empty() {
            return Vec::new();
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
            && let Some(i) = lines[..end]
                .iter()
                .rposition(|l| l.words.last().is_some_and(|w| w.id == held.id))
        {
            end = i;
        }
        let start = if including_last {
            0
        } else {
            end.saturating_sub(32)
        };
        let newest_end = lines.last().map_or(0.0, |l| l.end);
        let stable = lines[start..end].to_vec();
        let input: Vec<_> = stable
            .iter()
            .map(|l| Input {
                id: l.id,
                speaker: l.speaker,
                text: l.text(),
                start: l.start,
                end: l.end,
                undecided: SpeakerNumbers::is_deciding(
                    l.speaker_margin,
                    (newest_end - l.end).max(0.0),
                ),
            })
            .collect();
        let mut jobs = Vec::new();
        for run in runs(&input, 3.0, !including_last) {
            let Some(anchor) = stable.iter().find(|l| l.id == run.anchor) else {
                continue;
            };
            if run.members.is_empty() {
                if let Some(job) = self.line(store, anchor, selected, token, available, None) {
                    jobs.push(job);
                }
                continue;
            }
            let revision = text_revision(&anchor.text());
            let joined_revision = text_revision(&run.text);
            let routed = targets(&run.text, selected, token);
            for member in run.members {
                if let Some(line) = stable.iter().find(|l| l.id == member) {
                    let hash = text_revision(&line.text());
                    if self.translated.get(&member) != Some(&hash) {
                        self.translated.insert(member, hash);
                        for lang in &routed {
                            store.suppress_translation(member, lang.clone(), None);
                        }
                    }
                }
            }
            let existing = store.prune_translations(anchor.id, &routed, revision);
            let missing: Vec<_> = routed.difference(&existing).cloned().collect();
            if missing.is_empty() {
                self.translated.insert(anchor.id, joined_revision);
                continue;
            }
            if self.translated.get(&anchor.id) == Some(&joined_revision) || !available {
                continue;
            }
            self.translated.insert(anchor.id, joined_revision);
            self.coalesced
                .insert(anchor.id, (run.text.clone(), revision));
            jobs.push(Request {
                id: anchor.id,
                text: run.text,
                targets: missing,
                cacheable: false,
            });
        }
        jobs
    }
    pub fn apply_cached(
        &mut self,
        store: &mut TranscriptStore,
        request: &mut Request,
        cached: &super::cache::Entry,
    ) {
        if !request.cacheable {
            return;
        }
        let revision = text_revision(&request.text);
        request.targets.retain(|lang| {
            if let Some(text) = cached.get(lang) {
                store.set_translation(request.id, lang.clone(), text, Some(revision), false);
                false
            } else {
                true
            }
        });
        // Cache hits have no client callback. Close only matching, successfully
        // applied keys; an empty or stale cached value is not a valid translation.
        let valid = store.valid_translation_languages(request.id, revision);
        self.backfill.retain(|key| {
            key.id != request.id || key.revision != revision || !valid.contains(&key.language)
        });
    }
    fn valid_backlog(
        &self,
        store: &TranscriptStore,
        selected: &[String],
        token: Option<i64>,
    ) -> BTreeSet<Key> {
        self.backlog
            .iter()
            .filter(|key| {
                store
                    .lines()
                    .iter()
                    .find(|l| l.id == key.id)
                    .is_some_and(|line| {
                        text_revision(&line.text()) == key.revision
                            && targets(&line.text(), selected, token).contains(&key.language)
                            && !line.translations.contains_key(&key.language)
                    })
            })
            .cloned()
            .collect()
    }
    pub fn backfill(
        &mut self,
        store: &mut TranscriptStore,
        selected: &[String],
        token: Option<i64>,
        finalizing: bool,
    ) -> Vec<Request> {
        let valid = self.valid_backlog(store, selected, token);
        let mut groups: BTreeMap<Uuid, BTreeSet<String>> = BTreeMap::new();
        if finalizing {
            self.backfill = valid.clone();
            self.backlog.clear();
        } else {
            self.backlog = valid.clone();
        }
        for key in valid {
            if !finalizing && groups.keys().next().is_some_and(|first| first != &key.id) {
                break;
            }
            groups.entry(key.id).or_default().insert(key.language);
        }
        groups
            .into_iter()
            .filter_map(|(id, langs)| {
                let line = store.lines().iter().find(|l| l.id == id)?.clone();
                self.invalidate(id);
                self.line(store, &line, selected, token, true, Some(&langs))
            })
            .collect()
    }
}
