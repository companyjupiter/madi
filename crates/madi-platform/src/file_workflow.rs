//! File-session presentation owner. Native hosts supply paths/configuration;
//! web commands only address the current generation and transcript identities.
use crate::{
    asr_config::FileSettings,
    file_session::{Configuration, FileSession, RunId, UpdateKind},
    media_file,
    session_archive::SessionArchiveWriter,
};
use madi_core::{
    session::{Failure, Phase},
    transcript::{Features, Line, SpeakerNumbers, TranscriptStore, archive},
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
    pub archive: ArchiveSnapshot,
}
#[derive(Clone, Debug)]
pub struct ArchiveSettings {
    pub enabled: bool,
    pub folder: PathBuf,
}
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArchiveSnapshot {
    #[serde(skip)]
    pub write_revision: u64,
    pub enabled: bool,
    pub folder: Option<PathBuf>,
    pub transcript: Option<PathBuf>,
    pub error: Option<String>,
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
            archive: ArchiveSnapshot::default(),
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
    Export {
        generation: u64,
        path: PathBuf,
        format: crate::transcript_export::Format,
        settings: madi_core::transcript::export::EditorSettings,
        reply: oneshot::Sender<io::Result<()>>,
    },
    RenderExport {
        generation: u64,
        format: crate::transcript_export::Format,
        settings: madi_core::transcript::export::EditorSettings,
        reply: oneshot::Sender<io::Result<Option<String>>>,
    },
    ArchiveSettings {
        settings: ArchiveSettings,
        reply: oneshot::Sender<io::Result<Snapshot>>,
    },
    OpenArchive {
        generation: u64,
        path: PathBuf,
        reply: oneshot::Sender<io::Result<Snapshot>>,
    },
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
        Self::with_archive(configuration, None, changed)
    }
    /// Native hosts own the selected folder. The renderer cannot supply paths.
    /// None is reserved for isolated harnesses with persistence disabled.
    pub fn with_archive(
        configuration: Configuration,
        archive_settings: Option<ArchiveSettings>,
        changed: impl Fn(Snapshot) + Send + Sync + 'static,
    ) -> io::Result<Self> {
        let session = FileSession::new(configuration.clone())?;
        let (commands, input) = mpsc::unbounded_channel();
        let mut state = Snapshot::default();
        state.archive.enabled = archive_settings
            .as_ref()
            .is_some_and(|settings| settings.enabled);
        state.archive.folder = archive_settings
            .as_ref()
            .map(|settings| settings.folder.clone());
        let (output, snapshot) = watch::channel(state.clone());
        let task = tokio::spawn(
            Worker {
                configuration,
                session,
                input,
                output,
                changed: Box::new(changed),
                state,
                store: TranscriptStore::default(),
                run: None,
                render: None,
                fix: None,
                pending_failure: None,
                checkpoint: None,
                archive_settings,
                archive_writer: Arc::new(std::sync::Mutex::new(SessionArchiveWriter::default())),
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
    /// Queue a persisted setting change without creating a detached async task.
    pub fn archive_settings_changed(&self, settings: ArchiveSettings) -> io::Result<()> {
        let (reply, _) = oneshot::channel();
        self.owner
            .commands
            .send(Command::ArchiveSettings { settings, reply })
            .map_err(|_| closed())
    }
    pub async fn set_archive_settings(&self, settings: ArchiveSettings) -> io::Result<Snapshot> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::ArchiveSettings { settings, reply })
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }
    /// The native save panel owns path selection and overwrite confirmation.
    /// Once queued, serialization and atomic writing are joined by shutdown.
    pub async fn export_to(
        &self,
        generation: u64,
        path: PathBuf,
        format: crate::transcript_export::Format,
        settings: madi_core::transcript::export::EditorSettings,
    ) -> io::Result<()> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::Export {
                generation,
                path,
                format,
                settings,
                reply,
            })
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }
    pub async fn render_export(
        &self,
        generation: u64,
        format: crate::transcript_export::Format,
        settings: madi_core::transcript::export::EditorSettings,
    ) -> io::Result<Option<String>> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::RenderExport {
                generation,
                format,
                settings,
                reply,
            })
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }
    pub async fn open_archive(&self, generation: u64, path: PathBuf) -> io::Result<Snapshot> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::OpenArchive {
                generation,
                path,
                reply,
            })
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
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
    pending_failure: Option<String>,
    checkpoint: Option<Instant>,
    archive_settings: Option<ArchiveSettings>,
    archive_writer: Arc<std::sync::Mutex<SessionArchiveWriter>>,
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
        self.pending_failure = None;
        self.checkpoint = None;
        // All disk work is joined before another command can reach clear.
        self.archive_writer = Arc::new(std::sync::Mutex::new(SessionArchiveWriter::default()));
        self.store.reset();
        let revision = self.state.revision;
        let generation = self.state.generation.wrapping_add(1);
        self.state = Snapshot {
            revision,
            generation,
            archive: ArchiveSnapshot {
                enabled: self
                    .archive_settings
                    .as_ref()
                    .is_some_and(|settings| settings.enabled),
                folder: self
                    .archive_settings
                    .as_ref()
                    .map(|settings| settings.folder.clone()),
                ..ArchiveSnapshot::default()
            },
            ..Snapshot::default()
        };
    }
    async fn finish(&mut self) {
        self.checkpoint = None;
        self.store.flush_pending_speaker_fix_rebuild();
        self.store.finalize();
        self.state.partial.clear();
        self.auto_save().await;
        self.publish();
    }
    async fn auto_save(&mut self) {
        let Some(settings) = self
            .archive_settings
            .as_ref()
            .filter(|settings| settings.enabled)
        else {
            return;
        };
        if self.store.lines().is_empty() {
            return;
        }
        let markdown = archive::markdown(self.store.lines(), &self.state.speaker_names, None);
        let folder = settings.folder.clone();
        let base = std::path::Path::new(&self.state.file_name)
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let writer = self.archive_writer.clone();
        let saved = tokio::task::spawn_blocking(move || {
            let mut writer = writer
                .lock()
                .map_err(|_| io::Error::other("archive writer unavailable"))?;
            writer.save_transcript(&markdown, &folder, &base);
            Ok::<_, io::Error>((
                writer.transcript().map(std::path::Path::to_path_buf),
                writer.last_error().map(str::to_owned),
            ))
        })
        .await;
        match saved {
            Ok(Ok((path, error))) => {
                if error.is_none() && path.is_some() {
                    self.state.archive.write_revision =
                        self.state.archive.write_revision.wrapping_add(1);
                }
                self.state.archive.transcript = path;
                self.state.archive.error = error;
            }
            Ok(Err(error)) => self.state.archive.error = Some(error.to_string()),
            Err(error) => self.state.archive.error = Some(error.to_string()),
        }
    }
    async fn open_archive(&mut self, generation: u64, path: PathBuf) -> io::Result<Snapshot> {
        if generation != self.state.generation || self.state.phase == ViewPhase::Processing {
            return Ok(self.state.clone());
        }
        let source = path.clone();
        let parsed = tokio::task::spawn_blocking(move || {
            std::fs::read_to_string(source)
                .ok()
                .and_then(|text| archive::parse(&text))
        })
        .await
        .map_err(io::Error::other)?;
        // Unreadable or unrecognized Markdown leaves the current meeting intact.
        let Some(parsed) = parsed else {
            return Ok(self.state.clone());
        };
        if parsed
            .lines
            .iter()
            .any(|line| !line.start.is_finite() || !line.end.is_finite())
        {
            return Ok(self.state.clone());
        }
        self.session.reset().await?;
        self.clear();
        self.state.speaker_names = parsed.names;
        self.store.load(parsed.lines);
        self.state.file_name = media_file::summary(&path).name;
        self.state.speaker_island_absorption = self.store.features.speaker_island_absorption;
        self.state.phase = ViewPhase::Done;
        // Opening a file never claims it as this session's checkpoint target.
        self.publish();
        Ok(self.state.clone())
    }
    async fn run_loop(&mut self) -> io::Result<()> {
        loop {
            tokio::select! {
                command=self.input.recv()=>match command {
                    Some(Command::Export {generation,path,format,settings,reply})=>{
                        let result=if generation!=self.state.generation || self.store.lines().is_empty(){Ok(())}else{
                            let lines=self.store.lines().to_vec();let names=self.state.speaker_names.clone();
                            tokio::task::spawn_blocking(move ||{
                                let content=crate::transcript_export::render(format,&lines,&names,&settings)?;
                                crate::transcript_export::write_selected(&path,&content)
                            }).await.map_err(io::Error::other).and_then(|result|result)
                        };
                        let _=reply.send(result);
                    },
                    Some(Command::RenderExport {generation,format,settings,reply})=>{
                        let result=if generation!=self.state.generation || self.store.lines().is_empty(){Ok(None)}else{
                            let lines=self.store.lines().to_vec();let names=self.state.speaker_names.clone();
                            tokio::task::spawn_blocking(move ||crate::transcript_export::render(format,&lines,&names,&settings)).await.map_err(io::Error::other).and_then(|result|result.map(Some))
                        };
                        let _=reply.send(result);
                    },
                    Some(Command::ArchiveSettings {settings,reply})=>{
                        if self.state.archive.enabled!=settings.enabled || self.state.archive.folder.as_ref()!=Some(&settings.folder) {
                            self.state.archive.enabled=settings.enabled;
                            self.state.archive.folder=Some(settings.folder.clone());
                            self.archive_settings=Some(settings);
                            self.publish();
                        }
                        let _=reply.send(Ok(self.state.clone()));
                    },
                    Some(Command::OpenArchive {generation,path,reply})=>{
                        let result=self.open_archive(generation,path).await;
                        let _=reply.send(result);
                    },
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
                        UpdateKind::Phase(Phase::Error(failure))=>{self.pending_failure=Some(failure_message(&failure,&self.state.file_name));},
                        UpdateKind::Finished=>{self.state.phase=ViewPhase::Done;self.finish().await;},
                        UpdateKind::Failed=>{
                            if let Some(message)=self.pending_failure.take() {self.state.phase=ViewPhase::Error {message};}
                            self.finish().await;
                        },
                        UpdateKind::Fault(message)=>{
                            self.state.phase=ViewPhase::Error {message};self.finish().await;
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
                _=deadline(self.checkpoint)=>{
                    self.checkpoint=if self.state.phase==ViewPhase::Processing {Some(Instant::now()+Duration::from_secs(30))}else{None};
                    if self.checkpoint.is_some() {self.auto_save().await;self.publish();}
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
            // SessionCoordinator.fail invokes onFailed only for an active
            // engine/capture/processing session. Admission has none; finalizing
            // a reopened archive here would rebuild from an empty merger.
            self.publish();
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
        self.checkpoint = Some(Instant::now() + Duration::from_secs(30));
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
