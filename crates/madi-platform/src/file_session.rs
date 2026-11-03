//! Serialized file-transcription effect executor. Native paths and resources
//! are provided by the host; this module exposes no arbitrary-path web command.
use crate::{
    asr_config::{FileSettings, Resources},
    engine_process::{EngineProcess, Event, Message},
    prepared_audio::{DecodeTask, PreparedRegistry},
};
use madi_core::session::{Effect, Failure, Phase, Session, Token};
use madi_protocol::{stream::Output, transcribe};
use std::{collections::VecDeque, io, path::PathBuf};
use tokio::{
    sync::{mpsc, oneshot},
    task::JoinHandle,
    time::Instant,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RunId(u64);

#[derive(Debug, PartialEq)]
pub enum UpdateKind {
    Phase(Phase),
    Output(Output),
    Capabilities(Vec<String>),
    Finished,
    Failed,
    /// Internal teardown/transport fault, for localized product error mapping.
    Fault(String),
}

#[derive(Debug, PartialEq)]
pub struct Update {
    pub run: RunId,
    pub kind: UpdateKind,
}

pub struct Configuration {
    pub resources: Resources,
    pub decoder: PathBuf,
    pub scratch_parent: PathBuf,
}

enum Command {
    Start {
        original: PathBuf,
        settings: FileSettings,
        reply: oneshot::Sender<Option<RunId>>,
    },
    Reset(oneshot::Sender<()>),
    Shutdown,
}

pub struct FileSession {
    commands: mpsc::UnboundedSender<Command>,
    updates: mpsc::UnboundedReceiver<Update>,
    task: Option<JoinHandle<io::Result<()>>>,
}

impl FileSession {
    pub fn new(configuration: Configuration) -> io::Result<Self> {
        tokio::runtime::Handle::try_current().map_err(io::Error::other)?;
        let (commands, input) = mpsc::unbounded_channel();
        let (output, updates) = mpsc::unbounded_channel();
        let task = tokio::spawn(
            Worker {
                configuration,
                input,
                output,
                core: Session::default(),
                run: RunId(0),
                phase: Phase::Idle,
                started: Instant::now(),
                request: None,
                preparation: None,
                engine: None,
                prepared: PreparedRegistry::default(),
            }
            .execute(),
        );
        Ok(Self {
            commands,
            updates,
            task: Some(task),
        })
    }

    /// Returns None while another file is processing. Reset first to replace it.
    pub async fn start(
        &self,
        original: PathBuf,
        settings: FileSettings,
    ) -> io::Result<Option<RunId>> {
        let (reply, received) = oneshot::channel();
        self.commands
            .send(Command::Start {
                original,
                settings,
                reply,
            })
            .map_err(|_| closed())?;
        received.await.map_err(|_| closed())
    }

    /// Acknowledged only after decoder/engine teardown and owned-file removal.
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

    /// Await during application exit while the Tokio runtime is still alive.
    /// Cancelling this await retains the handle for a later cleanup wait.
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
impl Drop for FileSession {
    fn drop(&mut self) {
        // Do not abort the worker: it must reap the child before dropping WAVs.
        let _ = self.commands.send(Command::Shutdown);
    }
}
fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "file session closed")
}

struct Worker {
    configuration: Configuration,
    input: mpsc::UnboundedReceiver<Command>,
    output: mpsc::UnboundedSender<Update>,
    core: Session,
    run: RunId,
    phase: Phase,
    started: Instant,
    request: Option<(PathBuf, FileSettings)>,
    preparation: Option<(Token, DecodeTask)>,
    engine: Option<(Token, EngineProcess)>,
    prepared: PreparedRegistry,
}

