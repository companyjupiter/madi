//! File-session presentation owner. Native hosts supply paths/configuration;
//! web commands only address the current generation and transcript identities.
use crate::{
    asr_config::FileSettings,
    file_session::{Configuration, FileSession, RunId, UpdateKind},
    media_file,
};
use madi_core::{
    session::{Failure, Phase},
    transcript::{Features, Line, SpeakerNumbers, TranscriptStore},
};
use madi_protocol::{stream::Output, transcribe::Event};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, io, path::PathBuf, sync::Arc, time::Duration};
use tokio::{
    sync::{Mutex, mpsc, oneshot, watch},
    task::JoinHandle,
    time::Instant,
};

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ViewPhase {
    Idle,
    Processing,
    Done,
    Error { message: String },
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayLine {
    #[serde(flatten)]
    pub line: Line,
    pub text: String,
    // Keep the full 64-bit revision intact across JavaScript serialization.
    pub source_revision: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub revision: u64,
    pub generation: u64,
    pub phase: ViewPhase,
    pub file_name: String,
    pub size_label: String,
    pub chunks_done: i64,
    pub chunks_total: i64,
    pub lines: Vec<DisplayLine>,
    pub speaker_numbers: SpeakerNumbers,
    pub speaker_names: BTreeMap<i64, String>,
    pub partial: String,
    pub speaker_island_absorption: bool,
}
impl Default for Snapshot {
    fn default() -> Self {
        Self {
            revision: 0,
            generation: 0,
            phase: ViewPhase::Idle,
            file_name: String::new(),
            size_label: String::new(),
            chunks_done: 0,
            chunks_total: 0,
            lines: Vec::new(),
            speaker_numbers: SpeakerNumbers::default(),
            speaker_names: BTreeMap::new(),
            partial: String::new(),
            speaker_island_absorption: false,
        }
    }
}
#[derive(Debug, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Edit {
    Line {
        id: String,
        text: String,
    },
    Word {
        id: String,
        index: usize,
        text: String,
    },
    Translation {
        id: String,
        language: String,
        text: String,
    },
    SpeakerName {
        speaker: i64,
        name: String,
    },
}
enum Command {
    Start {
        path: PathBuf,
        settings: FileSettings,
        admission_error: Option<String>,
        reply: oneshot::Sender<io::Result<Snapshot>>,
    },
    Reset {
        generation: u64,
        reply: oneshot::Sender<io::Result<Snapshot>>,
    },
    Edit {
        generation: u64,
        edit: Edit,
        reply: oneshot::Sender<io::Result<Snapshot>>,
    },
    Shutdown,
}
struct Owner {
    commands: mpsc::UnboundedSender<Command>,
    snapshot: watch::Receiver<Snapshot>,
    task: Mutex<Option<JoinHandle<io::Result<()>>>>,
}
impl Drop for Owner {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Shutdown);
    }
}
#[derive(Clone)]
pub struct FileWorkflow {
    owner: Arc<Owner>,
}
impl FileWorkflow {
    pub fn new(
        configuration: Configuration,
        changed: impl Fn(Snapshot) + Send + Sync + 'static,
    ) -> io::Result<Self> {
        let session = FileSession::new(configuration.clone())?;
        let (commands, input) = mpsc::unbounded_channel();
        let (output, snapshot) = watch::channel(Snapshot::default());
        let task = tokio::spawn(
            Worker {
                configuration,
                session,
                input,
                output,
                changed: Box::new(changed),
                state: Snapshot::default(),
                store: TranscriptStore::default(),
                run: None,
                render: None,
                fix: None,
            }
            .execute(),
        );
        Ok(Self {
            owner: Arc::new(Owner {
                commands,
                snapshot,
                task: Mutex::new(Some(task)),
            }),
        })
    }
    pub fn snapshot(&self) -> Snapshot {
        self.owner.snapshot.borrow().clone()
    }
    pub async fn start(
        &self,
        path: PathBuf,
        settings: FileSettings,
        admission_error: Option<String>,
    ) -> io::Result<Snapshot> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::Start {
                path,
                settings,
                admission_error,
                reply,
            })
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }
    pub async fn reset(&self, generation: u64) -> io::Result<Snapshot> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::Reset { generation, reply })
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }
    pub async fn edit(&self, generation: u64, edit: Edit) -> io::Result<Snapshot> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::Edit {
                generation,
                edit,
                reply,
            })
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }
    /// A cancelled caller leaves the worker and its JoinHandle owned here.
    pub async fn shutdown(&self) -> io::Result<()> {
        let _ = self.owner.commands.send(Command::Shutdown);
        let mut task = self.owner.task.lock().await;
        let result = match task.as_mut() {
            Some(task) => task.await,
            None => return Ok(()),
        };
        task.take();
        result.map_err(io::Error::other)?
    }
}
fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "file workflow closed")
}
async fn deadline(time: Option<Instant>) {
    match time {
        Some(time) => tokio::time::sleep_until(time).await,
        None => std::future::pending().await,
    }
}
struct Worker {
    configuration: Configuration,
    session: FileSession,
    input: mpsc::UnboundedReceiver<Command>,
    output: watch::Sender<Snapshot>,
    changed: Box<dyn Fn(Snapshot) + Send + Sync>,
    state: Snapshot,
    store: TranscriptStore,
    run: Option<RunId>,
    render: Option<Instant>,
    fix: Option<Instant>,
}
impl Worker {
    async fn execute(mut self) -> io::Result<()> {
        let result = self.run_loop().await;
        // Keep the async owner alive until native children and owned WAVs exit.
        let cleanup = self.session.shutdown().await;
        result.and(cleanup)
    }
    fn publish(&mut self) {
        self.state.lines = self
            .store
            .display_lines()
            .iter()
            .map(|line| DisplayLine {
                line: line.clone(),
                text: line.text(),
                source_revision: madi_core::transcript::text_revision(&line.text()).to_string(),
            })
            .collect();
        self.state.speaker_numbers = self.store.speaker_numbers.clone();
        self.state.revision = self.state.revision.wrapping_add(1);
        self.output.send_replace(self.state.clone());
        (self.changed)(self.state.clone());
    }
    fn schedule(&mut self) {
        if self.store.render_pending && self.render.is_none() {
            self.render = Some(Instant::now() + Duration::from_millis(33));
        }
        if self.store.speaker_fix_pending && self.fix.is_none() {
            self.fix = Some(Instant::now() + Duration::from_millis(50));
        }
    }
    fn clear(&mut self) {
        self.run = None;
        self.store.reset();
        let revision = self.state.revision;
        let generation = self.state.generation.wrapping_add(1);
        self.state = Snapshot {
            revision,
            generation,
            ..Snapshot::default()
        };
    }
    fn finish(&mut self) {
        self.store.flush_pending_speaker_fix_rebuild();
        self.store.finalize();
        self.state.partial.clear();
        self.publish();
    }
    async fn run_loop(&mut self) -> io::Result<()> {
        loop {
            tokio::select! {
                command=self.input.recv()=>match command {
                    Some(Command::Start {path,settings,admission_error,reply})=>{
                        let result=self.start(path,settings,admission_error).await;
                        let _=reply.send(result);
                    },
                    Some(Command::Reset {generation,reply})=>{
                        let result=if generation==self.state.generation {
                            self.clear(); self.publish();
                            self.session.reset().await.map(|()|self.state.clone())
                        }else {Ok(self.state.clone())};
                        let _=reply.send(result);
                    },
                    Some(Command::Edit {generation,edit,reply})=>{
                        let result=if generation==self.state.generation {self.edit(edit)} else {Ok(self.state.clone())};
                        let _=reply.send(result);
                    },
                    Some(Command::Shutdown)|None=>return Ok(()),
                },
                update=self.session.next()=>{
                    let Some(update)=update else {return Err(closed())};
                    if self.run!=Some(update.run) {continue;}
                    match update.kind {
                        UpdateKind::Output(Output::Stdout(event))=>self.ingest(event),
                        UpdateKind::Phase(Phase::Processing)=>{self.state.phase=ViewPhase::Processing;self.publish();},
                        UpdateKind::Phase(Phase::Error(failure))=>{self.state.phase=ViewPhase::Error {message:failure_message(&failure,&self.state.file_name)};},
                        UpdateKind::Finished=>{self.state.phase=ViewPhase::Done;self.finish();},
                        UpdateKind::Failed=>self.finish(),
                        UpdateKind::Fault(message)=>{
                            self.state.phase=ViewPhase::Error {message};self.finish();
                            // A transport fault retires the underlying executor.
                            // Reap it before replacing it so retry/back remain usable.
                            let _=self.session.shutdown().await;
                            self.session=FileSession::new(self.configuration.clone())?;
                            self.run=None;
                        },
                        _=>(),
                    }
                },
                _=deadline(self.fix)=>{
                    self.fix=None;
                    self.store.flush_pending_speaker_fix_rebuild();
                },
                _=deadline(self.render)=>{
                    self.render=None;
                    self.store.flush_render();
                    self.publish();
                },
            }
            self.schedule();
        }
    }
    async fn start(
        &mut self,
        path: PathBuf,
        settings: FileSettings,
        admission_error: Option<String>,
    ) -> io::Result<Snapshot> {
        if self.state.phase == ViewPhase::Processing {
            return Ok(self.state.clone());
        }
        if let Some(message) = admission_error {
            self.state.phase = ViewPhase::Error { message };
            self.finish();
            return Ok(self.state.clone());
        }
        self.session.reset().await?;
        self.clear();
        self.store.features = Features::for_language(settings.language_token);
        self.state.speaker_island_absorption = self.store.features.speaker_island_absorption;
        let file = media_file::summary(&path);
        self.state.file_name = file.name;
        self.state.size_label = file.size_label;
        let run = self
            .session
            .start(path, settings)
            .await?
            .ok_or_else(|| io::Error::other("file session is busy"))?;
        self.run = Some(run);
        self.state.phase = ViewPhase::Processing;
        self.publish();
        Ok(self.state.clone())
    }
    fn ingest(&mut self, event: Event) {
        match &event {
            Event::ProgressTotal(total) => self.state.chunks_total = *total,
            Event::ProgressChunk(done) => {
                self.state.chunks_done = self.state.chunks_done.max(*done)
            }
            Event::WordSectionBegin => self.state.partial.clear(),
            Event::SpeakerName { id, name } => {
                self.state.speaker_names.insert(*id, name.clone());
            }
            _ => (),
        }
        self.store.ingest(&event);
        // Progress/name callbacks are low-frequency UI state, also coalesced.
        if self.render.is_none() {
            self.render = Some(Instant::now() + Duration::from_millis(33));
        }
    }
    fn edit(&mut self, edit: Edit) -> io::Result<Snapshot> {
        let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "invalid transcript identity");
        match edit {
            Edit::Line { id, text } => {
                self.store
                    .edit_line(id.parse().map_err(|_| invalid())?, &text, None);
            }
            Edit::Word { id, index, text } => {
                self.store
                    .edit_word(id.parse().map_err(|_| invalid())?, index, &text);
            }
            Edit::Translation { id, language, text } => {
                self.store.set_translation(
                    id.parse().map_err(|_| invalid())?,
                    language,
                    &text,
                    None,
                    true,
                );
            }
            Edit::SpeakerName { speaker, name } => {
                if speaker != 255 {
                    let name = madi_core::transcript::trim_whitespace_and_newlines(&name);
                    if name.is_empty() {
                        self.state.speaker_names.remove(&speaker);
                    } else {
                        self.state.speaker_names.insert(speaker, name.into());
                    }
                    self.publish();
                }
            }
        }
        self.schedule();
        Ok(self.state.clone())
    }
}
fn failure_message(failure: &Failure, file_name: &str) -> String {
    match failure {
        Failure::Message(text) => text.clone(),
        Failure::EngineStart(error) => format!("전사 엔진을 시작하지 못했어요: {error}"),
        Failure::StartupTimeout => {
            "엔진 시작이 너무 오래 걸려요. 다시 시도해주세요 — 계속되면 앱을 재시작해주세요.".into()
        }
        Failure::EngineExit(code) => {
            format!("전사 엔진이 예기치 않게 종료되었어요 (코드 {code}). 다시 시도해주세요.")
        }
        Failure::Preparation(reason) => format!("'{file_name}' 을(를) 열 수 없습니다 — {reason}."),
        Failure::CaptureStart(error) => format!("오디오 입력을 시작하지 못했어요: {error}"),
    }
}

#[cfg(test)]
mod tests;
