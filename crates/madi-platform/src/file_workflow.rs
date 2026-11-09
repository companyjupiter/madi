//! Shared file/live presentation owner. Native hosts supply paths/configuration;
//! web commands only address the current generation and transcript identities.
use crate::{
    asr_config::FileSettings, file_session::Configuration, glossary_service::GlossaryService,
    media_file, preferences_service::PreferencesService, session_archive::SessionArchiveWriter,
};
mod driver;
#[cfg(target_os = "macos")]
mod live_preview;
mod reconciliation;
pub mod translation;
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

pub use madi_core::pipeline_status::ViewPhase;
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
    pub word_spacing: Vec<bool>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub revision: u64,
    pub generation: u64,
    pub phase: ViewPhase,
    pub file_name: String,
    pub has_source_media: bool,
    pub size_label: String,
    pub chunks_done: i64,
    pub chunks_total: i64,
    pub lines: Vec<DisplayLine>,
    pub review_words: Vec<madi_core::review::Span>,
    pub status: madi_core::pipeline_status::Presentation,
    pub speaker_numbers: SpeakerNumbers,
    pub speaker_names: BTreeMap<i64, String>,
    pub partial: String,
    pub speaker_island_absorption: bool,
    pub archive: ArchiveSnapshot,
    pub live: Option<LiveSnapshot>,
    pub permission_issue: Option<crate::audio_permissions::Issue>,
    pub admission_pending: bool,
    #[cfg(test)]
    #[serde(skip)]
    pub(crate) reconcile_replies: Vec<Option<String>>,
    pub reconciling: bool,
    pub reconcile_note: Option<String>,
    pub has_speaker_corrections: bool,
    pub language_corrections_pending: usize,
    pub translation_queue_depth: usize,
    pub translation_queued_lines: usize,
    pub translation_backlog: usize,
    pub translation_backfill_remaining: usize,
}
#[derive(Clone, Debug)]
pub struct ReviewInput {
    pub source: Option<PathBuf>,
    pub queue: Vec<madi_core::review::Span>,
    pub flagged: Vec<madi_core::review::Span>,
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
            has_source_media: false,
            size_label: String::new(),
            chunks_done: 0,
            chunks_total: 0,
            lines: Vec::new(),
            review_words: Vec::new(),
            status: Default::default(),
            speaker_numbers: SpeakerNumbers::default(),
            speaker_names: BTreeMap::new(),
            partial: String::new(),
            speaker_island_absorption: false,
            archive: ArchiveSnapshot::default(),
            live: None,
            permission_issue: None,
            admission_pending: false,
            #[cfg(test)]
            reconcile_replies: Vec::new(),
            reconciling: false,
            reconcile_note: None,
            has_speaker_corrections: false,
            language_corrections_pending: 0,
            translation_queue_depth: 0,
            translation_queued_lines: 0,
            translation_backlog: 0,
            translation_backfill_remaining: 0,
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
    RevertReconcile,
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
    #[cfg(all(test, target_os = "macos"))]
    InspectReconciliationTimer(oneshot::Sender<Option<Instant>>),
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
    ReviewInput {
        generation: u64,
        reply: oneshot::Sender<io::Result<Option<ReviewInput>>>,
    },
    PlaybackSource {
        generation: u64,
        reply: oneshot::Sender<io::Result<Option<PathBuf>>>,
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
        Self::with_translation(configuration, archive_settings, None, changed)
    }
    pub fn with_translation(
        configuration: Configuration,
        archive_settings: Option<ArchiveSettings>,
        translation_resources: Option<translation::Resources>,
        changed: impl Fn(Snapshot) + Send + Sync + 'static,
    ) -> io::Result<Self> {
        let translations = translation::Translations::new(translation_resources)?;
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
                source_media: None,
                review_cache_key: None,
                coverage_gaps: Vec::new(),
                hang_recoveries: 0,
                silence: None,
                silence_tick: None,
                store: TranscriptStore::default(),
                glossary: None,
                preferences: None,
                preference_updates: None,
                translations,
                reconciliation: Default::default(),
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
                #[cfg(target_os = "macos")]
                live_preview: None,
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
    /// Bounded projection for native playback reconciliation. Avoid cloning all
    /// transcript lines on every meter/preview update on the main thread.
    pub fn playback_identity(&self) -> (u64, bool) {
        let state = self.owner.snapshot.borrow();
        (state.generation, state.has_source_media)
    }
    /// Resolve only the source admitted by the native file picker. This path
    /// never enters a renderer payload and expires when the session is reset.
    pub async fn review_input(&self, generation: u64) -> io::Result<Option<ReviewInput>> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::ReviewInput { generation, reply })
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }
    pub async fn playback_source(&self, generation: u64) -> io::Result<Option<PathBuf>> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::PlaybackSource { generation, reply })
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
    source_media: Option<PathBuf>,
    review_cache_key: Option<(u64, u64)>,
    coverage_gaps: Vec<f64>,
    hang_recoveries: usize,
    silence: Option<madi_core::pipeline_status::SilenceWatch>,
    silence_tick: Option<Instant>,
    store: TranscriptStore,
    glossary: Option<GlossaryService>,
    preferences: Option<PreferencesService>,
    preference_updates: Option<watch::Receiver<crate::preferences_service::Snapshot>>,
    translations: translation::Translations,
    reconciliation: reconciliation::Reconciliation,
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
    #[cfg(target_os = "macos")]
    live_preview: Option<live_preview::LivePreview>,
    archive_settings: Option<ArchiveSettings>,
    archive_writer: Arc<std::sync::Mutex<SessionArchiveWriter>>,
}
// The shipping silence watch uses Date, so clock changes affect its elapsed
// interval too. Tokio Instant still schedules polls; it is not the silence clock.
fn status_wall_seconds() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or_else(
            |error| -error.duration().as_secs_f64(),
            |duration| duration.as_secs_f64(),
        )
}
impl Worker {
    async fn execute(mut self) -> io::Result<()> {
        let result = self.run_loop().await;
        self.cancel_admission().await;
        // Keep the async owner alive until native children and owned WAVs exit.
        self.stop_reconciliation().await;
        let cleanup = self.session.shutdown().await;
        self.stop_translation().await;
        self.translations.broker.shutdown();
        let dna_cleanup = self.translations.broker.wait().await;
        result.and(cleanup).and(dna_cleanup)
    }
    fn publish_status(&mut self) {
        use madi_core::pipeline_status::{self, Signals, SilenceWatch};
        if self.state.live.is_some()
            && self.state.phase == ViewPhase::Recording
            && self.silence.is_none()
        {
            self.silence = Some(SilenceWatch::new(status_wall_seconds()));
            self.silence_tick = Some(Instant::now() + Duration::from_secs(3));
        } else if !self.state.phase.is_recording() {
            self.silence = None;
            self.silence_tick = None;
        }
        #[cfg(target_os = "macos")]
        let segments = self.live_preview.as_ref().map_or(0, |p| p.segments_pending);
        #[cfg(not(target_os = "macos"))]
        let segments = 0;
        let signals = Signals {
            phase: self.state.phase.clone(),
            chunks_done: self.state.chunks_done,
            chunks_total: self.state.chunks_total,
            translate_backlog: self.state.translation_backlog,
            translate_queued_lines: self.state.translation_queued_lines,
            translate_queue_depth: self.state.translation_queue_depth,
            backfill_remaining: self.state.translation_backfill_remaining,
            segments_in_flight: segments,
            mic_silent: self.silence.as_ref().is_some_and(|w| w.silent),
            capture_ended_reason: self
                .state
                .live
                .as_ref()
                .and_then(|s| s.capture_ended_reason.clone()),
            coverage_gaps: self.coverage_gaps.clone(),
            hang_recoveries: self.hang_recoveries,
            reconciling: self.state.reconciling,
            language_corrections_pending: self.state.language_corrections_pending,
        };
        let language = self
            .preferences
            .as_ref()
            .map(|p| p.snapshot().presentation.ui_language)
            .unwrap_or_default();
        self.state.status = pipeline_status::presentation(&signals, language);
    }
    fn review_threshold(&self) -> f64 {
        self.preferences
            .as_ref()
            .map_or(0.55, |p| p.snapshot().settings.vad_conf_threshold)
    }
    fn publish(&mut self) {
        let threshold = self.review_threshold();
        let key = (self.store.display_revision, threshold.to_bits());
        if self.review_cache_key != Some(key) {
            self.state.review_words =
                madi_core::review::queue(self.store.display_lines(), threshold);
            self.review_cache_key = Some(key);
        }
        self.state.translation_queue_depth = self.translations.policy.depth;
        self.state.translation_queued_lines = self.translations.policy.queued_lines;
        self.state.translation_backlog = self.translations.policy.backlog_lines();
        self.state.translation_backfill_remaining = self.translations.policy.backfill_remaining();
        self.publish_status();
        self.state.lines = self
            .store
            .display_lines()
            .iter()
            .map(|line| DisplayLine {
                word_spacing: madi_core::review::word_spacing(line),
                line: line.clone(),
                text: line.text(),
                source_revision: madi_core::transcript::text_revision(&line.text()).to_string(),
            })
            .collect();
        self.state.speaker_numbers = self.store.speaker_numbers.clone();
        self.state.has_speaker_corrections = self.store.has_speaker_corrections();
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
    async fn clear(&mut self) {
        self.stop_reconciliation().await;
        self.reconciliation = Default::default();
        self.stop_translation().await;
        self.translations.policy = Default::default();
        self.translations.interim.clear();
        self.translations.language_token = None;
        self.translations.finalized = false;
        self.translations.idle = None;
        self.translations.preview_tick = None;
        #[cfg(target_os = "macos")]
        {
            self.live_preview = None;
        }
        self.run = None;
        self.pending_failure = None;
        self.checkpoint = None;
        self.countdown = None;
        // All disk work is joined before another command can reach clear.
        self.archive_writer = Arc::new(std::sync::Mutex::new(SessionArchiveWriter::default()));
        self.source_media = None;
        self.review_cache_key = None;
        self.coverage_gaps.clear();
        self.hang_recoveries = 0;
        self.silence = None;
        self.silence_tick = None;
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
        self.reconciliation.timer = None;
        if self.state.phase != ViewPhase::Done {
            self.stop_reconciliation().await;
        }
        #[cfg(target_os = "macos")]
        {
            self.live_preview = None;
        }
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
        self.translations.tail = None;
        self.translations.idle = None;
        self.translations.finalized = true;
        self.translations.preview_tick = None;
        self.translate_stable(true).await;
        self.translations.interim.clear();
        self.auto_save().await;
        if self.state.phase == ViewPhase::Done {
            self.kick_reconcile(false).await;
        }
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
        self.clear().await;
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
            let preference_pending = self.preference_updates.is_some();
            let correction_pending = self.reconciliation.correction_active();
            let reconciliation_deadline = self.reconciliation.timer;
            tokio::select! {
                command=self.input.recv(),if !self.closing=>match command {
                    #[cfg(target_os="macos")]
                    Some(Command::StartLive {request,admission_error,reply})=>{let result=self.start_live(request,admission_error).await;let _=reply.send(result);},
                    #[cfg(target_os="macos")]
                    Some(Command::LiveControl {generation,command,reply})=>{let result=self.live_control(generation,command).await;let _=reply.send(result);},
                    Some(Command::Preferences(preferences, reply))=>{
                        self.preference_updates=Some(preferences.subscribe());
                        self.preferences=Some(preferences);self.publish();let _=reply.send(Ok(()));
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
                    Some(Command::ReviewInput {generation,reply})=>{
                        let input = (generation == self.state.generation && !self.closing).then(|| ReviewInput {
                            source:self.source_media.clone(),
                            queue:madi_core::review::queue(self.store.lines(), self.review_threshold()),
                            flagged:madi_core::review::queue(self.store.display_lines(), self.review_threshold()),
                        });
                        let _=reply.send(Ok(input));
                    },
                    Some(Command::PlaybackSource {generation,reply})=>{
                        let path = if generation == self.state.generation && !self.closing {
                            self.source_media.clone()
                        } else { None };
                        let _ = reply.send(Ok(path));
                    },
                    Some(Command::Start {path,settings,admission_error,reply})=>{
                        let result=self.start(path,settings,admission_error).await;
                        let _=reply.send(result);
                    },
                    Some(Command::Reset {generation,reply})=>{
                        let result=if generation==self.state.generation && !self.state.phase.is_recording() {
                            self.cancel_admission().await;
                            self.clear().await; self.publish();
                            self.session.reset().await.map(|()|self.state.clone())
                        }else {Ok(self.state.clone())};
                        let _=reply.send(result);
                    },
                    Some(Command::Edit {generation,edit,reply})=>{
                        let result=if generation==self.state.generation {self.edit(edit).await} else {Ok(self.state.clone())};
                        let _=reply.send(result);
                    },
                    #[cfg(all(test,target_os="macos"))]
                    Some(Command::InspectReconciliationTimer(reply))=>{
                        let _=reply.send(self.reconciliation.timer);
                    },
                    Some(Command::Shutdown)|None=>{
                        #[cfg(target_os="macos")]
                        if self.state.live.is_some() && (self.state.phase.is_recording() || self.state.phase==ViewPhase::Flushing) {
                            if self.state.phase.is_recording() && let Some(run)=self.run {self.session.control(run,LiveControl::Stop)?;}
                            self.closing=true; continue;
                        }
                        if self.translations.finalized && self.post_work_pending() {self.closing=true;continue;}
                        return Ok(());
                    },
                },
                update=self.session.next()=>{
                    let Some(update)=update else {return Err(closed())};
                    if self.run!=Some(update.run) {continue;}
                    match update.kind {
                        UpdateKind::Output(Output::Stdout(event))=>self.ingest(event).await,
                        UpdateKind::Output(Output::Structured(madi_protocol::structured::Event::Segment(segment)))=>{
                            if segment.dropped || segment.fallback!="none" || segment.avg_logprob < -1.0 {
                                self.reconciliation.risks.push((segment.t0,segment.t1));
                            }
                        },
                        UpdateKind::Phase(Phase::Processing)=>{self.state.phase=ViewPhase::Processing;self.publish();},
                        UpdateKind::Phase(phase)=>{
                            if let Phase::Error(failure)=phase {self.pending_failure=Some(failure_message(&failure,&self.state.file_name));}
                            else if self.state.live.is_some() {
                                self.state.phase=match phase {Phase::EngineStarting=>ViewPhase::EngineStarting,Phase::Ready=>ViewPhase::Ready,Phase::Recording=>ViewPhase::Recording,Phase::Paused=>ViewPhase::Paused,Phase::Flushing=>ViewPhase::Flushing,_=>self.state.phase.clone()};self.publish();
                            }
                        },
                        UpdateKind::Finished=>{self.state.phase=ViewPhase::Done;self.finish().await;if self.closing && !self.post_work_pending() {return Ok(());}},
                        UpdateKind::Failed=>{
                            if let Some(message)=self.pending_failure.take() {self.state.phase=ViewPhase::Error {message};}
                            self.finish().await;
                            if self.closing && !self.post_work_pending() {return Ok(());}
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
                    #[cfg(target_os="macos")]
                    self.pump_preview().await;
                },
                event=self.translations.broker.next()=>{
                    if let Some(event)=event {
                        self.translation_event(&event).await;
                        self.reconciliation_event(&event).await;
                    }
                    else {return Err(io::Error::other("translation broker closed"));}
                    if self.closing && self.translations.finalized && !self.post_work_pending() {return Ok(());}
                },
                result=self.reconciliation.next_correction(),if correction_pending=>{
                    self.correction_finished(result).await;
                    if self.closing && self.translations.finalized && !self.post_work_pending() {return Ok(());}
                },
                _=deadline(reconciliation_deadline)=>self.reconciliation_tick().await,
                _=deadline(self.translations.tail.map(|tail|tail.0))=>self.translation_tail().await,
                _=deadline(self.translations.idle)=>self.translation_idle().await,
                _=deadline(self.translations.preview_tick)=>{
                    self.translations.preview_tick=(self.state.live.is_some() && self.state.phase.is_busy())
                        .then(||Instant::now()+Duration::from_secs(1));
                },
                changed=async{self.preference_updates.as_mut().unwrap().changed().await},if preference_pending=>{
                    if changed.is_err() {self.preference_updates=None;}
                    else {
                        if self.preferences.as_ref().is_some_and(|p|!p.has_translation_targets()) {self.stop_translation().await;}
                        self.publish();
                    }
                },
                _=deadline(self.silence_tick)=>{
                    self.silence_tick=None;
                    if let Some(watch)=&mut self.silence
                        && watch.tick(&self.state.phase,status_wall_seconds()) {
                        self.silence_tick=Some(Instant::now()+Duration::from_secs(3));
                    }
                    self.publish();
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
            #[cfg(target_os = "macos")]
            self.pump_preview().await;
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
        self.clear().await;
        self.translations.language_token = settings.language_token;
        self.store.features = Features::for_language(settings.language_token);
        self.state.speaker_island_absorption = self.store.features.speaker_island_absorption;
        let file = media_file::summary(&path);
        self.source_media = Some(path.clone());
        self.state.has_source_media = true;
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
        self.stop_translation().await;
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
                let preferences = preferences.clone();
                let glossary = self.glossary.clone();
                let initial_terms = request.settings.common.bias_terms.clone();
                request.recovery_settings = Some(Arc::new(move || {
                    let terms = glossary
                        .as_ref()
                        .map(|g| g.with_value(personal_vocabulary::bias_terms))
                        .unwrap_or_else(|| initial_terms.clone());
                    crate::asr_config::LiveSettings::from_setup(
                        &preferences.snapshot().setup,
                        memory,
                        terms,
                    )
                    .map_err(io::Error::other)
                }));
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
            self.clear().await;
            self.translations.language_token = request.settings.common.language_token;
            self.translations.idle = Some(Instant::now() + Duration::from_secs(5));
            self.translations.preview_tick = Some(Instant::now() + Duration::from_secs(1));
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
            self.live_preview = Some(live_preview::LivePreview::new(
                request.capture.preview_enabled,
                request.settings.common.language_token.is_some(),
            ));
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
            Live::Recovery {
                attempts,
                language_token,
            } => {
                self.hang_recoveries = attempts;
                self.store.mark_diar_namespace_broken();
                let refreshed = Features::for_language(language_token);
                self.store.features.speaker_island_absorption = refreshed.speaker_island_absorption;
                self.store.features.weak_label_continuation = refreshed.weak_label_continuation;
                self.state.speaker_island_absorption = refreshed.speaker_island_absorption;
                self.publish();
            }
            Live::Coverage {
                segments_in_flight,
                gaps,
            } => {
                self.coverage_gaps = gaps;
                if let Some(preview) = &mut self.live_preview {
                    preview.segments_pending = segments_in_flight;
                }
                if self.render.is_none() {
                    self.render = Some(Instant::now() + Duration::from_millis(33));
                }
            }
            Live::Preview { offset, wav } => {
                if let Some(preview) = &mut self.live_preview {
                    preview.scheduler.feed(wav, offset);
                }
            }
            Live::Segment { offset, wav, .. } => {
                self.reconciliation.segments.push((offset, wav));
            }
            Live::RecordingStarted => {
                self.start_reconciliation_timer();
                self.checkpoint = Some(Instant::now() + Duration::from_secs(30));
            }
            Live::RecordedSeconds(seconds) => {
                if let Some(live) = &mut self.state.live {
                    live.seconds = seconds;
                    self.publish();
                }
            }
            Live::Level(level) => {
                if let Some(watch) = &mut self.silence {
                    watch.level(level, status_wall_seconds());
                }
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
            // Remaining AI policies have separate consumers.
            _ => {}
        }
    }
    async fn ingest(&mut self, event: Event) {
        #[cfg(target_os = "macos")]
        if self.preview_event(&event) {
            return;
        }
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
        if matches!(event, Event::Word { .. } | Event::WordSectionBegin) {
            self.apply_stable_passes();
            self.translate_stable(false).await;
            if matches!(event, Event::Word { .. }) {
                self.arm_translation_tail();
            }
        }
        // Progress/name callbacks are low-frequency UI state, also coalesced.
        if self.render.is_none() {
            self.render = Some(Instant::now() + Duration::from_millis(33));
        }
    }
    fn apply_stable_passes(&mut self) {
        let enabled = self
            .preferences
            .as_ref()
            .is_some_and(PreferencesService::has_translation_targets);
        if let Some(glossary) = &self.glossary {
            glossary.with_value(|glossary| {
                self.text_passes.stable(
                    &mut self.store,
                    Some(glossary),
                    enabled,
                    &self.state.partial,
                    false,
                )
            });
        } else {
            self.text_passes
                .stable(&mut self.store, None, enabled, &self.state.partial, false);
        }
    }
    async fn edit(&mut self, edit: Edit) -> io::Result<Snapshot> {
        let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "invalid transcript identity");
        let mut learn = None;
        let mut retranslate = None;
        match edit {
            Edit::RevertReconcile => self.revert_reconcile(),
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
                    retranslate = Some(id);
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
                    retranslate = Some(id);
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
        if let Some(id) = retranslate {
            self.translate_line(id, true).await;
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
