//! Serialized macOS capture -> owned WAV -> resident ASR executor.
//! The host resolves all paths/settings. No PCM or arbitrary path command is
//! exposed to a renderer. Native main-loop delivery must remain alive at exit.
use crate::{
    asr_config::{LiveSettings, Resources},
    audio_capture::{Capture, Event as CaptureEvent},
    capture_pipeline::{CapturePipeline, Event as PipelineEvent, OwnedWav},
    engine_process::{EngineProcess, Event as EngineEvent, Message},
};
use madi_core::{
    capture_stream,
    session::{Effect, Failure, Phase, Session, Token},
};
use madi_protocol::{stream::Output, transcribe};
use std::{collections::VecDeque, io, path::PathBuf, time::Duration};
use tokio::{
    sync::{mpsc, oneshot},
    task::JoinHandle,
    time::Instant,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RunId(u64);

#[derive(Debug)]
pub enum UpdateKind {
    #[cfg(test)]
    WatchdogChecked(usize),
    Phase(Phase),
    Output(Output),
    Capabilities(Vec<String>),
    Level(f32),
    Coverage {
        segments_in_flight: usize,
        gaps: Vec<f64>,
    },
    Recovery {
        attempts: usize,
        language_token: Option<i64>,
    },
    Segment {
        offset: f64,
        wav: OwnedWav,
        had_speech: bool,
    },
    /// Mutable preview slots, not committed audio. Product preview admission
    /// (language lock, busy lane, forced prefix) is a separate host policy.
    Preview {
        offset: f64,
        wav: OwnedWav,
    },
    CaptureInterrupted(String),
    WriteFailed {
        name: String,
        preview: bool,
        message: String,
    },
    RecordingStarted,
    RecordedSeconds(f64),
    FlushTimedOut,
    Finished,
    Failed,
    Fault(String),
}
#[derive(Debug)]
pub struct Update {
    pub run: RunId,
    pub kind: UpdateKind,
}

#[derive(Clone)]
pub struct Configuration {
    pub resources: Resources,
    pub scratch_parent: PathBuf,
    #[cfg(test)]
    pub wall_clock: Option<std::sync::Arc<std::sync::atomic::AtomicU64>>,
}

pub enum Input {
    Devices {
        device: Option<u32>,
    },
    /// Converter/engine verification only; never offered by renderer IPC.
    #[cfg(debug_assertions)]
    Replay {
        path: PathBuf,
        chunk_frames: u32,
    },
    #[cfg(test)]
    Scripted(tests::Scripted),
}
pub struct Request {
    pub settings: LiveSettings,
    /// Native preferences/glossary snapshot at replacement time, never renderer
    /// executable/path input. Standalone replay callers can retain initial settings.
    pub recovery_settings: Option<RecoverySettings>,
    #[cfg(test)]
    pub wall_clock: Option<std::sync::Arc<std::sync::atomic::AtomicU64>>,
    pub capture: capture_stream::Configuration,
    pub input: Input,
}
pub type RecoverySettings = std::sync::Arc<dyn Fn() -> io::Result<LiveSettings> + Send + Sync>;
enum Command {
    Start(Request, oneshot::Sender<io::Result<Option<RunId>>>),
    Pause(RunId),
    Resume(RunId),
    Stop(RunId),
    InputDevice(RunId, Option<u32>),
    Preview {
        run: RunId,
        wav: OwnedWav,
        forced: String,
        reply: oneshot::Sender<io::Result<bool>>,
    },
    Reset(oneshot::Sender<()>),
    Shutdown,
}
pub struct LiveSession {
    commands: mpsc::UnboundedSender<Command>,
    updates: mpsc::UnboundedReceiver<Update>,
    task: Option<JoinHandle<io::Result<()>>>,
}
impl LiveSession {
    pub fn new(configuration: Configuration) -> io::Result<Self> {
        tokio::runtime::Handle::try_current().map_err(io::Error::other)?;
        let (commands, input) = mpsc::unbounded_channel();
        let (output, updates) = mpsc::unbounded_channel();
        let watchdog = madi_core::hang_watchdog::Watchdog::new(wall_seconds(&configuration));
        let task = tokio::spawn(
            Worker {
                configuration,
                input,
                output,
                core: Session::default(),
                phase: Phase::Idle,
                run: RunId(0),
                started: Instant::now(),
                request: None,
                engine: None,
                capture: None,
                pipeline: None,
                processing: None,
                retained: Vec::new(),
                deadline: None,
                flush_sent: None,
                pipeline_token: None,
                clock_tick: None,
                coverage: Default::default(),
                watchdog,
                watchdog_tick: None,
                preview_lease: None,
                language_locked: false,
                preview_forced_prefix: false,
            }
            .execute(),
        );
        Ok(Self {
            commands,
            updates,
            task: Some(task),
        })
    }
    pub async fn start(&self, request: Request) -> io::Result<Option<RunId>> {
        let (reply, received) = oneshot::channel();
        self.commands
            .send(Command::Start(request, reply))
            .map_err(|_| closed())?;
        received.await.map_err(|_| closed())?
    }
    pub fn pause(&self, run: RunId) -> io::Result<()> {
        self.commands
            .send(Command::Pause(run))
            .map_err(|_| closed())
    }
    pub fn resume(&self, run: RunId) -> io::Result<()> {
        self.commands
            .send(Command::Resume(run))
            .map_err(|_| closed())
    }
    pub fn stop(&self, run: RunId) -> io::Result<()> {
        self.commands.send(Command::Stop(run)).map_err(|_| closed())
    }
    pub fn switch_input(&self, run: RunId, device: Option<u32>) -> io::Result<()> {
        self.commands
            .send(Command::InputDevice(run, device))
            .map_err(|_| closed())
    }
    /// Only an owned capture lease can cross this boundary. Renderer paths and
    /// retired runs cannot submit a PREVIEW or compete with committed work.
    pub(crate) async fn preview(
        &self,
        run: RunId,
        wav: OwnedWav,
        forced: String,
    ) -> io::Result<bool> {
        let (reply, received) = oneshot::channel();
        self.commands
            .send(Command::Preview {
                run,
                wav,
                forced,
                reply,
            })
            .map_err(|_| closed())?;
        received.await.map_err(|_| closed())?
    }
    /// Ack follows native stop, engine reap and release of this owner's WAVs.
    /// Other native consumers can retain explicit OwnedWav leases after reset.
    pub async fn reset(&self) -> io::Result<()> {
        let (reply, received) = oneshot::channel();
        self.commands
            .send(Command::Reset(reply))
            .map_err(|_| closed())?;
        received.await.map_err(|_| closed())
    }
    pub async fn next(&mut self) -> Option<Update> {
        self.updates.recv().await
    }
    pub async fn shutdown(&mut self) -> io::Result<()> {
        let _ = self.commands.send(Command::Shutdown);
        let result = match self.task.as_mut() {
            Some(task) => task.await,
            None => return Ok(()),
        };
        self.task.take();
        result.map_err(io::Error::other)?
    }
}
impl Drop for LiveSession {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Shutdown);
    }
}
fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "live session closed")
}

