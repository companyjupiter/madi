//! Session-scoped TranslateEngine state. Effects are executed by one native DNA
//! owner; callbacks must retain their ticket and process generation.
use super::{
    Example, Kind, Queue, Turn, adaptive_guarantee, body, canonical, committed_targets, count,
    output as policy, starts_with, usable_example,
};
use crate::{
    dna::Priority,
    personal_vocabulary::canonically_equal as equal,
    transcript::{Uuid, trim_whitespace_and_newlines as trim},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    time::Duration,
};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug)]
pub struct Configuration {
    pub priority_language: Option<String>,
    pub max_pending: usize,
    pub shed_secondary_targets_at: usize,
    pub interim_guarantee_seconds: f64,
}
impl Default for Configuration {
    fn default() -> Self {
        Self {
            priority_language: None,
            max_pending: 0,
            shed_secondary_targets_at: 6,
            interim_guarantee_seconds: 3.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Translation {
    pub id: Uuid,
    pub language: String,
    pub source: String,
    pub text: String,
}
impl Translation {
    fn from_turn(turn: &Turn, text: String) -> Self {
        Self {
            id: turn.id,
            language: turn.lang.clone(),
            source: turn.source.clone(),
            text,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Request {
    Prefix { slot: u8, text: String },
    Turn { prompt: String },
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    Submit {
        ticket: u64,
        request: Request,
        priority: Priority,
    },
    Partial(Translation),
    Result(Translation),
    Drop {
        id: Uuid,
        language: String,
        source: String,
    },
    Discard {
        id: Uuid,
        language: String,
        source: String,
    },
    Depth {
        turns: usize,
        lines: usize,
    },
    Pressure(usize),
}
#[derive(Debug)]
struct Inflight {
    ticket: u64,
    turn: Turn,
}

#[derive(Debug)]
pub struct Client {
    pub configuration: Configuration,
    pending: Queue,
    inflight: Option<Inflight>,
    ready: bool,
    closed: bool,
    generation: u64,
    forced_prefix_supported: bool,
    registered: BTreeSet<String>,
    disabled: BTreeSet<String>,
    registering: BTreeMap<String, u64>,
    prefix_requests: BTreeMap<u64, (String, u64)>,
    last_pair: BTreeMap<String, Example>,
    last_interim_accepted_at: Option<f64>,
    last_partial_emit: Duration,
    next_ticket: u64,
    runaway_truncations: usize,
    effects: Vec<Effect>,
}
impl Client {
    pub fn new(configuration: Configuration, monotonic_now: Duration) -> Self {
        Self {
            configuration,
            pending: Queue::default(),
            inflight: None,
            ready: false,
            closed: false,
            generation: 0,
            forced_prefix_supported: false,
            registered: BTreeSet::new(),
            disabled: BTreeSet::new(),
            registering: BTreeMap::new(),
            prefix_requests: BTreeMap::new(),
            last_pair: BTreeMap::new(),
            last_interim_accepted_at: None,
            last_partial_emit: monotonic_now,
            next_ticket: 0,
            runaway_truncations: 0,
            effects: Vec::new(),
        }
    }
    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }
    pub fn runaway_truncations(&self) -> usize {
        self.runaway_truncations
    }
    pub fn depth(&self) -> usize {
        self.pending.turns.len() + usize::from(self.inflight.is_some())
    }
    fn ticket(&mut self) -> u64 {
        self.next_ticket += 1;
        self.next_ticket
    }
    pub fn ready(&mut self, generation: u64, forced_prefix_supported: bool) {
        if self.closed || generation < self.generation {
            return;
        }
        self.generation = generation;
        self.ready = true;
        self.forced_prefix_supported = forced_prefix_supported;
        self.registered.clear();
        self.registering.clear();
        self.disabled.clear();
        self.pump();
    }
    /// Stop admission immediately on timeout, before orphaned completions can
    /// pump a stale cached-prefix command into the newly launched process.
    pub fn suspend(&mut self, generation: u64) {
        if generation != self.generation {
            return;
        }
        self.ready = false;
        self.registered.clear();
        self.registering.clear();
        self.disabled.clear();
    }
    /// A terminal transport failure drains barriers even for work still owned
    /// by this queue (and consequently invisible to the broker).
    pub fn fail(&mut self) {
        if self.closed {
            return;
        }
        self.closed = true;
        self.ready = false;
        if let Some(active) = self.inflight.take() {
            self.effects.push(Effect::Result(Translation::from_turn(
                &active.turn,
                String::new(),
            )));
        }
        for turn in self.pending.turns.drain(..) {
            self.effects
                .push(Effect::Result(Translation::from_turn(&turn, String::new())));
        }
        self.prefix_requests.clear();
        self.registered.clear();
        self.registering.clear();
        self.disabled.clear();
        self.report_queue();
    }
    pub fn stop(&mut self) {
        self.closed = true;
        self.ready = false;
        self.pending.turns.clear();
        self.inflight = None;
        self.prefix_requests.clear();
        self.registered.clear();
        self.registering.clear();
        self.disabled.clear();
        self.last_pair.clear();
        self.effects.push(Effect::Pressure(0));
    }
    pub fn translate(
        &mut self,
        text: &str,
        targets: &[String],
        id: Uuid,
        kind: Kind,
        forced: &BTreeMap<String, String>,
        uptime: f64,
    ) -> bool {
        if self.closed {
            return false;
        }
        let source = one_line(text);
        if source.is_empty() {
            return false;
        }
        let mut ordered = targets.to_vec();
        if kind == Kind::Committed {
            let backlog = self
                .pending
                .turns
                .iter()
                .filter(|t| t.kind == Kind::Committed)
                .count();
            let (send, shed) = committed_targets(
                &ordered,
                self.configuration.priority_language.as_deref(),
                backlog,
                self.configuration.shed_secondary_targets_at,
            );
            for language in shed {
                self.effects.push(Effect::Drop {
                    id,
                    language,
                    source: source.clone(),
                });
            }
            ordered = send;
        }
        if let Some(priority) = &self.configuration.priority_language
            && let Some(index) = ordered.iter().position(|t| equal(t, priority))
        {
            ordered.remove(index);
            ordered.push(priority.clone());
        }
        let mut reservation = kind == Kind::Interim && self.interim_starved(uptime);
        let mut accepted = false;
        for target in &ordered {
            let claims = reservation && ordered.last().is_some_and(|t| equal(t, target));
            let key = canonical(target);
            let example = usable_example(self.last_pair.get(&key), &source, 200);
            let head = instruction(target);
            let body = body(&source, example.as_ref(), anchor(target));
            let turn = Turn {
                id,
                lang: target.clone(),
                source: source.clone(),
                prompt: format!("{head}{body}"),
                prefix: Some(head),
                body: Some(body),
                retries: 1,
                kind,
                reserved: claims,
                forced: forced
                    .iter()
                    .find(|(k, _)| equal(k, target))
                    .and_then(|(_, v)| forced_prefix(v, kind)),
                example_source: example.as_ref().map(|e| e.source.clone()),
                example_target: example.map(|e| e.target),
            };
            let result = self.pending.enqueue(
                turn,
                self.inflight
                    .as_ref()
                    .is_some_and(|i| i.turn.kind == Kind::Committed),
                true,
            );
            if result.accepted {
                if claims {
                    reservation = false;
                }
                if kind == Kind::Interim {
                    self.last_interim_accepted_at = Some(uptime);
                }
            }
            accepted |= result.accepted;
            for old in result.displaced {
                self.discard(old);
            }
        }
        for turn in self.pending.shed_oldest(self.configuration.max_pending) {
            self.effects.push(Effect::Drop {
                id: turn.id,
                language: turn.lang,
                source: turn.source,
            });
        }
        self.pump();
        self.report_queue();
        accepted
    }
    fn interim_starved(&self, uptime: f64) -> bool {
        let backlog = self
            .pending
            .turns
            .iter()
            .filter(|t| t.kind == Kind::Committed)
            .count()
            + usize::from(
                self.inflight
                    .as_ref()
                    .is_some_and(|i| i.turn.kind == Kind::Committed),
            );
        adaptive_guarantee(self.configuration.interim_guarantee_seconds, backlog).is_some_and(
            |interval| {
                self.last_interim_accepted_at
                    .is_none_or(|last| uptime - last >= interval)
            },
        )
    }
    fn report_queue(&mut self) {
        let mut ids: BTreeSet<_> = self.pending.turns.iter().map(|t| t.id).collect();
        if let Some(active) = &self.inflight {
            ids.insert(active.turn.id);
        }
        self.effects.push(Effect::Depth {
            turns: self.depth(),
            lines: ids.len(),
        });
    }
    fn discard(&mut self, turn: Turn) {
        self.effects.push(Effect::Discard {
            id: turn.id,
            language: turn.lang,
            source: turn.source,
        });
    }
    fn pump(&mut self) {
        if !self.ready || self.closed || self.inflight.is_some() {
            return;
        }
        let Some(next) = self.pending.next() else {
            return;
        };
        let key = canonical(&next.lang);
        if let Some(prefix) = &next.prefix
            && let Some(slot) = slot(&next.lang)
            && !self.registered.contains(&key)
            && !self.disabled.contains(&key)
        {
            if self.registering.contains_key(&key) {
                return;
            }
            let text = prefix.clone();
            let ticket = self.ticket();
            self.registering.insert(key.clone(), ticket);
            self.prefix_requests.insert(ticket, (key, self.generation));
            self.effects.push(Effect::Submit {
                ticket,
                request: Request::Prefix { slot, text },
                priority: Priority::CommittedCaption,
            });
            return;
        }
        let turn = self.pending.pop_next().expect("peeked pending turn");
        let mut prompt = if let Some(body) = &turn.body
            && let Some(slot) = slot(&turn.lang)
            && self.registered.contains(&key)
        {
            format!("%%TRN {slot} {body}")
        } else {
            turn.prompt.clone()
        };
        if self.forced_prefix_supported {
            prompt.push_str(&format!(" %%MAX {}", policy::token_cap(&turn.source)));
            if let Some(forced) = &turn.forced {
                prompt.push_str(&format!(" %%FP {forced}"));
            }
        }
        let priority = if turn.kind == Kind::Committed {
            Priority::CommittedCaption
        } else {
            Priority::InterimCaption
        };
        let ticket = self.ticket();
        self.inflight = Some(Inflight { ticket, turn });
        self.effects.push(Effect::Submit {
            ticket,
            request: Request::Turn { prompt },
            priority,
        });
        self.report_queue();
    }
    pub fn partial(&mut self, ticket: u64, generation: u64, text: &str, now: Duration) {
        if self.closed || !self.ready || generation != self.generation {
            return;
        }
        let Some(active) = &self.inflight else {
            return;
        };
        if active.ticket != ticket
            || now.saturating_sub(self.last_partial_emit) <= Duration::from_millis(80)
        {
            return;
        }
        self.last_partial_emit = now;
        let turn = &active.turn;
        if text.is_empty() {
            return;
        }
        let cleaned = policy::clean(text);
        if cleaned.is_empty()
            || starts_with(policy::norm(&turn.source), policy::norm(&cleaned))
            || policy::may_be_example_echo(&cleaned, turn.example_target.as_deref())
        {
            return;
        }
        let cleaned =
            policy::strip_example_echo(&cleaned, turn.example_target.as_deref(), &turn.source);
        if cleaned.is_empty()
            || policy::should_retry(&cleaned, &turn.source, &turn.lang)
            || count(&cleaned) > policy::runaway_limit(&turn.source, Some(&turn.lang))
        {
            return;
        }
        self.effects
            .push(Effect::Partial(Translation::from_turn(turn, cleaned)));
    }
    pub fn complete(&mut self, ticket: u64, text: Option<&str>) {
        if self.closed {
            return;
        }
        if let Some((key, generation)) = self.prefix_requests.remove(&ticket) {
            if self.registering.get(&key) == Some(&ticket) {
                self.registering.remove(&key);
            }
            if generation == self.generation && self.ready {
                if text.is_some() {
                    self.registered.insert(key);
                } else {
                    self.disabled.insert(key);
                }
            }
            self.pump();
            return;
        }
        if self.inflight.as_ref().is_none_or(|i| i.ticket != ticket) {
            return;
        }
        let turn = self.inflight.take().unwrap().turn;
        let text = text.unwrap_or("");
        let sanitized = policy::clean(text);
        let cleaned =
            policy::strip_example_echo(&sanitized, turn.example_target.as_deref(), &turn.source);
        if (cleaned.is_empty() && !sanitized.is_empty())
            || policy::is_example_replay(
                &sanitized,
                turn.example_target.as_deref(),
                &turn.source,
                turn.example_source.as_deref(),
            )
            || policy::should_retry(text, &turn.source, &turn.lang)
        {
            if turn.retries > 0 {
                let retry = Turn {
                    id: turn.id,
                    lang: turn.lang.clone(),
                    source: turn.source.clone(),
                    prompt: repair_prompt(&turn.lang, &turn.source),
                    prefix: None,
                    body: None,
                    retries: turn.retries - 1,
                    kind: turn.kind,
                    reserved: false,
                    forced: None,
                    example_target: None,
                    example_source: None,
                };
                let result = self.pending.enqueue(retry.clone(), false, false);
                for old in result.displaced {
                    self.discard(old);
                }
                if !result.accepted {
                    self.discard(retry);
                }
            } else {
                self.effects
                    .push(Effect::Result(Translation::from_turn(&turn, String::new())));
            }
        } else {
            let limit = policy::runaway_limit(&turn.source, Some(&turn.lang));
            let runaway = count(&cleaned) > limit;
            let text = if runaway {
                self.runaway_truncations += 1;
                policy::truncate_runaway(&cleaned, limit)
            } else {
                cleaned
            };
            if turn.kind == Kind::Committed && !text.is_empty() && !runaway {
                self.last_pair.insert(
                    canonical(&turn.lang),
                    Example {
                        source: turn.source.clone(),
                        target: text.clone(),
                    },
                );
            }
            self.effects
                .push(Effect::Result(Translation::from_turn(&turn, text)));
        }
        self.pump();
        self.report_queue();
    }
}
pub fn one_line(text: &str) -> String {
    trim(&text.replace('\n', " ")).to_owned()
}
fn forced_prefix(text: &str, kind: Kind) -> Option<String> {
    if kind != Kind::Interim {
        return None;
    }
    let text = one_line(text);
    // Foundation substring matching respects the final grapheme boundary.
    let has_marker = text
        .grapheme_indices(true)
        .any(|(i, _)| starts_with(&text[i..], "%%FP"));
    (!text.is_empty() && !has_marker).then_some(text)
}
fn instruction(target: &str) -> String {
    format!(
        "Translate the following into {target}. Reply with only the translation in {target}, no notes. Example — "
    )
}
fn repair_prompt(target: &str, text: &str) -> String {
    let source = policy::source_language(text);
    format!(
        "You are a {source}-to-{target} translator. Return {target} text only. Source {source}: {text} Target {target}:"
    )
}
fn anchor(target: &str) -> &'static str {
    match target {
        "Korean" => "안녕하세요",
        "Japanese" => "こんにちは",
        "Chinese" => "你好",
        _ => "Hello",
    }
}
fn slot(target: &str) -> Option<u8> {
    match target {
        "Korean" => Some(0),
        "English" => Some(1),
        "Japanese" => Some(2),
        "Chinese" => Some(3),
        _ => None,
    }
}