impl Worker {
    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }
    fn emit(&self, kind: UpdateKind) {
        let _ = self.output.send(Update {
            run: self.run,
            kind,
        });
    }
    fn phase_changed(&mut self) {
        if self.phase != *self.core.phase() {
            self.phase = self.core.phase().clone();
            self.emit(UpdateKind::Phase(self.phase.clone()));
        }
    }

    async fn execute(mut self) -> io::Result<()> {
        let result = self.run_loop().await;
        // This finally-style cleanup runs on normal shutdown, dropped receivers,
        // command closure and executor errors. Never drop a registry first.
        let effects = self.core.reset();
        let cleanup = self.effects(effects).await;
        if let Err(error) = result.and(cleanup) {
            // Resource identities have been released; retain an error phase
            // instead of making failed teardown look like a successful reset.
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
            let preparing = self.preparation.is_some();
            let running = self.engine.is_some();
            tokio::select! {
                command = self.input.recv() => match command {
                    Some(Command::Start { original, settings, reply }) => {
                        if !self.core.can_start() { let _ = reply.send(None); continue; }
                        self.run.0 = self.run.0.checked_add(1).ok_or_else(|| io::Error::other("file run identity exhausted"))?;
                        self.request = Some((original, settings));
                        let effects = self.core.begin_file();
                        self.phase_changed();
                        self.effects(effects).await?;
                        self.phase_changed();
                        let _ = reply.send(Some(self.run));
                    }
                    Some(Command::Reset(reply)) => {
                        let effects = self.core.reset();
                        self.effects(effects).await?;
                        self.request = None;
                        self.phase_changed();
                        let _ = reply.send(());
                    }
                    Some(Command::Shutdown) | None => return Ok(()),
                },
                decoded = async {
                    let (token, task) = self.preparation.as_mut().expect("guarded preparation");
                    (*token, task.wait().await)
                }, if preparing => {
                    self.preparation.take();
                    let result = decoded.1.map(|audio| self.prepared.insert(audio)).map_err(|error| error.to_string());
                    let effects = self.core.file_prepared(decoded.0, result, self.now());
                    self.effects(effects).await?;
                    self.phase_changed();
                },
                message = async { self.engine.as_mut().expect("guarded engine").1.next().await }, if running => {
                    let Some(message) = message else {
                        // A successful engine stream always ends with Terminated.
                        return Err(io::Error::other("engine transport ended without a termination event"));
                    };
                    self.receive(message).await?;
                    self.phase_changed();
                },
                _ = self.output.closed() => return Ok(()),
            }
        }
    }

    async fn receive(&mut self, message: Message) -> io::Result<()> {
        let token = message.token;
        let effects = match message.event {
            Event::Protocol(Output::Stdout(transcribe::Event::Ready)) => {
                self.core.engine_ready(token)
            }
            Event::Protocol(Output::Stdout(transcribe::Event::FlushEnd)) => {
                self.core.engine_flushed(token, self.now())
            }
            Event::Protocol(Output::Terminated(code)) => {
                self.core.engine_exited(token, code, self.now())
            }
            Event::Protocol(output) => {
                let ordinary = matches!(&output, Output::Stdout(event) if !matches!(event, transcribe::Event::Other(_)));
                let (accepted, effects) = self.core.engine_event(token, ordinary);
                if accepted {
                    self.emit(UpdateKind::Output(output));
                }
                effects
            }
            Event::Capabilities(capabilities) => {
                if self.core.engine_token() == Some(token) {
                    self.emit(UpdateKind::Capabilities(capabilities));
                }
                Vec::new()
            }
            Event::IoFailure { operation, message } => {
                if self.core.engine_token() != Some(token) {
                    return Ok(());
                }
                self.core.fail(
                    Failure::Message(format!("{operation}: {message}")),
                    self.now(),
                )
            }
        };
        self.effects(effects).await
    }

    async fn effects(&mut self, effects: Vec<Effect>) -> io::Result<()> {
        let mut pending = VecDeque::from(effects);
        // Continue cleanup after the first failure, but do not announce success.
        let mut fault = None;
        while let Some(effect) = pending.pop_front() {
            let result = match effect {
                Effect::PrepareFile(token) => {
                    let original = &self
                        .request
                        .as_ref()
                        .ok_or_else(|| io::Error::other("missing file request"))?
                        .0;
                    match DecodeTask::start(
                        &self.configuration.decoder,
                        original,
                        &self.configuration.scratch_parent,
                    ) {
                        Ok(task) => self.preparation = Some((token, task)),
                        Err(error) => pending.extend(self.core.file_prepared(
                            token,
                            Err(error.to_string()),
                            self.now(),
                        )),
                    }
                    Ok(())
                }
                Effect::CancelPreparation(token) => {
                    if self
                        .preparation
                        .as_ref()
                        .is_some_and(|(current, _)| *current == token)
                    {
                        let (_, mut task) = self.preparation.take().expect("matched preparation");
                        task.cancel();
                        // A completed decode can win the cancellation race.
                        if let Ok(audio) = task.wait().await {
                            audio.dispose()
                        } else {
                            Ok(())
                        }
                    } else {
                        Ok(())
                    }
                }
                Effect::StartEngine {
                    token,
                    file: Some(file),
                } => {
                    let settings = &self
                        .request
                        .as_ref()
                        .ok_or_else(|| io::Error::other("missing file settings"))?
                        .1;
                    let launched = self
                        .configuration
                        .resources
                        .file_launch(&file, settings)
                        .map_err(io::Error::other)
                        .and_then(|launch| {
                            EngineProcess::spawn(launch, token, &self.configuration.scratch_parent)
                        });
                    let outcome = match launched {
                        Ok(engine) => {
                            engine.close_input();
                            self.engine = Some((token, engine));
                            Ok(())
                        }
                        Err(error) => Err(error.to_string()),
                    };
                    pending.extend(self.core.engine_started(token, outcome, self.now()));
                    Ok(())
                }
                Effect::TerminateEngine(token) => {
                    if self
                        .engine
                        .as_ref()
                        .is_some_and(|(current, _)| *current == token)
                    {
                        let (_, mut engine) = self.engine.take().expect("matched engine");
                        engine.terminate();
                        let result = engine.wait().await;
                        // Supervision can surface drain failures during teardown.
                        // Output after the core retired this identity is ignored,
                        // but resource faults must never become a success receipt.
                        let mut result = result;
                        while let Some(message) = engine.next().await {
                            if let Event::IoFailure { operation, message } = message.event {
                                result = result
                                    .and(Err(io::Error::other(format!("{operation}: {message}"))));
                            }
                        }
                        result
                    } else {
                        Ok(())
                    }
                }
                Effect::RemovePreparedFile(path) => self.prepared.release(&path).map(|_| ()),
                Effect::Finished | Effect::Failed => {
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
                _ => Err(io::Error::other(
                    "non-file effect reached the file executor",
                )),
            };
            if let Err(error) = result {
                fault.get_or_insert(error);
            }
        }
        if let Some(error) = fault {
            return Err(error);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests;
