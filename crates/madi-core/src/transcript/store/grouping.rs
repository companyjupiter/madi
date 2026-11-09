use super::*;

impl TranscriptStore {
    fn ends_sentence(text: &str) -> bool {
        matches!(
            text.trim_matches(whitespace).graphemes(true).next_back(),
            Some("." | "?" | "!" | "。" | "？" | "！" | "…")
        )
    }
    fn ends_clause(text: &str) -> bool {
        matches!(
            text.trim_matches(whitespace).graphemes(true).next_back(),
            Some("," | "，" | "、" | ";" | "；" | ":" | "：")
        )
    }
    pub fn line_is_full(words: usize, span: f64, tail_ends_clause: bool) -> bool {
        words >= 28 || span >= 14.0 || (words >= 16 && tail_ends_clause)
    }
    fn live_lookup(&mut self) -> Arc<LabelLookup> {
        self.lookup
            .get_or_insert_with(|| Arc::new(LabelLookup::new(&self.speakers)))
            .clone()
    }
    fn numberable_speakers(&self) -> Vec<i64> {
        let mut seconds = BTreeMap::new();
        let mut order = Vec::new();
        for line in &self.lines {
            if !seconds.contains_key(&line.speaker) {
                order.push(line.speaker);
            }
            *seconds.entry(line.speaker).or_insert(0.0_f64) += (line.end - line.start).max(0.0);
        }
        order
            .into_iter()
            .filter(|speaker| seconds[speaker] >= self.features.min_seconds_to_number)
            .collect()
    }
    pub fn finalize(&mut self) {
        self.speaker_numbers
            .assign_all(self.lines.iter().map(|line| line.speaker));
        self.finalized = true;
        self.frozen_count = 0;
        self.frozen_word_count = 0;
        self.merger.finish();
        let mut last_by_time = BTreeMap::new();
        let mut order = Vec::new();
        for label in &self.fixes {
            let key = (label.time * 100.0).round() as i64;
            if !last_by_time.contains_key(&key) {
                order.push(key);
            }
            last_by_time.insert(key, label.clone());
        }
        let deduped: Vec<_> = order
            .into_iter()
            .map(|key| last_by_time.remove(&key).expect("ordered label"))
            .collect();
        let labels = if deduped.is_empty() || self.namespace_broken {
            &self.speakers
        } else {
            &deduped
        };
        self.lines = self.group(
            self.merger.committed().to_vec(),
            &LabelLookup::new(labels),
            usize::MAX,
        );
        self.apply_overlays(0);
        self.apply_overlaps(0);
        self.flush_display_now();
    }
    pub(super) fn rebuild_live(&mut self) {
        let committed_count = self.merger.committed().len();
        if self.frozen_word_count > committed_count || self.frozen_count > self.lines.len() {
            self.frozen_count = 0;
            self.frozen_word_count = 0;
        }
        let words = self.merger.display_words(self.frozen_word_count);
        let watermark = words.last().map_or(0.0, |word| word.t1) - 6.0;
        let lookup = self.live_lookup();
        let tail = self.group(words, &lookup, committed_count - self.frozen_word_count);
        let splice = self.frozen_count;
        let mut promoted = 0;
        while tail.len() - promoted > 1
            && tail[promoted].end < watermark
            && self.frozen_word_count + tail[promoted].words.len() <= committed_count
        {
            self.frozen_word_count += tail[promoted].words.len();
            promoted += 1;
        }
        self.frozen_count += promoted;
        self.lines.truncate(splice);
        self.lines.extend(tail);
        self.apply_overlays(splice);
        self.apply_overlaps(splice);
        self.speaker_numbers.assign_all(self.numberable_speakers());
        self.join_newly_frozen(promoted);
        self.render_pending = true;
    }
    pub(super) fn reassign_frozen_speakers(&mut self) {
        if self.frozen_count == 0 || self.frozen_count > self.lines.len() {
            return;
        }
        let lookup = self.live_lookup();
        for i in 0..self.frozen_count {
            let line = &self.lines[i];
            let (speaker, margin) = lookup.at((line.start + line.end) / 2.0);
            self.lines[i].speaker = self.resolved_speaker(
                self.speaker_overrides
                    .get(&line.id)
                    .copied()
                    .unwrap_or(speaker),
            );
            self.lines[i].speaker_margin = margin;
        }
    }
    fn can_join(&self, a: &Line, b: &Line) -> bool {
        if !self.features.join_same_speaker_neighbors
            || a.speaker != b.speaker
            || a.speaker == UNKNOWN_SPEAKER
            || a.is_edited()
            || b.is_edited()
        {
            return false;
        }
        let (Some(tail), Some(head), Some(last)) =
            (a.words.last(), b.words.first(), b.words.last())
        else {
            return false;
        };
        if Self::ends_sentence(&tail.text)
            || self.sentence_breaks.contains(&tail.id)
            || head.t0 - tail.t1 >= 1.5
        {
            return false;
        }
        if Self::line_is_full(
            a.words.len(),
            last.t1 - a.start,
            Self::ends_clause(&tail.text),
        ) || a.words.len() + b.words.len() > 28
            || last.t1 - a.start > 14.0
        {
            return false;
        }
        !b.words
            .iter()
            .take(b.words.len() - 1)
            .enumerate()
            .any(|(k, word)| a.words.len() + k + 1 >= 16 && Self::ends_clause(&word.text))
    }
    fn join_frozen(&mut self, index: usize) {
        let b = self.lines.remove(index + 1);
        let a = &mut self.lines[index];
        if let Some(tail) = a.words.last() {
            self.break_after.remove(&tail.id);
            self.break_decided.remove(&tail.id);
        }
        a.words.extend(b.words.iter().cloned());
        a.end = a.end.max(b.end);
        a.speaker_margin = a.speaker_margin.min(b.speaker_margin);
        for speaker in &b.overlap_speakers {
            if !a.overlap_speakers.contains(speaker) {
                a.overlap_speakers.push(*speaker);
            }
        }
        if index + 1 < self.frozen_count {
            self.frozen_count -= 1;
        }
        self.translations.remove(&b.id);
        self.suppressed.remove(&b.id);
        self.edits.remove(&b.id);
        self.speaker_overrides.remove(&b.id);
        self.edited_row_words.remove(&b.id);
        if let Some(words) = self.edited_row_words.get_mut(&a.id) {
            words.extend(b.words.iter().map(|word| word.id));
        }
        self.refresh_translation_overlay(index);
        self.same_speaker_joins += 1;
        self.render_pending = true;
    }
    pub fn join_same_speaker_neighbors(&mut self) {
        if self.finalized || !self.features.join_same_speaker_neighbors {
            return;
        }
        let mut flipped = false;
        let mut index = 0;
        while index + 1 < self.lines.len() {
            if index + 1 < self.frozen_count {
                if self.can_join(&self.lines[index], &self.lines[index + 1]) {
                    self.join_frozen(index);
                    continue;
                }
            } else if index >= self.frozen_count
                && self.can_join(&self.lines[index], &self.lines[index + 1])
                && let Some(tail) = self.lines[index].words.last()
                && self.break_after.contains(&tail.id)
            {
                self.break_after.remove(&tail.id);
                self.break_decided.remove(&tail.id);
                self.same_speaker_joins += 1;
                flipped = true;
            }
            index += 1;
        }
        if flipped {
            self.rebuild_live();
        }
    }
    fn join_newly_frozen(&mut self, promoted: usize) {
        if promoted == 0 || !self.features.join_same_speaker_neighbors {
            return;
        }
        let mut index = (self.frozen_count - promoted).max(1);
        while index < self.frozen_count {
            if self.can_join(&self.lines[index - 1], &self.lines[index]) {
                self.join_frozen(index - 1);
            } else {
                index += 1;
            }
        }
    }
    fn group(&mut self, mut words: Vec<Word>, lookup: &LabelLookup, settled: usize) -> Vec<Line> {
        let settled_ids: Option<BTreeSet<_>> = (self.features.settled_ledger
            && settled < words.len())
        .then(|| words.iter().take(settled).map(|word| word.id).collect());
        let is_settled = |word: &Word| {
            settled_ids
                .as_ref()
                .is_none_or(|ids| ids.contains(&word.id))
        };
        words.sort_by(|a, b| a.t0.partial_cmp(&b.t0).unwrap_or(std::cmp::Ordering::Equal));
        let mut out: Vec<Line> = Vec::new();
        for word in words {
            let (speaker, margin) = lookup.at(word.t0);
            if self.features.speaker_island_absorption && out.len() >= 2 {
                let b = &out[out.len() - 1];
                let a = &out[out.len() - 2];
                if b.speaker != speaker
                    && a.speaker == speaker
                    && b.words.len() <= 4
                    && b.speaker_margin < 0.35
                    && !self.edits.contains_key(&b.id)
                    && !self.edits.contains_key(&a.id)
                    && let (Some(a_tail), Some(b_tail)) = (a.words.last(), b.words.last())
                    && !Self::ends_sentence(&a_tail.text)
                    && !self.sentence_breaks.contains(&a_tail.id)
                    && !Self::ends_sentence(&b_tail.text)
                    && !self.sentence_breaks.contains(&b_tail.id)
                    && b.start - a.end < 0.3
                    && word.t0 - b.end < 0.3
                {
                    let boundary = a_tail.id;
                    let b = out.pop().expect("island row");
                    let a = out.last_mut().expect("pre-island row");
                    a.words.extend(b.words);
                    a.end = a.end.max(b.end);
                    self.break_after.remove(&boundary);
                    self.island_absorptions += 1;
                }
            }
            let tail = out.last().and_then(|line| line.words.last());
            let weak = self.features.weak_label_continuation > 0.0
                && out.last().is_some_and(|last| {
                    last.speaker != speaker
                        && margin < self.features.weak_label_continuation
                        && word.t0 - last.end < 0.3
                });
            let continuing;
            if let Some(last) = out.last()
                && let Some(owned) = self.edited_row_words.get(&last.id)
            {
                continuing = owned.contains(&word.id) && !self.edits.contains_key(&word.id);
            } else if let Some(last) = out.last()
                && (self.edits.contains_key(&last.id) || self.edits.contains_key(&word.id))
            {
                continuing = false;
            } else if !self.finalized
                && let Some(tail) = tail
                && self.break_decided.contains(&tail.id)
            {
                continuing = !self.break_after.contains(&tail.id);
            } else {
                let broken = tail.is_some_and(|tail| self.sentence_breaks.contains(&tail.id));
                continuing = out.last().is_some_and(|last| {
                    let same_speaker = last.speaker == speaker;
                    let head = self.features.turn_head_adoption
                        && !same_speaker
                        && last.words.len() <= 1
                        && word.t0 - last.end < 0.3;
                    ((same_speaker && word.t0 - last.end < 1.5) || head || weak)
                        && !broken
                        && !last
                            .words
                            .last()
                            .is_some_and(|word| Self::ends_sentence(&word.text))
                        && !Self::line_is_full(
                            last.words.len(),
                            word.t1 - last.start,
                            last.words
                                .last()
                                .is_some_and(|word| Self::ends_clause(&word.text)),
                        )
                });
                if !self.finalized
                    && let Some(tail) = tail
                    && is_settled(tail)
                    && is_settled(&word)
                {
                    self.break_decided.insert(tail.id);
                    if !continuing {
                        self.break_after.insert(tail.id);
                    }
                }
            }
            if continuing {
                let last = out.last_mut().expect("continuing row");
                if self.features.turn_head_adoption
                    && last.speaker != speaker
                    && last.words.len() <= 1
                    && !weak
                {
                    last.speaker = speaker;
                    last.speaker_margin = margin;
                }
                last.end = last.end.max(word.t1);
                last.words.push(word);
                if weak && last.speaker != speaker {
                    self.weak_label_continuations += 1;
                } else {
                    last.speaker_margin = last.speaker_margin.min(margin);
                }
            } else {
                if let Some(tail) = tail
                    && Self::ends_sentence(&tail.text)
                    && is_settled(tail)
                    && is_settled(&word)
                {
                    self.sentence_breaks.insert(tail.id);
                }
                out.push(Line::new(word, speaker, margin));
            }
        }
        out
    }
}