enum CapturePort {
    Native(Capture),
    #[cfg(test)]
    Scripted(tests::Scripted),
}
impl CapturePort {
    fn start(request: &mut Request) -> io::Result<Self> {
        match &mut request.input {
            Input::Devices { device } => {
                Capture::start(request.capture.source, *device).map(Self::Native)
            }
            #[cfg(debug_assertions)]
            Input::Replay { path, chunk_frames } => {
                Capture::replay(path, *chunk_frames).map(Self::Native)
            }
            #[cfg(test)]
            Input::Scripted(port) => Ok(Self::Scripted(port.take())),
        }
    }
    async fn next(&mut self) -> Option<CaptureEvent> {
        match self {
            Self::Native(capture) => capture.next().await,
            #[cfg(test)]
            Self::Scripted(port) => port.events.as_mut().unwrap().recv().await,
        }
    }
    fn control(&mut self, control: Control) {
        match self {
            Self::Native(capture) => match control {
                Control::Pause => capture.pause(),
                Control::Resume => capture.resume(),
                Control::Stop => capture.stop(),
                Control::InputDevice(device) => capture.switch_input(device),
            },
            #[cfg(test)]
            Self::Scripted(port) => {
                let _ = port.controls.send(control);
            }
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Control {
    Pause,
    Resume,
    Stop,
    InputDevice(Option<u32>),
}

struct Processing {
    token: Token,
    tail: bool,
    task: JoinHandle<(CapturePipeline, Vec<PipelineEvent>)>,
}
struct Worker {
    configuration: Configuration,
    input: mpsc::UnboundedReceiver<Command>,
    output: mpsc::UnboundedSender<Update>,
    core: Session,
    phase: Phase,
    run: RunId,
    started: Instant,
    request: Option<Request>,
    engine: Option<(Token, EngineProcess)>,
    capture: Option<(Token, CapturePort)>,
    pipeline: Option<CapturePipeline>,
    processing: Option<Processing>,
    retained: Vec<OwnedWav>,
    deadline: Option<(Token, Instant)>,
    flush_sent: Option<Token>,
    pipeline_token: Option<Token>,
    clock_tick: Option<Instant>,
    coverage: madi_core::coverage::Coverage<OwnedWav>,
    watchdog: madi_core::hang_watchdog::Watchdog,
    watchdog_tick: Option<Instant>,
    preview_lease: Option<OwnedWav>,
    language_locked: bool,
    preview_forced_prefix: bool,
}
fn wall_seconds(configuration: &Configuration) -> f64 {
    #[cfg(test)]
    if let Some(clock) = &configuration.wall_clock {
        return f64::from_bits(clock.load(std::sync::atomic::Ordering::SeqCst));
    }
    let _ = configuration;
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or_else(|e| -e.duration().as_secs_f64(), |v| v.as_secs_f64())
}
impl Worker {
    async fn watchdog_tick(&mut self) -> io::Result<()> {
        if !self.watchdog.tick(
            self.core.phase(),
            self.coverage.oldest_fed_at(),
            wall_seconds(&self.configuration),
        ) {
            return Ok(());
        }
        let request = self
            .request
            .as_mut()
            .ok_or_else(|| io::Error::other("missing recovery request"))?;
        if let Some(settings) = &request.recovery_settings {
            request.settings = settings()?;
        }
        self.emit(UpdateKind::Recovery {
            attempts: self.watchdog.recoveries,
            language_token: self
                .request
                .as_ref()
                .unwrap()
                .settings
                .common
                .language_token,
        });
        let effects = self.core.replace_engine();
        self.effects(effects).await?;
        // Launch failure has already retired capture/queue and emitted Failed.
        if !matches!(self.core.phase(), Phase::Recording | Phase::Paused) {
            return Ok(());
        }
        for job in self.coverage.refeed(wall_seconds(&self.configuration)) {
            let path = job
                .audio
                .path()
                .to_str()
                .ok_or_else(|| io::Error::other("non UTF-8 recovery WAV"))?;
            let (_, engine) = self
                .engine
                .as_ref()
                .ok_or_else(|| io::Error::other("missing recovery engine"))?;
            engine.send_line(&format!("{:.3} {path}", job.offset))?;
        }
        Ok(())
    }
    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }
    fn emit(&self, kind: UpdateKind) {
        let _ = self.output.send(Update {
            run: self.run,
            kind,
        });
    }
    fn emit_coverage(&self) {
        self.emit(UpdateKind::Coverage {
            segments_in_flight: self.coverage.pending(),
            gaps: self.coverage.gaps.clone(),
        });
    }
    fn phase_changed(&mut self) {
        if self.phase != *self.core.phase() {
            self.phase = self.core.phase().clone();
            self.emit(UpdateKind::Phase(self.phase.clone()));
            self.emit(UpdateKind::RecordedSeconds(
                self.core.recorded_seconds(self.now()),
            ));
            self.clock_tick =
                (self.phase == Phase::Recording).then(|| Instant::now() + Duration::from_secs(1));
        }
    }
    async fn execute(mut self) -> io::Result<()> {
        let result = self.run_loop().await;
        let effects = self.core.reset();
        let cleanup = self.effects(effects).await;
        // Even a task failure must reap before releasing the last directory owner.
        self.coverage.retire_pending();
        self.emit_coverage();
        self.retained.clear();
        self.pipeline.take();
        self.request.take();
        if let Err(error) = result.and(cleanup) {
            let _ = self
                .core
                .fail(Failure::Message(error.to_string()), self.now());
            self.phase_changed();
            self.emit(UpdateKind::Fault(error.to_string()));
            return Err(error);
        }
        self.phase_changed();
        Ok(())
    }
    async fn run_loop(&mut self) -> io::Result<()> {
        loop {
            let capturing = self.capture.is_some() && self.processing.is_none();
            let processing = self.processing.is_some();
            let running = self.engine.is_some();
            let deadline = self.deadline;
            let clock_tick = self.clock_tick;
            let watchdog_tick = self.watchdog_tick;
            tokio::select! {
                command = self.input.recv() => match command {
                    Some(Command::Start(request, reply)) => {
                        if !self.core.can_start() { let _ = reply.send(Ok(None)); continue; }
                        // Retire the old run before installing any replacement paths.
                        let effects = self.core.reset(); self.effects(effects).await?;
                        self.pipeline.take(); self.retained.clear(); self.request.take();
                        self.preview_lease.take(); self.coverage=Default::default();
                        self.watchdog.recoveries=0; self.watchdog_tick=None;
                        self.language_locked=request.settings.common.language_token.is_some();
                        self.preview_forced_prefix=false;
                        let config = request.capture.clone();
                        let parent = self.configuration.scratch_parent.clone();
                        let pipeline = tokio::task::spawn_blocking(move || CapturePipeline::new(config, &parent)).await.map_err(io::Error::other)?;
                        let pipeline = match pipeline { Ok(p) => p, Err(e) => { self.phase_changed(); let _ = reply.send(Err(e)); continue; } };
                        self.run.0 = self.run.0.checked_add(1).ok_or_else(|| io::Error::other("live run identity exhausted"))?;
                        self.watchdog_tick=Some(Instant::now()+Duration::from_secs(5));
                        self.emit_coverage();
                        self.pipeline = Some(pipeline); self.request = Some(request); self.flush_sent = None;
                        let effects = self.core.begin_live(); self.pipeline_token = self.core.capture_token(); self.phase_changed(); self.effects(effects).await?; self.phase_changed();
                        let _ = reply.send(Ok(Some(self.run)));
                    }
                    Some(Command::Pause(run)) if run == self.run => { let effects = self.core.pause(self.now()); self.effects(effects).await?; self.phase_changed(); }
                    Some(Command::Resume(run)) if run == self.run => { let effects = self.core.resume(self.now()); self.effects(effects).await?; self.phase_changed(); }
                    Some(Command::Stop(run)) if run == self.run => { let effects = self.core.stop(self.now()); self.effects(effects).await?; self.phase_changed(); }
                    Some(Command::InputDevice(run,device)) if run==self.run && matches!(self.core.phase(),Phase::Recording|Phase::Paused)=>{
                        if let Some((_,capture))=&mut self.capture {capture.control(Control::InputDevice(device));}
                    }
                    Some(Command::Pause(_) | Command::Resume(_) | Command::Stop(_) | Command::InputDevice(..)) => {}
                    Some(Command::Preview {run,wav,forced,reply}) => {
                        let result=self.submit_preview(run,wav,&forced);
                        let _=reply.send(result);
                    }
                    Some(Command::Reset(reply)) => {
                        let effects = self.core.reset(); self.effects(effects).await?;
                        self.retained.clear(); self.pipeline.take(); self.request.take(); self.flush_sent = None;
                        self.coverage=Default::default(); self.emit_coverage();
                        self.watchdog_tick=None;
                        self.phase_changed(); let _ = reply.send(());
                    }
                    Some(Command::Shutdown) | None => return Ok(()),
                },
                event = async { let (token, capture) = self.capture.as_mut().unwrap(); (*token, capture.next().await) }, if capturing => {
                    let event_value = event.1.ok_or_else(|| io::Error::other("capture ended without Stopped"))?;
                    self.capture_event(event.0, event_value).await?; self.phase_changed();
                },
                result = async { (&mut self.processing.as_mut().unwrap().task).await }, if processing => {
                    let work = self.processing.take().unwrap();
                    let (pipeline, events) = result.map_err(io::Error::other)?;
                    self.pipeline = Some(pipeline);
                    self.pipeline_events(work.token, events)?;
                    if work.tail { let effects = self.core.capture_stopped(work.token); self.effects(effects).await?; }
                    self.phase_changed();
                },
                message = async { self.engine.as_mut().unwrap().1.next().await }, if running => {
                    let message = message.ok_or_else(|| io::Error::other("engine ended without Terminated"))?;
                    self.engine_event(message).await?; self.phase_changed();
                },
                _ = async { tokio::time::sleep_until(deadline.unwrap().1).await }, if deadline.is_some() => {
                    self.deadline = None;
                    let effects = self.core.deadline_fired(deadline.unwrap().0, self.now());
                    self.effects(effects).await?; self.phase_changed();
                },
                _ = self.output.closed() => return Ok(()),
                _ = async { tokio::time::sleep_until(watchdog_tick.unwrap()).await }, if watchdog_tick.is_some() => {
                    self.watchdog_tick=Some(Instant::now()+Duration::from_secs(5));
                    self.watchdog_tick().await?;
                    #[cfg(test)]
                    self.emit(UpdateKind::WatchdogChecked(self.watchdog.recoveries));
                },
                _ = async { tokio::time::sleep_until(clock_tick.unwrap()).await }, if clock_tick.is_some() => {
                    self.emit(UpdateKind::RecordedSeconds(self.core.recorded_seconds(self.now())));
                    self.clock_tick = Some(Instant::now() + Duration::from_secs(1));
                },
            }
        }
    }
    fn process(&mut self, token: Token, samples: Option<(Vec<i16>, bool)>) -> io::Result<()> {
        let mut pipeline = self
            .pipeline
            .take()
            .ok_or_else(|| io::Error::other("missing live pipeline"))?;
        let tail = samples.is_none();
        self.processing = Some(Processing {
            token,
            tail,
            task: tokio::task::spawn_blocking(move || {
                let events = match samples {
                    Some((pcm, microphone)) => pipeline.ingest(&pcm, microphone),
                    None => pipeline.stop(),
                };
                (pipeline, events)
            }),
        });
        Ok(())
    }
    fn submit_preview(&mut self, run: RunId, wav: OwnedWav, forced: &str) -> io::Result<bool> {
        if run != self.run
            || *self.core.phase() != Phase::Recording
            || !self.language_locked
            || self.coverage.pending() != 0
            || self.preview_lease.is_some()
            || !self
                .request
                .as_ref()
                .is_some_and(|request| request.capture.preview_enabled)
        {
            return Ok(false);
        }
        // processing owns the pipeline during WAV publication; the root itself
        // is independently retained by the request's immutable segment leases.
        let expected = self
            .pipeline
            .as_ref()
            .map(CapturePipeline::directory)
            .or_else(|| self.retained.first().map(OwnedWav::directory));
        if expected != Some(wav.directory()) {
            return Ok(false);
        }
        let path = wav
            .path()
            .to_str()
            .ok_or_else(|| io::Error::other("non UTF-8 preview WAV"))?;
        let one = forced.replace('\n', " ");
        // Foundation whitespacesAndNewlines additionally includes U+200B.
        let one = one.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}');
        // EngineProcess rejects protocol controls even if a future hypothesis
        // includes CR/NUL; those hypotheses fall back to an unforced preview.
        let suffix = if self.preview_forced_prefix
            && !one.is_empty()
            && !one.contains("%%FP")
            && !one.contains(['\r', '\0'])
        {
            format!(" %%FP {one}")
        } else {
            String::new()
        };
        self.engine
            .as_ref()
            .ok_or_else(|| io::Error::other("missing preview engine"))?
            .1
            .send_line(&format!("PREVIEW {path}{suffix}"))?;
        self.preview_lease = Some(wav);
        Ok(true)
    }
    async fn capture_event(&mut self, token: Token, event: CaptureEvent) -> io::Result<()> {
        let effects = match event {
            CaptureEvent::Started => self.core.capture_started(token, Ok(()), self.now()),
            CaptureEvent::Samples { microphone, pcm } => {
                if self.core.accepts_segment(token) {
                    self.process(token, Some((pcm, microphone)))?;
                }
                Vec::new()
            }
            CaptureEvent::Paused | CaptureEvent::Resumed => {
                if self.core.capture_token() == Some(token)
                    && let Some(pipeline) = &mut self.pipeline
                {
                    if event == CaptureEvent::Paused {
                        pipeline.pause();
                    } else {
                        pipeline.resume();
                    }
                }
                Vec::new()
            }
            CaptureEvent::Stopped => {
                self.capture.take();
                // Replay EOF and device EOF follow the same graceful stop path.
                if matches!(self.core.phase(), Phase::Recording | Phase::Paused) {
                    let effects = self.core.stop(self.now());
                    self.effects(effects).await?;
                }
                if *self.core.phase() == Phase::Flushing && self.core.capture_token() == Some(token)
                {
                    self.process(token, None)?;
                    Vec::new()
                } else {
                    self.core.capture_started(
                        token,
                        Err("capture stopped before readiness".into()),
                        self.now(),
                    )
                }
            }
            CaptureEvent::Fault(message) => {
                if self.core.capture_token() != Some(token) {
                    return Ok(());
                }
                if matches!(self.core.phase(), Phase::Recording | Phase::Paused) {
                    self.emit(UpdateKind::CaptureInterrupted(message));
                    self.core.stop(self.now())
                } else {
                    self.core.fail(Failure::CaptureStart(message), self.now())
                }
            }
        };
        self.effects(effects).await
    }
    fn pipeline_events(&mut self, token: Token, events: Vec<PipelineEvent>) -> io::Result<()> {
        for event in events {
            match event {
                PipelineEvent::Segment {
                    offset,
                    wav,
                    had_speech,
                } if self.core.accepts_segment(token) => {
                    // Both the pipeline and each immutable segment lease retain
                    // the validated root until the child has been reaped.
                    let path = wav
                        .path()
                        .to_str()
                        .ok_or_else(|| io::Error::other("non UTF-8 live WAV"))?;
                    let engine = &self
                        .engine
                        .as_ref()
                        .ok_or_else(|| io::Error::other("missing live engine"))?
                        .1;
                    engine.send_line(&format!("{offset:.3} {path}"))?;
                    self.coverage.feed(
                        offset,
                        wav.clone(),
                        had_speech,
                        wall_seconds(&self.configuration),
                    );
                    self.emit_coverage();
                    self.retained.push(wav.clone());
                    self.emit(UpdateKind::Segment {
                        offset,
                        wav,
                        had_speech,
                    });
                }
                PipelineEvent::Level(level) if self.core.accepts_preview_or_level(token) => {
                    self.emit(UpdateKind::Level(level))
                }
                PipelineEvent::Preview { offset, wav }
                    if self.core.accepts_preview_or_level(token) =>
                {
                    self.emit(UpdateKind::Preview { offset, wav })
                }
                PipelineEvent::WriteFailed {
                    name,
                    preview,
                    error,
                } if self.core.accepts_segment(token) => self.emit(UpdateKind::WriteFailed {
                    name,
                    preview,
                    message: error.to_string(),
                }),
                _ => {}
            }
        }
        Ok(())
    }
    async fn engine_event(&mut self, message: Message) -> io::Result<()> {
        let token = message.token;
        if self.core.engine_token() != Some(token) {
            return Ok(());
        }
        // EngineProcess dispatches these through SessionController.engine(didEmit:).
        // READY, FLUSH_END, diagnostics, capabilities, JSONL and exit are separate
        // callbacks in Swift and must not disguise a hung committed job.
        if matches!(&message.event, EngineEvent::Protocol(Output::Stdout(event))
            if !matches!(event, transcribe::Event::Ready | transcribe::Event::FlushEnd | transcribe::Event::Other(_)))
        {
            self.watchdog.activity(wall_seconds(&self.configuration));
        }
        // Swift stop() is synchronous. The async port must not accept an early
        // engine acknowledgement while native capture/tail delivery is pending.
        let premature = *self.core.phase() == Phase::Flushing && self.flush_sent != Some(token);
        let effects = match message.event {
            EngineEvent::Protocol(Output::Stdout(transcribe::Event::Ready)) => {
                self.core.engine_ready(token)
            }
            EngineEvent::Protocol(Output::Stdout(transcribe::Event::FlushEnd)) if premature => {
                self.core.fail(
                    Failure::Message("engine flushed before capture tail was delivered".into()),
                    self.now(),
                )
            }
            EngineEvent::Protocol(Output::Terminated(0)) if premature => self.core.fail(
                Failure::Message("engine exited before capture tail was delivered".into()),
                self.now(),
            ),
            EngineEvent::Protocol(Output::Stdout(transcribe::Event::FlushEnd)) => {
                self.core.engine_flushed(token, self.now())
            }
            EngineEvent::Protocol(Output::Terminated(code)) => {
                self.core.engine_exited(token, code, self.now())
            }
            EngineEvent::Protocol(output) => {
                match &output {
                    Output::Stdout(transcribe::Event::LanguageDetected(_)) => {
                        self.language_locked = true
                    }
                    Output::Stdout(transcribe::Event::Word { .. }) => self.coverage.word(),
                    Output::Stdout(transcribe::Event::SegmentEnd) => {
                        if let Some(retry) =
                            self.coverage.segment_end(wall_seconds(&self.configuration))
                        {
                            let path = retry
                                .audio
                                .path()
                                .to_str()
                                .ok_or_else(|| io::Error::other("non UTF-8 live WAV"))?;
                            let (_, engine) = self
                                .engine
                                .as_ref()
                                .ok_or_else(|| io::Error::other("missing live retry engine"))?;
                            engine.send_line(&format!("{:.3} {path}", retry.offset))?;
                        }
                        self.emit_coverage();
                    }
                    Output::Stdout(transcribe::Event::PreviewEnd) => {
                        self.preview_lease.take();
                    }
                    _ => (),
                }
                let ordinary = matches!(&output, Output::Stdout(event) if !matches!(event, transcribe::Event::Other(_)));
                let (accepted, effects) = self.core.engine_event(token, ordinary);
                if accepted {
                    self.emit(UpdateKind::Output(output));
                }
                effects
            }
            EngineEvent::Capabilities(caps) => {
                self.preview_forced_prefix = caps.iter().any(|cap| cap == "preview-fp");
                self.emit(UpdateKind::Capabilities(caps));
                Vec::new()
            }
            EngineEvent::IoFailure { operation, message } => self.core.fail(
                Failure::Message(format!("{operation}: {message}")),
                self.now(),
            ),
        };
        self.effects(effects).await
    }
    async fn abort_capture(&mut self, token: Token) -> io::Result<()> {
        if self.pipeline_token != Some(token) {
            return Ok(());
        }
        let mut fault = None;
        if self.capture.as_ref().is_some_and(|(t, _)| *t == token) {
            let (_, mut capture) = self.capture.take().unwrap();
            capture.control(Control::Stop);
            let drained = tokio::time::timeout(Duration::from_secs(45), async {
                let mut failure = None;
                while let Some(event) = capture.next().await {
                    if let CaptureEvent::Fault(message) = &event {
                        failure.get_or_insert(io::Error::other(message.clone()));
                    }
                    if event == CaptureEvent::Stopped {
                        return failure.map_or(Ok(()), Err);
                    }
                }
                Err(io::Error::other("aborted capture ended without Stopped"))
            })
            .await;
            if let Err(error) = drained.unwrap_or_else(|_| {
                Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "native capture teardown timed out",
                ))
            }) {
                fault = Some(error);
            }
        }
        if self
            .processing
            .as_ref()
            .is_some_and(|work| work.token == token)
        {
            let work = self.processing.take().unwrap();
            match work.task.await {
                Ok((pipeline, _)) => self.pipeline = Some(pipeline),
                Err(error) => {
                    fault.get_or_insert(io::Error::other(error));
                }
            }
        }
        if let Some(pipeline) = &mut self.pipeline {
            pipeline.abort();
        }
        match fault {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }
    async fn effects(&mut self, effects: Vec<Effect>) -> io::Result<()> {
        let mut pending = VecDeque::from(effects);
        let mut fault = None;
        while let Some(effect) = pending.pop_front() {
            let result = match effect {
                Effect::StartEngine { token, file: None } => {
                    self.preview_forced_prefix = false;
                    let launched = self
                        .configuration
                        .resources
                        .live_launch(
                            self.pipeline
                                .as_ref()
                                .map(CapturePipeline::directory)
                                .or_else(|| self.retained.first().map(OwnedWav::directory))
                                .ok_or_else(|| io::Error::other("missing capture root"))?,
                            &self
                                .request
                                .as_ref()
                                .ok_or_else(|| io::Error::other("missing live request"))?
                                .settings,
                        )
                        .and_then(|launch| {
                            EngineProcess::spawn(launch, token, &self.configuration.scratch_parent)
                        });
                    let outcome = match launched {
                        Ok(engine) => {
                            self.engine = Some((token, engine));
                            Ok(())
                        }
                        Err(error) => Err(error.to_string()),
                    };
                    pending.extend(self.core.engine_started(token, outcome, self.now()));
                    Ok(())
                }
                Effect::StartCapture(token) => {
                    self.pipeline
                        .as_mut()
                        .ok_or_else(|| io::Error::other("missing capture pipeline"))?
                        .start();
                    match CapturePort::start(
                        self.request
                            .as_mut()
                            .ok_or_else(|| io::Error::other("missing capture request"))?,
                    ) {
                        Ok(capture) => self.capture = Some((token, capture)),
                        Err(error) => pending.extend(self.core.capture_started(
                            token,
                            Err(error.to_string()),
                            self.now(),
                        )),
                    }
                    Ok(())
                }
                Effect::PauseCapture(token)
                | Effect::ResumeCapture(token)
                | Effect::StopCapture(token) => {
                    if let Some((current, capture)) = &mut self.capture
                        && *current == token
                    {
                        capture.control(match effect {
                            Effect::PauseCapture(_) => Control::Pause,
                            Effect::ResumeCapture(_) => Control::Resume,
                            _ => Control::Stop,
                        });
                    }
                    Ok(())
                }
                // Cancellation of an in-flight start and abort name the same
                // unique port; draining it once makes the second effect a no-op.
                Effect::CancelCaptureStart(token) | Effect::AbortCapture(token) => {
                    self.abort_capture(token).await
                }
                Effect::TerminateEngine(token) => {
                    if self
                        .engine
                        .as_ref()
                        .is_some_and(|(current, _)| *current == token)
                    {
                        let (_, mut engine) = self.engine.take().unwrap();
                        engine.terminate();
                        let mut result = engine.wait().await;
                        while let Some(message) = engine.next().await {
                            if let EngineEvent::IoFailure { operation, message } = message.event {
                                result = result
                                    .and(Err(io::Error::other(format!("{operation}: {message}"))));
                            }
                        }
                        self.preview_lease.take();
                        result
                    } else {
                        Ok(())
                    }
                }
                Effect::FlushEngine(token) => {
                    if let Some((current, engine)) = &self.engine
                        && *current == token
                    {
                        engine.send_line("FLUSH")?;
                        self.flush_sent = Some(token);
                    }
                    Ok(())
                }
                Effect::Schedule { token, seconds, .. } => {
                    self.deadline = Some((
                        token,
                        Instant::now() + Duration::from_secs(u64::from(seconds)),
                    ));
                    Ok(())
                }
                Effect::CancelDeadline(token) => {
                    if self.deadline.is_some_and(|(current, _)| current == token) {
                        self.deadline = None;
                    }
                    Ok(())
                }
                Effect::RecordingStarted => {
                    self.phase_changed();
                    self.emit(UpdateKind::RecordingStarted);
                    Ok(())
                }
                Effect::FlushTimedOut => {
                    self.emit(UpdateKind::FlushTimedOut);
                    Ok(())
                }
                Effect::Finished | Effect::Failed => {
                    self.watchdog_tick = None;
                    self.coverage.retire_pending();
                    self.emit_coverage();
                    if fault.is_none() {
                        self.phase_changed();
                        self.emit(if effect == Effect::Finished {
                            UpdateKind::Finished
                        } else {
                            UpdateKind::Failed
                        });
                    }
                    Ok(())
                }
                _ => Err(io::Error::other("non-live effect reached live executor")),
            };
            if let Err(error) = result {
                fault.get_or_insert(error);
            }
        }
        match fault {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }
}

#[cfg(test)]
pub(crate) mod tests;
