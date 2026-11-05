//! Deterministic lifetime contract ported from SessionCoordinator.swift.
//! An OS adapter executes effects in order and tags every asynchronous reply.
//! Resource tokens prevent cleanup of an old capture from touching a new one.
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Token {
    generation: u64,
    identity: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    EngineStart(String),
    CaptureStart(String),
    Preparation(String),
    StartupTimeout,
    EngineExit(i32),
    Message(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Phase {
    Idle,
    CountingDown(u32),
    EngineStarting,
    Ready,
    Recording,
    Paused,
    Processing,
    Flushing,
    Done,
    Error(Failure),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeadlineKind {
    Startup,
    Flush,
    Countdown,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    StartEngine {
        token: Token,
        file: Option<PathBuf>,
    },
    TerminateEngine(Token),
    StartCapture(Token),
    CancelCaptureStart(Token),
    AbortCapture(Token),
    PauseCapture(Token),
    ResumeCapture(Token),
    StopCapture(Token),
    FlushEngine(Token),
    PrepareFile(Token),
    CancelPreparation(Token),
    RemovePreparedFile(PathBuf),
    Schedule {
        token: Token,
        kind: DeadlineKind,
        seconds: u32,
    },
    CancelDeadline(Token),
    RecordingStarted,
    Finished,
    Failed,
    FlushTimedOut,
    CountdownElapsed,
}

pub struct Session {
    phase: Phase,
    generation: u64,
    identity: u64,
    engine: Option<Token>,
    capture: Option<Token>,
    capture_start: Option<Token>,
    stopping_capture: Option<Token>,
    preparation: Option<Token>,
    prepared_file: Option<PathBuf>,
    deadline: Option<(Token, DeadlineKind)>,
    countdown: Option<Token>,
    started_at: Option<f64>,
    ended_at: Option<f64>,
    paused_at: Option<f64>,
    paused_accumulated: f64,
}

impl Default for Session {
    fn default() -> Self {
        Self {
            phase: Phase::Idle,
            generation: 0,
            identity: 0,
            engine: None,
            capture: None,
            capture_start: None,
            stopping_capture: None,
            preparation: None,
            prepared_file: None,
            deadline: None,
            countdown: None,
            started_at: None,
            ended_at: None,
            paused_at: None,
            paused_accumulated: 0.0,
        }
    }
}

impl Session {
    pub fn phase(&self) -> &Phase {
        &self.phase
    }
    pub fn engine_token(&self) -> Option<Token> {
        self.engine
    }
    pub fn capture_token(&self) -> Option<Token> {
        self.capture
    }
    pub fn can_start(&self) -> bool {
        matches!(self.phase, Phase::Idle | Phase::Done | Phase::Error(_))
    }
    pub fn recorded_seconds(&self, now: f64) -> f64 {
        self.started_at
            .map(|start| {
                let end = self.ended_at.unwrap_or(now);
                (end - start
                    - self.paused_accumulated
                    - self.paused_at.map(|p| end - p).unwrap_or(0.0))
                .max(0.0)
            })
            .unwrap_or(0.0)
    }
    fn token(&mut self) -> Token {
        self.identity = self
            .identity
            .checked_add(1)
            .expect("session token exhausted");
        Token {
            generation: self.generation,
            identity: self.identity,
        }
    }
    fn cancel_deadline(&mut self, effects: &mut Vec<Effect>) {
        if let Some((token, _)) = self.deadline.take() {
            effects.push(Effect::CancelDeadline(token));
        }
    }
    fn arm(&mut self, kind: DeadlineKind, effects: &mut Vec<Effect>) {
        self.cancel_deadline(effects);
        let token = self.token();
        self.deadline = Some((token, kind));
        effects.push(Effect::Schedule {
            token,
            kind,
            seconds: 45,
        });
    }
    fn retire_engine(&mut self, effects: &mut Vec<Effect>) {
        if let Some(token) = self.engine.take() {
            effects.push(Effect::TerminateEngine(token));
        }
    }
    fn release(&mut self, effects: &mut Vec<Effect>) {
        self.cancel_deadline(effects);
        if let Some(token) = self.countdown.take() {
            effects.push(Effect::CancelDeadline(token));
        }
        if let Some(token) = self.capture_start.take() {
            effects.push(Effect::CancelCaptureStart(token));
        }
        if let Some(token) = self.preparation.take() {
            effects.push(Effect::CancelPreparation(token));
        }
        self.stopping_capture = None;
        if let Some(token) = self.capture.take() {
            effects.push(Effect::AbortCapture(token));
        }
        self.retire_engine(effects);
        if let Some(path) = self.prepared_file.take() {
            effects.push(Effect::RemovePreparedFile(path));
        }
    }
    pub fn reset(&mut self) -> Vec<Effect> {
        self.generation = self
            .generation
            .checked_add(1)
            .expect("session generation exhausted");
        let mut effects = Vec::new();
        self.release(&mut effects);
        self.started_at = None;
        self.ended_at = None;
        self.paused_at = None;
        self.paused_accumulated = 0.0;
        self.phase = Phase::Idle;
        effects
    }
    pub fn open_archive(&mut self) -> Vec<Effect> {
        if !self.can_start() {
            return Vec::new();
        }
        let effects = self.reset();
        self.phase = Phase::Done;
        effects
    }
    pub fn begin_countdown(&mut self, count: u32) -> Vec<Effect> {
        if !self.can_start() {
            return Vec::new();
        }
        let token = self.token();
        self.countdown = Some(token);
        self.phase = Phase::CountingDown(count.max(1));
        vec![Effect::Schedule {
            token,
            kind: DeadlineKind::Countdown,
            seconds: 1,
        }]
    }
    pub fn cancel_countdown(&mut self) -> Vec<Effect> {
        if !matches!(self.phase, Phase::CountingDown(_)) {
            return Vec::new();
        }
        self.phase = Phase::Idle;
        self.countdown
            .take()
            .map(Effect::CancelDeadline)
            .into_iter()
            .collect()
    }
    pub fn begin_live(&mut self) -> Vec<Effect> {
        if !self.can_start() && self.phase != Phase::CountingDown(1) {
            return Vec::new();
        }
        let mut effects = self.reset();
        self.capture = Some(self.token());
        self.phase = Phase::EngineStarting;
        self.arm(DeadlineKind::Startup, &mut effects);
        self.install(None, &mut effects);
        effects
    }
    fn install(&mut self, file: Option<PathBuf>, effects: &mut Vec<Effect>) {
        let token = self.token();
        self.engine = Some(token);
        effects.push(Effect::StartEngine { token, file });
    }
    pub fn begin_file(&mut self) -> Vec<Effect> {
        if !self.can_start() {
            return Vec::new();
        }
        let mut effects = self.reset();
        self.phase = Phase::Processing;
        let token = self.token();
        self.preparation = Some(token);
        effects.push(Effect::PrepareFile(token));
        effects
    }
    /// Only the adapter's owned temporary WAV can be transferred here. Never
    /// pass an original user file; cancellation removes the transferred path.
    pub fn file_prepared(
        &mut self,
        token: Token,
        result: Result<PathBuf, String>,
        now: f64,
    ) -> Vec<Effect> {
        if self.preparation != Some(token) || self.phase != Phase::Processing {
            return result
                .ok()
                .map(Effect::RemovePreparedFile)
                .into_iter()
                .collect();
        }
        self.preparation = None;
        match result {
            Ok(path) => {
                self.prepared_file = Some(path.clone());
                let mut effects = Vec::new();
                self.install(Some(path), &mut effects);
                effects
            }
            Err(message) => self.fail(Failure::Preparation(message), now),
        }
    }
    pub fn replace_engine(&mut self) -> Vec<Effect> {
        if !matches!(self.phase, Phase::Recording | Phase::Paused) {
            return Vec::new();
        }
        let mut effects = Vec::new();
        self.retire_engine(&mut effects);
        self.install(None, &mut effects);
        effects
    }
    pub fn engine_started(
        &mut self,
        token: Token,
        result: Result<(), String>,
        now: f64,
    ) -> Vec<Effect> {
        if self.engine != Some(token) {
            return Vec::new();
        }
        result
            .err()
            .map(|message| self.fail(Failure::EngineStart(message), now))
            .unwrap_or_default()
    }
    pub fn engine_ready(&mut self, token: Token) -> Vec<Effect> {
        if self.engine != Some(token) || self.phase != Phase::EngineStarting {
            return Vec::new();
        }
        let Some(capture) = self.capture else {
            return Vec::new();
        };
        self.phase = Phase::Ready;
        self.capture_start = Some(capture);
        vec![Effect::StartCapture(capture)]
    }
    pub fn capture_started(
        &mut self,
        token: Token,
        result: Result<(), String>,
        now: f64,
    ) -> Vec<Effect> {
        if self.capture_start != Some(token)
            || self.capture != Some(token)
            || self.phase != Phase::Ready
        {
            return vec![Effect::AbortCapture(token)];
        }
        self.capture_start = None;
        if let Err(message) = result {
            return self.fail(Failure::CaptureStart(message), now);
        }
        let mut effects = Vec::new();
        self.cancel_deadline(&mut effects);
        self.started_at = Some(now);
        self.phase = Phase::Recording;
        effects.push(Effect::RecordingStarted);
        effects
    }
    /// Forward the payload only when accepted. Only ordinary stdout events
    /// refresh the flush deadline; structured/diagnostic messages do not.
    pub fn engine_event(&mut self, token: Token, ordinary: bool) -> (bool, Vec<Effect>) {
        if self.engine != Some(token) {
            return (false, Vec::new());
        }
        let mut effects = Vec::new();
        if ordinary && self.phase == Phase::Flushing {
            self.arm(DeadlineKind::Flush, &mut effects);
        }
        (true, effects)
    }
    pub fn accepts_segment(&self, token: Token) -> bool {
        self.capture == Some(token)
            && matches!(
                self.phase,
                Phase::Ready | Phase::Recording | Phase::Paused | Phase::Flushing
            )
    }
    pub fn accepts_preview_or_level(&self, token: Token) -> bool {
        self.capture == Some(token) && self.phase == Phase::Recording
    }
    pub fn accepts_capture_error(&self, token: Token) -> bool {
        self.capture == Some(token)
            && matches!(
                self.phase,
                Phase::EngineStarting | Phase::Ready | Phase::Recording | Phase::Paused
            )
    }
    pub fn pause(&mut self, now: f64) -> Vec<Effect> {
        if self.phase != Phase::Recording {
            return Vec::new();
        }
        self.paused_at = Some(now);
        self.phase = Phase::Paused;
        self.capture.map(Effect::PauseCapture).into_iter().collect()
    }
    pub fn resume(&mut self, now: f64) -> Vec<Effect> {
        if self.phase != Phase::Paused {
            return Vec::new();
        }
        if let Some(paused) = self.paused_at.take() {
            self.paused_accumulated += now - paused;
        }
        self.phase = Phase::Recording;
        self.capture
            .map(Effect::ResumeCapture)
            .into_iter()
            .collect()
    }
    pub fn stop(&mut self, now: f64) -> Vec<Effect> {
        if !matches!(self.phase, Phase::Recording | Phase::Paused) {
            return Vec::new();
        }
        self.ended_at = Some(now);
        self.phase = Phase::Flushing;
        let mut effects = Vec::new();
        self.arm(DeadlineKind::Flush, &mut effects);
        if let Some(token) = self.capture {
            self.stopping_capture = Some(token);
            effects.push(Effect::StopCapture(token));
        } else if let Some(token) = self.engine {
            effects.push(Effect::FlushEngine(token));
        }
        effects
    }
    /// Adapter acknowledges stop only after all final segment callbacks were
    /// delivered. This is the async equivalent of Swift's synchronous stop().
    pub fn capture_stopped(&mut self, token: Token) -> Vec<Effect> {
        if self.stopping_capture != Some(token) || self.phase != Phase::Flushing {
            return Vec::new();
        }
        self.stopping_capture = None;
        self.engine.map(Effect::FlushEngine).into_iter().collect()
    }
    pub fn engine_flushed(&mut self, token: Token, now: f64) -> Vec<Effect> {
        if self.engine != Some(token) {
            return Vec::new();
        }
        self.finish(now)
    }
    pub fn engine_exited(&mut self, token: Token, code: i32, now: f64) -> Vec<Effect> {
        if self.engine != Some(token) {
            return Vec::new();
        }
        if code == 0 && matches!(self.phase, Phase::Processing | Phase::Flushing) {
            self.finish(now)
        } else {
            self.fail(Failure::EngineExit(code), now)
        }
    }
    pub fn fail(&mut self, failure: Failure, now: f64) -> Vec<Effect> {
        let active =
            self.engine.is_some() || self.capture.is_some() || self.phase == Phase::Processing;
        if active {
            self.generation = self
                .generation
                .checked_add(1)
                .expect("session generation exhausted");
        }
        self.ended_at.get_or_insert(now);
        let mut effects = Vec::new();
        self.release(&mut effects);
        self.phase = Phase::Error(failure);
        if active {
            effects.push(Effect::Failed);
        }
        effects
    }
    fn finish(&mut self, now: f64) -> Vec<Effect> {
        if !matches!(self.phase, Phase::Processing | Phase::Flushing) {
            return Vec::new();
        }
        self.ended_at.get_or_insert(now);
        let mut effects = Vec::new();
        self.release(&mut effects);
        self.phase = Phase::Done;
        effects.push(Effect::Finished);
        effects
    }
    pub fn deadline_fired(&mut self, token: Token, now: f64) -> Vec<Effect> {
        if self.countdown == Some(token) {
            let Phase::CountingDown(count) = self.phase else {
                return Vec::new();
            };
            self.countdown = None;
            if count == 1 {
                return vec![Effect::CountdownElapsed];
            }
            let next = self.token();
            self.countdown = Some(next);
            self.phase = Phase::CountingDown(count - 1);
            return vec![Effect::Schedule {
                token: next,
                kind: DeadlineKind::Countdown,
                seconds: 1,
            }];
        }
        let Some((current, kind)) = self.deadline else {
            return Vec::new();
        };
        if current != token {
            return Vec::new();
        }
        match kind {
            DeadlineKind::Startup if matches!(self.phase, Phase::EngineStarting | Phase::Ready) => {
                self.fail(Failure::StartupTimeout, now)
            }
            DeadlineKind::Flush if self.phase == Phase::Flushing => {
                let mut effects = vec![Effect::FlushTimedOut];
                effects.extend(self.finish(now));
                effects
            }
            _ => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scheduled(effects: &[Effect], kind: DeadlineKind) -> Token {
        effects
            .iter()
            .find_map(|e| match e {
                Effect::Schedule {
                    token,
                    kind: actual,
                    ..
                } if *actual == kind => Some(*token),
                _ => None,
            })
            .expect("missing deadline")
    }
    fn live() -> (Session, Token, Token) {
        let mut session = Session::default();
        session.begin_live();
        let engine = session.engine_token().unwrap();
        let capture = session.capture_token().unwrap();
        assert_eq!(
            session.engine_ready(engine),
            vec![Effect::StartCapture(capture)]
        );
        assert!(
            session
                .capture_started(capture, Ok(()), 1000.0)
                .contains(&Effect::RecordingStarted)
        );
        (session, engine, capture)
    }

    #[test]
    fn tail_ack_precedes_flush_and_finish_occurs_once_with_frozen_duration() {
        let (mut s, engine, capture) = live();
        s.pause(1010.0);
        s.resume(1030.0);
        let stop = s.stop(1035.0);
        assert!(stop.contains(&Effect::StopCapture(capture)));
        assert!(!stop.iter().any(|e| matches!(e, Effect::FlushEngine(_))));
        assert!(s.accepts_segment(capture));
        assert_eq!(
            s.capture_stopped(capture),
            vec![Effect::FlushEngine(engine)]
        );
        assert!(s.capture_stopped(capture).is_empty());
        assert!(s.stop(1040.0).is_empty());
        assert_eq!(s.recorded_seconds(1040.0), 15.0);
        let finish = s.engine_flushed(engine, 1040.0);
        assert_eq!(finish.iter().filter(|e| **e == Effect::Finished).count(), 1);
        assert!(finish.contains(&Effect::AbortCapture(capture)));
        assert!(finish.contains(&Effect::TerminateEngine(engine)));
        assert!(s.engine_exited(engine, 0, 1041.0).is_empty());
        assert!(s.engine_flushed(engine, 1041.0).is_empty());
        assert_eq!(s.phase(), &Phase::Done);
        assert_eq!(s.recorded_seconds(9999.0), 15.0);
    }

    #[test]
    fn old_engine_exit_and_capture_completion_cannot_affect_replacement() {
        let mut s = Session::default();
        s.begin_live();
        let old_engine = s.engine_token().unwrap();
        let old_capture = s.capture_token().unwrap();
        s.engine_ready(old_engine);
        s.reset();
        s.begin_live();
        let engine = s.engine_token().unwrap();
        let capture = s.capture_token().unwrap();
        s.engine_ready(engine);
        s.capture_started(capture, Ok(()), 1000.0);
        assert_eq!(
            s.capture_started(old_capture, Ok(()), 1001.0),
            vec![Effect::AbortCapture(old_capture)]
        );
        assert!(s.engine_exited(old_engine, 9, 1001.0).is_empty());
        assert!(!s.accepts_segment(old_capture));
        assert!(s.accepts_segment(capture));
        s.pause(1002.0);
        assert!(
            s.replace_engine()
                .contains(&Effect::TerminateEngine(engine))
        );
        let replacement = s.engine_token().unwrap();
        assert!(s.engine_ready(replacement).is_empty());
        assert!(s.engine_exited(engine, 15, 1003.0).is_empty());
        assert_eq!(s.phase(), &Phase::Paused);
        assert_eq!(s.capture_token(), Some(capture));
        assert!(s.engine_event(replacement, true).0);
        assert!(!s.engine_event(engine, true).0);
    }

    #[test]
    fn startup_timeout_includes_suspended_capture_and_rejects_late_success() {
        for ready in [false, true] {
            let mut s = Session::default();
            let start = s.begin_live();
            let deadline = scheduled(&start, DeadlineKind::Startup);
            let engine = s.engine_token().unwrap();
            let capture = s.capture_token().unwrap();
            if ready {
                s.engine_ready(engine);
            }
            let failure = s.deadline_fired(deadline, 1045.0);
            assert!(failure.contains(&Effect::TerminateEngine(engine)));
            assert!(failure.contains(&Effect::AbortCapture(capture)));
            assert_eq!(s.phase(), &Phase::Error(Failure::StartupTimeout));
            if ready {
                assert_eq!(
                    s.capture_started(capture, Ok(()), 1046.0),
                    vec![Effect::AbortCapture(capture)]
                );
            }
            assert_eq!(s.phase(), &Phase::Error(Failure::StartupTimeout));
        }
    }

    #[test]
    fn flush_progress_refreshes_only_ordinary_events_and_ignores_cancelled_timer() {
        let (mut s, engine, _) = live();
        let old = scheduled(&s.stop(1005.0), DeadlineKind::Flush);
        assert!(s.engine_event(engine, false).1.is_empty());
        let (accepted, progress) = s.engine_event(engine, true);
        assert!(accepted);
        assert!(progress.contains(&Effect::CancelDeadline(old)));
        let new = scheduled(&progress, DeadlineKind::Flush);
        assert!(s.deadline_fired(old, 1050.0).is_empty());
        assert_eq!(s.phase(), &Phase::Flushing);
        let done = s.deadline_fired(new, 1055.0);
        assert_eq!(done.first(), Some(&Effect::FlushTimedOut));
        assert_eq!(done.last(), Some(&Effect::Finished));
        assert!(s.deadline_fired(new, 1056.0).is_empty());
    }

    #[test]
    fn cancelled_import_disposes_its_owned_temp_file_without_starting_or_failing_next() {
        let mut s = Session::default();
        let old = s
            .begin_file()
            .into_iter()
            .find_map(|e| {
                if let Effect::PrepareFile(t) = e {
                    Some(t)
                } else {
                    None
                }
            })
            .unwrap();
        s.reset();
        let next = s
            .begin_file()
            .into_iter()
            .find_map(|e| {
                if let Effect::PrepareFile(t) = e {
                    Some(t)
                } else {
                    None
                }
            })
            .unwrap();
        let old_file = PathBuf::from("old-owned-temp.wav");
        assert_eq!(
            s.file_prepared(old, Ok(old_file.clone()), 1.0),
            vec![Effect::RemovePreparedFile(old_file)]
        );
        assert!(
            s.file_prepared(old, Err("late failure".into()), 1.0)
                .is_empty()
        );
        assert_eq!(s.phase(), &Phase::Processing);
        let new_file = PathBuf::from("new-owned-temp.wav");
        s.file_prepared(next, Ok(new_file.clone()), 2.0);
        let engine = s.engine_token().unwrap();
        assert!(s.engine_ready(engine).is_empty());
        let finish = s.engine_exited(engine, 0, 3.0);
        assert!(finish.contains(&Effect::RemovePreparedFile(new_file)));
        assert_eq!(s.phase(), &Phase::Done);
    }

    #[test]
    fn failures_release_resources_and_terminal_callbacks_are_not_repeated() {
        let (mut s, engine, capture) = live();
        let failed = s.engine_exited(engine, 9, 1001.0);
        assert!(failed.contains(&Effect::AbortCapture(capture)));
        assert!(failed.contains(&Effect::TerminateEngine(engine)));
        assert_eq!(failed.last(), Some(&Effect::Failed));
        assert!(!s.accepts_segment(capture));
        assert!(!s.engine_event(engine, true).0);
        assert!(
            !s.fail(Failure::Message("later".into()), 1002.0)
                .contains(&Effect::Failed)
        );
        let (mut s, _, capture) = live();
        s.replace_engine();
        let replacement = s.engine_token().unwrap();
        let failed = s.engine_started(replacement, Err("launch".into()), 1002.0);
        assert!(failed.contains(&Effect::AbortCapture(capture)));
        assert!(failed.contains(&Effect::TerminateEngine(replacement)));
        assert_eq!(
            s.phase(),
            &Phase::Error(Failure::EngineStart("launch".into()))
        );
    }

    #[test]
    fn countdown_cancel_cannot_restart_and_paused_stop_excludes_pause_time() {
        let mut s = Session::default();
        let timer = scheduled(&s.begin_countdown(3), DeadlineKind::Countdown);
        s.cancel_countdown();
        assert!(s.deadline_fired(timer, 1.0).is_empty());
        assert_eq!(s.phase(), &Phase::Idle);
        let timer = scheduled(&s.begin_countdown(1), DeadlineKind::Countdown);
        assert_eq!(s.deadline_fired(timer, 2.0), vec![Effect::CountdownElapsed]);
        assert_eq!(s.phase(), &Phase::CountingDown(1));
        s.begin_live();
        let engine = s.engine_token().unwrap();
        let capture = s.capture_token().unwrap();
        s.engine_ready(engine);
        s.capture_started(capture, Ok(()), 1000.0);
        assert!(s.begin_countdown(3).is_empty());
        s.pause(1010.0);
        s.stop(1030.0);
        assert_eq!(s.recorded_seconds(1040.0), 10.0);
    }
}
