//! SessionController's optional speaker/language correction cycle. The workflow
//! owns snapshot identities, engine leases and retained audio through shutdown.
use super::*;
use crate::{capture_pipeline::OwnedWav, dna_broker, language_correction, reconcile_client};
use madi_core::{
    reconcile,
    transcript::{UNKNOWN_SPEAKER, text_revision, trim_whitespace_and_newlines},
};
use std::collections::{BTreeSet, VecDeque};

#[cfg(test)]
mod tests;

#[derive(Default)]
pub(super) struct Reconciliation {
    client: Option<reconcile_client::ReconcileClient>,
    snapshot: Vec<Uuid>,
    mid: bool,
    pending_final: bool,
    pub timer: Option<Instant>,
    pub segments: Vec<(f64, OwnedWav)>,
    pub risks: Vec<(f64, f64)>,
    names_before: Option<BTreeMap<i64, String>>,
    corrections: Option<Corrections>,
}
struct Job {
    id: Uuid,
    token: i64,
    source: OwnedWav,
    start: f64,
    end: f64,
    revision: u64,
}
struct Corrections {
    generation: u64,
    mid: bool,
    parts: Vec<String>,
    jobs: VecDeque<Job>,
    active: Option<(Job, language_correction::CorrectionTask)>,
    total: usize,
    processed: usize,
    applied: usize,
    failed: usize,
}
fn note(mid: bool, parts: &[String]) -> Option<String> {
    (!parts.is_empty()).then(|| {
        format!(
            "{}{}",
            if mid {
                "AI 교정(진행 중): "
            } else {
                "AI 교정: "
            },
            parts.join(" · ")
        )
    })
}
impl Reconciliation {
    pub fn correction_active(&self) -> bool {
        self.corrections
            .as_ref()
            .is_some_and(|c| c.active.is_some())
    }
    pub async fn next_correction(&mut self) -> io::Result<Option<String>> {
        self.corrections
            .as_mut()
            .unwrap()
            .active
            .as_mut()
            .unwrap()
            .1
            .wait()
            .await
    }
}
impl Worker {
    fn ai_enabled(&self) -> bool {
        self.preferences
            .as_ref()
            .is_some_and(|p| p.snapshot().settings.ai_reconcile_enabled)
    }
    pub(super) fn post_work_pending(&self) -> bool {
        self.translations.policy.depth > 0
            || self.state.reconciling
            || self.reconciliation.corrections.is_some()
    }
    async fn cancel_corrections(&mut self) {
        if let Some(mut cycle) = self.reconciliation.corrections.take()
            && let Some((_, mut task)) = cycle.active.take()
        {
            task.cancel();
            let _ = task.wait().await;
        }
        self.state.language_corrections_pending = 0;
    }
    pub(super) async fn stop_reconciliation(&mut self) {
        self.cancel_corrections().await;
        if let Some(mut client) = self.reconciliation.client.take()
            && let Err(error) = client.stop().await
        {
            eprintln!("reconciliation stop: {error}");
        }
        self.reconciliation.timer = None;
        self.reconciliation.pending_final = false;
        self.state.reconciling = false;
    }
    #[cfg(target_os = "macos")]
    pub(super) fn start_reconciliation_timer(&mut self) {
        self.reconciliation.timer = (self.ai_enabled()
            && crate::model_presentation::physical_memory() >= 16 * (1 << 30))
            .then(|| Instant::now() + Duration::from_secs(120));
    }
    pub(super) async fn reconciliation_tick(&mut self) {
        self.reconciliation.timer = Some(Instant::now() + Duration::from_secs(120));
        if self.state.phase != ViewPhase::Recording
            || self.state.reconciling
            || self.translations.policy.depth != 0
            || self.translations.policy.backlog_lines() != 0
        {
            return;
        }
        #[cfg(target_os = "macos")]
        if self
            .live_preview
            .as_ref()
            .is_some_and(|p| p.segments_pending > 0)
        {
            return;
        }
        self.kick_reconcile(true).await;
    }
    pub(super) async fn kick_reconcile(&mut self, mid: bool) -> bool {
        if self.state.reconciling {
            if !mid {
                self.reconciliation.pending_final = true;
            }
            return true;
        }
        if !self.ai_enabled() || self.store.lines().len() < 4 {
            return false;
        }
        if self.reconciliation.client.is_none() {
            let Some(launch) = self.translations.reconcile_launch() else {
                return false;
            };
            match reconcile_client::ReconcileClient::attach(&self.translations.broker, launch).await
            {
                Ok(client) => self.reconciliation.client = Some(client),
                Err(error) => {
                    eprintln!("reconciliation admission: {error}");
                    return false;
                }
            }
        }
        let count = self
            .store
            .lines()
            .len()
            .saturating_sub(if mid { 2 } else { 0 });
        if count < 4 {
            return false;
        }
        let lines = &self.store.lines()[..count];
        self.reconciliation.snapshot = lines.iter().map(|l| l.id).collect();
        self.reconciliation.mid = mid;
        self.state.reconciling = true;
        if !mid {
            self.state.reconcile_note = None;
        }
        let uncertain = lines
            .iter()
            .enumerate()
            .filter_map(|(i, l)| (l.speaker_margin < 0.35).then_some(i))
            .collect();
        let risk = lines
            .iter()
            .enumerate()
            .filter_map(|(i, l)| {
                self.reconciliation
                    .risks
                    .iter()
                    .any(|(s, e)| *e > l.start && *s < l.end)
                    .then_some(i)
            })
            .collect();
        let text: Vec<_> = lines.iter().map(Line::text).collect();
        let numbered = reconcile::prompt_input(
            lines
                .iter()
                .zip(&text)
                .map(|(l, t)| (l.speaker, t.as_str())),
            |id| {
                if id == UNKNOWN_SPEAKER {
                    "미확인".into()
                } else {
                    self.state
                        .speaker_names
                        .get(&id)
                        .cloned()
                        .unwrap_or_else(|| format!("화자 {id}"))
                }
            },
            &uncertain,
            &risk,
        );
        self.publish();
        match self
            .reconciliation
            .client
            .as_mut()
            .unwrap()
            .reconcile(&self.translations.broker, &numbered)
            .await
        {
            Ok(update) => self.reconciliation_update(update).await,
            Err(error) => {
                eprintln!("reconciliation request: {error}");
                self.apply_reconcile(None).await;
            }
        }
        true
    }
    pub(super) async fn reconciliation_event(&mut self, event: &dna_broker::Event) {
        if let Some(client) = &mut self.reconciliation.client {
            #[cfg(test)]
            if let dna_broker::Event::Completed {
                client: id, text, ..
            } = event
                && *id == client.id()
            {
                self.state.reconcile_replies.push(text.clone());
            }
            let update = client.handle(event);
            self.reconciliation_update(update).await;
        }
    }
    async fn reconciliation_update(&mut self, update: reconcile_client::Update) {
        if let Some(error) = update.fault {
            eprintln!("reconciliation transport: {error}");
        }
        if update.completed {
            self.apply_reconcile(update.text.as_deref()).await;
        }
    }
    async fn apply_reconcile(&mut self, reply: Option<&str>) {
        self.state.reconciling = false;
        let mid = self.reconciliation.mid;
        let Some(reply) = reply else {
            if !mid {
                self.state.reconcile_note = None;
            }
            self.complete_reconcile_cycle(mid).await;
            return;
        };
        let snapshot = self.reconciliation.snapshot.clone();
        let speakers = self
            .store
            .lines()
            .iter()
            .map(|l| l.speaker)
            .filter(|id| *id != UNKNOWN_SPEAKER)
            .collect();
        let allowed: BTreeSet<_> = snapshot
            .iter()
            .enumerate()
            .filter_map(|(i, id)| {
                self.store
                    .lines()
                    .iter()
                    .find(|l| l.id == *id)
                    .filter(|l| l.speaker_margin < 0.35)
                    .map(|_| i)
            })
            .collect();
        let plan = reconcile::parse(reply, &speakers, snapshot.len() as i64, 24, Some(&allowed));
        if plan.is_empty() {
            if !mid {
                self.state.reconcile_note = None;
            }
            self.complete_reconcile_cycle(mid).await;
            return;
        }
        let mut merged = 0;
        if !mid {
            for merge in plan.merges {
                if self.merge_speaker_identity(merge.from, merge.into) {
                    merged += 1;
                }
            }
        }
        let mut relabeled = 0;
        for relabel in plan.relabels {
            if let Some(id) = snapshot.get(relabel.line) {
                self.store.relabel_speaker(*id, relabel.speaker);
                relabeled += 1;
            }
        }
        let mut held = 0;
        let mut flags = Vec::new();
        for flag in plan.language_flags {
            if let Some(id) = snapshot.get(flag.line) {
                if reconcile::language_flag_allowed(&flag.lang, self.translations.language_token) {
                    flags.push((*id, flag.lang));
                } else {
                    held += 1;
                }
            }
        }
        let mut parts = Vec::new();
        if merged > 0 {
            parts.push(format!("화자 {merged}건 병합"));
        }
        if relabeled > 0 {
            parts.push(format!("화자 {relabeled}건 재지정"));
        }
        if held > 0 {
            parts.push(format!("언어 {held}건 보류(세션 언어와 다름)"));
        }
        if !flags.is_empty() {
            if self.start_language_corrections(flags, parts, mid).await {
                self.publish();
                return;
            }
        } else if !parts.is_empty() {
            self.state.reconcile_note = note(mid, &parts);
        } else if !mid {
            self.state.reconcile_note = None;
        }
        self.complete_reconcile_cycle(mid).await;
    }
    fn merge_speaker_identity(&mut self, from: i64, into: i64) -> bool {
        let from_name = self
            .state
            .speaker_names
            .get(&from)
            .map(|s| trim_whitespace_and_newlines(s).to_owned());
        let into_name = self
            .state
            .speaker_names
            .get(&into)
            .map(|s| trim_whitespace_and_newlines(s).to_owned());
        if let (Some(a), Some(b)) = (&from_name, &into_name)
            && !a.is_empty()
            && !b.is_empty()
            && !reconcile_client::speaker_names_equal(a, b)
        {
            return false;
        }
        if self.reconciliation.names_before.is_none() {
            self.reconciliation.names_before = Some(self.state.speaker_names.clone());
        }
        self.store.merge_speaker(from, into);
        self.state.speaker_names.remove(&from);
        if let Some(name) = into_name
            .filter(|n| !n.is_empty())
            .or(from_name)
            .filter(|n| !n.is_empty())
        {
            self.state.speaker_names.insert(into, name);
        }
        true
    }
    pub(super) fn revert_reconcile(&mut self) {
        self.store.revert_speaker_corrections();
        if let Some(names) = self.reconciliation.names_before.take() {
            self.state.speaker_names = names;
        }
        self.state.reconcile_note = None;
        self.store.flush_render();
        self.publish();
    }
    async fn complete_reconcile_cycle(&mut self, mid: bool) {
        if !mid {
            self.auto_save().await;
        }
        self.store.flush_render();
        self.publish();
        if self.reconciliation.pending_final {
            self.reconciliation.pending_final = false;
            // Box the single possible recursive edge (a completed mid request
            // admitting its final cycle, including an immediate submit failure).
            Box::pin(self.kick_reconcile(false)).await;
        }
        // Summary/title services will consume the corrected store after this
        // boundary; those producers are not yet migrated to FileWorkflow.
    }
    async fn start_language_corrections(
        &mut self,
        flags: Vec<(Uuid, String)>,
        parts: Vec<String>,
        mid: bool,
    ) -> bool {
        let mut jobs = VecDeque::new();
        for (id, lang) in &flags {
            let Some(line) = self.store.lines().iter().find(|l| l.id == *id) else {
                continue;
            };
            let Some(token) = reconcile::language_token(lang) else {
                continue;
            };
            let Some((offset, source)) = self
                .reconciliation
                .segments
                .iter()
                .rfind(|(offset, _)| *offset <= line.start + 0.05)
                .or(self.reconciliation.segments.first())
            else {
                continue;
            };
            if !source.path().exists() {
                continue;
            }
            jobs.push_back(Job {
                id: *id,
                token,
                source: source.clone(),
                start: (line.start - offset).max(0.),
                end: (line.start - offset + 0.08).max(line.end - offset),
                revision: text_revision(&line.text()),
            });
        }
        let unavailable = flags.len() - jobs.len();
        if jobs.is_empty() {
            let mut parts = parts;
            parts.push(format!("언어 {unavailable}건 검증만(보존 오디오 없음)"));
            self.state.reconcile_note = note(mid, &parts);
            return false;
        }
        self.cancel_corrections().await;
        let total = jobs.len();
        let mut progress = parts.clone();
        progress.push(format!("언어 0/{total}줄 교정 중"));
        self.state.reconcile_note = note(mid, &progress);
        self.state.language_corrections_pending = total;
        self.reconciliation.corrections = Some(Corrections {
            generation: self.state.generation,
            mid,
            parts,
            jobs,
            active: None,
            total,
            processed: 0,
            applied: 0,
            failed: unavailable,
        });
        self.advance_correction().await;
        true
    }
    async fn advance_correction(&mut self) {
        loop {
            let Some(cycle) = self.reconciliation.corrections.as_mut() else {
                return;
            };
            if let Some(job) = cycle.jobs.pop_front() {
                let config = language_correction::Configuration::new(
                    self.configuration.resources.clone(),
                    job.token,
                );
                match language_correction::CorrectionTask::start(
                    config,
                    job.source.clone(),
                    job.start,
                    job.end,
                ) {
                    Ok(task) => {
                        cycle.active = Some((job, task));
                        return;
                    }
                    Err(error) => {
                        eprintln!("language correction start: {error}");
                        cycle.failed += 1;
                        cycle.processed += 1;
                        self.state.language_corrections_pending = cycle.jobs.len();
                        continue;
                    }
                }
            }
            let mut cycle = self.reconciliation.corrections.take().unwrap();
            if cycle.applied > 0 {
                cycle.parts.push(format!("언어 {}건 교정", cycle.applied));
            }
            if cycle.failed > 0 {
                cycle
                    .parts
                    .push(format!("언어 {}건 원문 유지", cycle.failed));
            }
            self.state.language_corrections_pending = 0;
            self.state.reconcile_note = note(cycle.mid, &cycle.parts);
            self.auto_save().await;
            self.complete_reconcile_cycle(cycle.mid).await;
            return;
        }
    }
    pub(super) async fn correction_finished(&mut self, result: io::Result<Option<String>>) {
        let Some(cycle) = self.reconciliation.corrections.as_mut() else {
            return;
        };
        let (job, _) = cycle.active.take().unwrap();
        let mut applied = false;
        if cycle.generation == self.state.generation {
            match result {
                Ok(Some(text)) if !text.is_empty() => {
                    applied = self.store.edit_line(job.id, &text, Some(job.revision))
                }
                Err(error) => eprintln!("language correction: {error}"),
                _ => {}
            }
        }
        cycle.processed += 1;
        if applied {
            cycle.applied += 1;
        } else {
            cycle.failed += 1;
        }
        self.state.language_corrections_pending = cycle.total - cycle.processed;
        let mut progress = cycle.parts.clone();
        progress.push(format!("언어 {}/{}줄 처리", cycle.processed, cycle.total));
        self.state.reconcile_note = note(cycle.mid, &progress);
        if applied {
            self.translate_line(job.id, true).await;
        }
        self.store.flush_render();
        self.publish();
        self.advance_correction().await;
    }
}
