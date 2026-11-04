//! Shared file/live presentation owner. Native hosts supply paths/configuration;
//! web commands only address the current generation and transcript identities.
use crate::{
    asr_config::FileSettings, file_session::Configuration, glossary_service::GlossaryService,
    media_file, preferences_service::PreferencesService, session_archive::SessionArchiveWriter,
};
mod driver;
use driver::{Driver, Kind as UpdateKind, RunId};
use madi_core::{
    personal_vocabulary,
    session::{Failure, Phase},
    text_passes::TextPasses,
    transcript::{Features, Line, SpeakerNumbers, TranscriptStore, Uuid, archive},
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
    CountingDown { remaining: u32 },
    EngineStarting,
    Ready,
    Recording,
    Paused,
    Flushing,
    Processing,
    Done,
    Error { message: String },
}
impl ViewPhase {
    pub fn is_busy(&self) -> bool {
        !matches!(self, Self::Idle | Self::Done | Self::Error { .. })
    }
    pub fn is_recording(&self) -> bool {
        matches!(self, Self::Recording | Self::Paused)
    }
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveSnapshot {
    pub source: madi_core::setup::AudioSource,
    pub input_device: Option<String>,
    pub seconds: f64,
    pub meter: f32,
    pub capture_ended_reason: Option<String>,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum LiveControl {
    Pause,
    Resume,
    Stop,
    CancelCountdown,
    InputDevice(Option<String>),
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
    pub live: Option<LiveSnapshot>,
    pub permission_issue: Option<crate::audio_permissions::Issue>,
    pub admission_pending: bool,
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
            live: None,
            permission_issue: None,
            admission_pending: false,
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
    #[cfg(target_os = "macos")]
    StartLive {
        request: crate::live_session::Request,
        admission_error: Option<String>,
        reply: oneshot::Sender<io::Result<Snapshot>>,
    },
    #[cfg(target_os = "macos")]
    LiveControl {
        generation: u64,
        command: LiveControl,
        reply: oneshot::Sender<io::Result<Snapshot>>,
    },
    Preferences(PreferencesService, oneshot::Sender<io::Result<()>>),
    Glossary(GlossaryService, oneshot::Sender<io::Result<()>>),
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
        let session = Driver::new(configuration.clone())?;
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
                glossary: None,
                preferences: None,
                text_passes: TextPasses::default(),
                run: None,
                render: None,
                fix: None,
                pending_failure: None,
                checkpoint: None,
                permission: None,
                countdown: None,
                closing: false,
                #[cfg(target_os = "macos")]
                last_meter: Instant::now(),
                #[cfg(target_os = "macos")]
                pending_live: None,
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
    /// Stable display passes consult the current targets, including settings
    /// changed during file processing, rather than a frozen admission copy.
    pub async fn set_preferences(&self, preferences: PreferencesService) -> io::Result<()> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::Preferences(preferences, reply))
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }
    /// Attach the app-owned glossary before admission or a saved-file edit.
    pub async fn set_glossary(&self, glossary: GlossaryService) -> io::Result<()> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::Glossary(glossary, reply))
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
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
    #[cfg(target_os = "macos")]
    pub async fn start_live(
        &self,
        request: crate::live_session::Request,
        admission_error: Option<String>,
    ) -> io::Result<Snapshot> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::StartLive {
                request,
                admission_error,
                reply,
            })
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }
    #[cfg(target_os = "macos")]
    pub async fn live_control(
        &self,
        generation: u64,
        command: LiveControl,
    ) -> io::Result<Snapshot> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::LiveControl {
                generation,
                command,
                reply,
            })
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
    session: Driver,
    input: mpsc::UnboundedReceiver<Command>,
    output: watch::Sender<Snapshot>,
    changed: Box<dyn Fn(Snapshot) + Send + Sync>,
    state: Snapshot,
    store: TranscriptStore,
    glossary: Option<GlossaryService>,
    preferences: Option<PreferencesService>,
    text_passes: TextPasses,
    run: Option<RunId>,
    render: Option<Instant>,
    fix: Option<Instant>,
    pending_failure: Option<String>,
    checkpoint: Option<Instant>,
    permission: Option<JoinHandle<io::Result<Option<crate::audio_permissions::Issue>>>>,
    countdown: Option<Instant>,
    closing: bool,
    #[cfg(target_os = "macos")]
    last_meter: Instant,
    #[cfg(target_os = "macos")]
    pending_live: Option<crate::live_session::Request>,
    archive_settings: Option<ArchiveSettings>,
    archive_writer: Arc<std::sync::Mutex<SessionArchiveWriter>>,
}
impl Worker {
    async fn execute(mut self) -> io::Result<()> {
        let result = self.run_loop().await;
        self.cancel_admission().await;
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
        self.countdown = None;
        // All disk work is joined before another command can reach clear.
        self.archive_writer = Arc::new(std::sync::Mutex::new(SessionArchiveWriter::default()));
        self.store.reset();
        self.text_passes.reset();
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
        if let Some(glossary) = &self.glossary {
            glossary.with_value(|glossary| {
                self.text_passes.finalize(&mut self.store, Some(glossary));
            });
        } else {
            self.text_passes.finalize(&mut self.store, None);
        }
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
            #[cfg(target_os = "macos")]
            let base = if base.is_empty() {
                crate::session_archive::live_fallback_title(
                    objc2_foundation::NSDate::date().timeIntervalSince1970(),
                )
            } else {
                base
            };
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
                if self.state.live.is_some()
                    && let Some(path) = &path
                {
                    self.state.size_label = media_file::summary(path).size_label;
                }
                self.state.archive.transcript = path;
                self.state.archive.error = error;
            }
            Ok(Err(error)) => self.state.archive.error = Some(error.to_string()),
            Err(error) => self.state.archive.error = Some(error.to_string()),
        }
    }
    async fn open_archive(&mut self, generation: u64, path: PathBuf) -> io::Result<Snapshot> {
        if generation != self.state.generation || self.busy() {
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
            let permission_pending = self.permission.is_some();
            tokio::select! {
                command=self.input.recv(),if !self.closing=>match command {
                    #[cfg(target_os="macos")]
                    Some(Command::StartLive {request,admission_error,reply})=>{let result=self.start_live(request,admission_error).await;let _=reply.send(result);},
                    #[cfg(target_os="macos")]
                    Some(Command::LiveControl {generation,command,reply})=>{let result=self.live_control(generation,command).await;let _=reply.send(result);},
                    Some(Command::Preferences(preferences, reply))=>{
                        self.preferences=Some(preferences);let _=reply.send(Ok(()));
                    },
                    Some(Command::Glossary(glossary, reply))=>{
                        self.glossary=Some(glossary);let _=reply.send(Ok(()));
                    },
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
                        let result=if generation==self.state.generation && !self.state.phase.is_recording() {
                            self.cancel_admission().await;
                            self.clear(); self.publish();
                            self.session.reset().await.map(|()|self.state.clone())
                        }else {Ok(self.state.clone())};
                        let _=reply.send(result);
                    },
                    Some(Command::Edit {generation,edit,reply})=>{
                        let result=if generation==self.state.generation {self.edit(edit).await} else {Ok(self.state.clone())};
                        let _=reply.send(result);
                    },
                    Some(Command::Shutdown)|None=>{
                        #[cfg(target_os="macos")]
                        if self.state.live.is_some() && (self.state.phase.is_recording() || self.state.phase==ViewPhase::Flushing) {
                            if self.state.phase.is_recording() && let Some(run)=self.run {self.session.control(run,LiveControl::Stop)?;}
                            self.closing=true; continue;
                        }
                        return Ok(());
                    },
                },
                update=self.session.next()=>{
                    let Some(update)=update else {return Err(closed())};
                    if self.run!=Some(update.run) {continue;}
                    match update.kind {
                        UpdateKind::Output(Output::Stdout(event))=>self.ingest(event),
                        UpdateKind::Phase(Phase::Processing)=>{self.state.phase=ViewPhase::Processing;self.publish();},
                        UpdateKind::Phase(phase)=>{
                            if let Phase::Error(failure)=phase {self.pending_failure=Some(failure_message(&failure,&self.state.file_name));}
                            else if self.state.live.is_some() {
                                self.state.phase=match phase {Phase::EngineStarting=>ViewPhase::EngineStarting,Phase::Ready=>ViewPhase::Ready,Phase::Recording=>ViewPhase::Recording,Phase::Paused=>ViewPhase::Paused,Phase::Flushing=>ViewPhase::Flushing,_=>self.state.phase.clone()};self.publish();
                            }
                        },
                        UpdateKind::Finished=>{self.state.phase=ViewPhase::Done;self.finish().await;if self.closing {return Ok(());}},
                        UpdateKind::Failed=>{
                            if let Some(message)=self.pending_failure.take() {self.state.phase=ViewPhase::Error {message};}
                            self.finish().await;
                            if self.closing {return Ok(());}
                        },
                        UpdateKind::Fault(message)=>{
                            self.state.phase=ViewPhase::Error {message:message.clone()};self.finish().await;
                            // A transport fault retires the underlying executor.
                            // Reap it before replacing it so retry/back remain usable.
                            let _=self.session.shutdown().await;
                            if self.closing {return Err(io::Error::other(message));}
                            self.session=Driver::new(self.configuration.clone())?;
                            self.run=None;
                        },
                        #[cfg(target_os="macos")]
                        UpdateKind::Live(event)=>self.live_event(event),
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
                    self.checkpoint=if self.state.phase==ViewPhase::Processing || self.state.phase.is_recording() || self.state.phase==ViewPhase::Flushing {Some(Instant::now()+Duration::from_secs(30))}else{None};
                    if self.checkpoint.is_some() {self.auto_save().await;self.publish();}
                },
                permission=async{self.permission.as_mut().unwrap().await},if permission_pending=>{
                    self.permission.take();
                    self.permission_result(permission.map_err(io::Error::other).and_then(|r|r)).await?;
                },
                _=deadline(self.countdown)=>{
                    self.countdown=None;
                    self.countdown_elapsed().await?;
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
        if self.busy() {
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
            .start(&self.configuration, path, settings)
            .await?
            .ok_or_else(|| io::Error::other("file session is busy"))?;
        self.run = Some(run);
        self.state.phase = ViewPhase::Processing;
        self.checkpoint = Some(Instant::now() + Duration::from_secs(30));
        self.publish();
        Ok(self.state.clone())
    }
    fn busy(&self) -> bool {
        self.closing || self.state.admission_pending || self.state.phase.is_busy()
    }
    async fn cancel_admission(&mut self) {
        if let Some(task) = self.permission.take() {
            task.abort();
            let _ = task.await;
        }
        self.countdown = None;
        #[cfg(target_os = "macos")]
        {
            self.pending_live = None;
        }
        self.state.admission_pending = false;
    }
    #[cfg(target_os = "macos")]
    async fn start_live(
        &mut self,
        request: crate::live_session::Request,
        admission_error: Option<String>,
    ) -> io::Result<Snapshot> {
        if self.busy() {
            return Ok(self.state.clone());
        }
        self.state.permission_issue = None;
        if let Some(message) = admission_error {
            self.state.phase = ViewPhase::Error { message };
            self.publish();
            return Ok(self.state.clone());
        }
        let source = request.capture.source;
        let devices = matches!(request.input, crate::live_session::Input::Devices { .. });
        // A cancelled admission is a retired UI identity too, even if no engine
        // was started. Delayed countdown controls cannot cancel its replacement.
        self.state.generation = self.state.generation.wrapping_add(1);
        self.pending_live = Some(request);
        self.state.admission_pending = true;
        self.permission = Some(tokio::spawn(async move {
            if devices {
                crate::audio_permissions::preflight(source).await
            } else {
                Ok(None)
            }
        }));
        self.publish();
        Ok(self.state.clone())
    }
    async fn permission_result(
        &mut self,
        result: io::Result<Option<crate::audio_permissions::Issue>>,
    ) -> io::Result<()> {
        self.state.admission_pending = false;
        let error = match result {
            Ok(Some(issue)) => {
                self.state.permission_issue = Some(issue);
                let language = self
                    .preferences
                    .as_ref()
                    .map(|p| p.snapshot().presentation.ui_language)
                    .unwrap_or_default();
                Some(issue.message(language).to_owned())
            }
            Err(error) => Some(error.to_string()),
            Ok(None) => None,
        };
        if let Some(message) = error {
            #[cfg(target_os = "macos")]
            {
                self.pending_live = None;
            }
            self.state.phase = ViewPhase::Error { message };
            self.publish();
            return Ok(());
        }
        #[cfg(target_os = "macos")]
        if let Some(request) = &self.pending_live {
            self.state.live = Some(LiveSnapshot {
                source: request.capture.source,
                input_device: match request.input {
                    crate::live_session::Input::Devices { device } => {
                        device.map(|id| format!("coreaudio:{id}"))
                    }
                    _ => None,
                },
                seconds: 0.0,
                meter: 0.0,
                capture_ended_reason: None,
            });
            self.state.phase = ViewPhase::CountingDown { remaining: 3 };
            self.countdown = Some(Instant::now() + Duration::from_secs(1));
            self.publish();
        }
        Ok(())
    }
    async fn countdown_elapsed(&mut self) -> io::Result<()> {
        let ViewPhase::CountingDown { remaining } = self.state.phase else {
            return Ok(());
        };
        if remaining > 1 {
            self.state.phase = ViewPhase::CountingDown {
                remaining: remaining - 1,
            };
            self.countdown = Some(Instant::now() + Duration::from_secs(1));
            self.publish();
            return Ok(());
        }
        #[cfg(target_os = "macos")]
        {
            let Some(mut request) = self.pending_live.take() else {
                return Ok(());
            };
            // Shipping start() reads the current controls after the countdown.
            if let Some(preferences) = &self.preferences {
                let latest = preferences.snapshot();
                let memory = if request.settings.common.encoder_f16_cache {
                    24_u64 << 30
                } else {
                    0
                };
                let terms = self
                    .glossary
                    .as_ref()
                    .map(|g| g.with_value(personal_vocabulary::bias_terms))
                    .unwrap_or_else(|| request.settings.common.bias_terms.clone());
                request.settings =
                    crate::asr_config::LiveSettings::from_setup(&latest.setup, memory, terms)
                        .map_err(io::Error::other)?;
                request.capture = madi_core::capture_stream::Configuration::from_settings(
                    &latest.settings,
                    &latest.setup,
                );
                if let crate::live_session::Input::Devices { device } = &mut request.input {
                    *device =
                        crate::audio_devices::capture_id(latest.setup.input_device_id.as_deref())?;
                }
            }
            self.session.reset().await?;
            self.clear();
            self.store.features = Features::for_language(request.settings.common.language_token);
            self.state.speaker_island_absorption = self.store.features.speaker_island_absorption;
            self.state.live = Some(LiveSnapshot {
                source: request.capture.source,
                input_device: match request.input {
                    crate::live_session::Input::Devices { device } => {
                        device.map(|id| format!("coreaudio:{id}"))
                    }
                    _ => None,
                },
                seconds: 0.0,
                meter: 0.0,
                capture_ended_reason: None,
            });
            self.last_meter = Instant::now();
            self.run = Some(
                self.session
                    .start_live(&self.configuration, request)
                    .await?
                    .ok_or_else(|| io::Error::other("live session is busy"))?,
            );
            self.state.phase = ViewPhase::EngineStarting;
            self.publish();
        }
        Ok(())
    }
    #[cfg(target_os = "macos")]
    async fn live_control(
        &mut self,
        generation: u64,
        command: LiveControl,
    ) -> io::Result<Snapshot> {
        if generation != self.state.generation || self.closing {
            return Ok(self.state.clone());
        }
        if matches!(command, LiveControl::CancelCountdown) {
            if matches!(self.state.phase, ViewPhase::CountingDown { .. }) {
                self.cancel_admission().await;
                self.state.phase = ViewPhase::Idle;
                self.state.live = None;
                self.publish();
            }
        } else if let Some(run) = self.run {
            self.session.control(run, command.clone())?;
            if let LiveControl::InputDevice(device) = command
                && let Some(live) = &mut self.state.live
            {
                live.input_device = device;
                self.publish();
            }
        }
        Ok(self.state.clone())
    }
    #[cfg(target_os = "macos")]
    fn live_event(&mut self, event: crate::live_session::UpdateKind) {
        use crate::live_session::UpdateKind as Live;
        match event {
            Live::RecordingStarted => {
                self.checkpoint = Some(Instant::now() + Duration::from_secs(30));
            }
            Live::RecordedSeconds(seconds) => {
                if let Some(live) = &mut self.state.live {
                    live.seconds = seconds;
                    self.publish();
                }
            }
            Live::Level(level) => {
                let now = Instant::now();
                let release =
                    (-now.duration_since(self.last_meter).as_secs_f64() / 0.5).exp() as f32;
                self.last_meter = now;
                if let Some(live) = &mut self.state.live {
                    live.meter = level.max(live.meter * release);
                }
                if self.render.is_none() {
                    self.render = Some(Instant::now() + Duration::from_millis(33));
                }
            }
            Live::CaptureInterrupted(_) => {
                let language = self
                    .preferences
                    .as_ref()
                    .map(|p| p.snapshot().presentation.ui_language)
                    .unwrap_or_default();
                if let Some(live) = &mut self.state.live {
                    live.capture_ended_reason = Some(
                        match language {
                            madi_core::preferences::UILanguage::Ko => {
                                "오디오 연결이 끊겨 녹음을 마쳤어요"
                            }
                            madi_core::preferences::UILanguage::En => {
                                "The audio connection stopped, so the recording was ended"
                            }
                            madi_core::preferences::UILanguage::Ja => {
                                "オーディオの接続が切れたため録音を終了しました"
                            }
                        }
                        .into(),
                    );
                    self.publish();
                }
            }
            Live::WriteFailed { name, message, .. } => eprintln!("capture write {name}: {message}"),
            // Preview policy/watchdog/AI remain distinct consumers; mutable
            // preview slots must never be fed blindly into the committed lane.
            _ => {}
        }
    }
    fn ingest(&mut self, event: Event) {
        let event = match event {
            Event::Word {
                t0,
                t1,
                text,
                confidence,
            } => Event::Word {
                t0,
                t1,
                confidence,
                text: self.glossary.as_ref().map_or_else(
                    || text.clone(),
                    |glossary| {
                        glossary.with_value(|glossary| {
                            personal_vocabulary::correct_incoming_text(&text, confidence, glossary)
                        })
                    },
                ),
            },
            event => event,
        };
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
        if matches!(event, Event::Word { .. } | Event::WordSectionBegin)
            && self
                .preferences
                .as_ref()
                .is_some_and(PreferencesService::has_translation_targets)
        {
            if let Some(glossary) = &self.glossary {
                glossary.with_value(|glossary| {
                    self.text_passes.stable(
                        &mut self.store,
                        Some(glossary),
                        true,
                        &self.state.partial,
                        false,
                    );
                });
            } else {
                self.text_passes
                    .stable(&mut self.store, None, true, &self.state.partial, false);
            }
        }
        // Progress/name callbacks are low-frequency UI state, also coalesced.
        if self.render.is_none() {
            self.render = Some(Instant::now() + Duration::from_millis(33));
        }
    }
    async fn edit(&mut self, edit: Edit) -> io::Result<Snapshot> {
        let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "invalid transcript identity");
        let mut learn = None;
        match edit {
            Edit::Line { id, text } => {
                let id = id.parse::<Uuid>().map_err(|_| invalid())?;
                let before = self
                    .store
                    .lines()
                    .iter()
                    .find(|line| line.id == id)
                    .map(Line::text);
                self.text_passes.mark_user_edited(id);
                if self.store.edit_line(id, &text, None)
                    && let Some(before) = before
                {
                    learn = Some((personal_vocabulary::diff(&before, &text), false));
                }
            }
            Edit::Word { id, index, text } => {
                let id = id.parse::<Uuid>().map_err(|_| invalid())?;
                let before = self
                    .store
                    .lines()
                    .iter()
                    .find(|line| line.id == id)
                    .and_then(|line| line.words.get(index))
                    .map(|word| word.text.clone());
                if self.store.edit_word(id, index, &text)
                    && let Some(before) = before
                    && !personal_vocabulary::canonically_equal(&before, &text)
                {
                    learn = Some((personal_vocabulary::diff(&before, &text), true));
                }
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
        if let Some((corrections, force)) = learn
            && let Some(glossary) = &self.glossary
            && let Err(error) = glossary.learn(corrections, force).await
        {
            // The successful transcript edit is not discarded when optional
            // glossary persistence fails. The owner retains its last saved rules.
            eprintln!("personal glossary learning: {error}");
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

#[cfg(all(test, target_os = "macos"))]
mod live_tests;
#[cfg(test)]
mod tests;
