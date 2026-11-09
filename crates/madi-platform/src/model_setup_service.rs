//! Serialized native first-run actions and revisioned snapshots.
use crate::{
    model_assets::{Locations, fast_size_matches},
    model_download::{DownloadState, DownloadTask, Downloader},
};
use madi_core::{
    assets::{TRANSCRIPTION, TranslationVariant},
    model_setup::{ModelSetupChoice, ModelSetupCommand, ModelSetupState},
};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Weak};
use tokio::sync::Mutex;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelSnapshot {
    #[serde(flatten)]
    pub state: ModelSetupState,
    pub can_enter_app: bool,
    pub can_continue_transcription: bool,
    pub has_retryable_download: bool,
    pub is_downloading: bool,
    pub memory_gb: u64,
    pub translation_name: String,
    pub translation_runtime_memory_gb: String,
    pub required_size: String,
    pub translation_size: String,
    pub transcription_download_size: String,
    pub recommended_download_size: String,
}

/// Settings actions do not select or reset the first-run recommendation.
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ModelKind {
    Transcription,
    Translation,
}
impl ModelKind {
    fn index(self) -> usize {
        match self {
            Self::Transcription => 0,
            Self::Translation => 1,
        }
    }
}
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum ManagementCommand {
    Download(ModelKind),
    CancelTranslation,
    RefreshTranslation,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelLocations {
    pub transcription: std::path::PathBuf,
    pub translation: std::path::PathBuf,
    pub transcription_installed: bool,
    pub translation_installed: bool,
    pub translation_disk_gb: String,
}

type Formatter = Arc<dyn Fn(u64) -> String + Send + Sync>;
type Changed = Arc<dyn Fn(ModelSnapshot) + Send + Sync>;

#[derive(Clone)]
pub struct ModelSetupService {
    inner: Arc<Mutex<Inner>>,
    changed: Changed,
}

struct Active {
    task: DownloadTask,
    cancelling: bool,
}
struct Inner {
    state: ModelSetupState,
    locations: Locations,
    formatter: Formatter,
    downloader: Option<Downloader>,
    jobs: [Option<Active>; 2],
    generations: [u64; 2],
    closing: bool,
    #[cfg(test)]
    fixtures: Option<[(madi_core::assets::RemoteAsset, String); 2]>,
}

impl Inner {
    fn snapshot(&self) -> ModelSnapshot {
        let ready = self.state.readiness();
        ModelSnapshot {
            state: self.state.clone(),
            can_enter_app: self.state.can_enter_app(),
            can_continue_transcription: self.state.can_continue_transcription(),
            has_retryable_download: self.state.has_retryable_download(),
            is_downloading: self.state.is_downloading(),
            memory_gb: self.state.physical_memory.saturating_add((1 << 30) / 2) / (1 << 30),
            translation_name: self.state.variant.display_name().into(),
            translation_runtime_memory_gb: format!(
                "{:.1}",
                self.state
                    .variant
                    .asset()
                    .approx_runtime_memory_gb
                    .unwrap_or(0.0)
            ),
            required_size: (self.formatter)(TRANSCRIPTION.size_bytes),
            translation_size: (self.formatter)(self.state.variant.asset().size_bytes),
            transcription_download_size: (self.formatter)(
                ready.download_bytes(ModelSetupChoice::TranscriptionOnly, self.state.variant),
            ),
            recommended_download_size: (self.formatter)(
                ready.download_bytes(ModelSetupChoice::Recommended, self.state.variant),
            ),
        }
    }
    fn set_download_state(&mut self, index: usize, value: DownloadState) {
        let slot = if index == 0 {
            &mut self.state.required
        } else {
            &mut self.state.translation
        };
        if *slot != value {
            *slot = value;
            self.state.revision += 1;
        }
    }
}

impl ModelSetupService {
    /// Initializes readiness synchronously and read-only, avoiding a first-run
    /// guide flash on an existing installation. No download is started here.
    pub fn new(
        locations: Locations,
        physical_memory: u64,
        model_override: Option<&str>,
        formatter: impl Fn(u64) -> String + Send + Sync + 'static,
        changed: impl Fn(ModelSnapshot) + Send + Sync + 'static,
    ) -> Self {
        let variant = TranslationVariant::selected(physical_memory, model_override);
        let required_ready = fast_size_matches(&locations.transcription_model(), TRANSCRIPTION);
        let translation_ready =
            fast_size_matches(&locations.translation_model(variant), variant.asset());
        let state = ModelSetupState {
            revision: 0,
            required: if required_ready {
                DownloadState::Ready
            } else {
                DownloadState::Idle
            },
            translation: if translation_ready {
                DownloadState::Ready
            } else {
                DownloadState::Idle
            },
            choice: None,
            variant,
            physical_memory,
            translation_engine_available: locations.translation_engine(variant).is_some(),
        };
        Self {
            inner: Arc::new(Mutex::new(Inner {
                state,
                locations,
                formatter: Arc::new(formatter),
                downloader: None,
                jobs: [None, None],
                generations: [0, 0],
                closing: false,
                #[cfg(test)]
                fixtures: None,
            })),
            changed: Arc::new(changed),
        }
    }

    pub async fn snapshot(&self) -> ModelSnapshot {
        self.inner.lock().await.snapshot()
    }

    pub async fn command(&self, command: ModelSetupCommand) -> Result<ModelSnapshot, String> {
        let mut inner = self.inner.lock().await;
        if inner.closing {
            return Err("model setup is shutting down".into());
        }
        match command {
            ModelSetupCommand::Start(choice) => {
                // The original view removes both start buttons after selection.
                // Reject queued duplicate intents instead of starting two writes.
                if inner.state.choice.is_none() {
                    inner.state.choice = Some(choice);
                    inner.state.revision += 1;
                    if inner.state.required != DownloadState::Ready {
                        self.start(&mut inner, 0, false).await;
                    }
                    if choice == ModelSetupChoice::Recommended
                        && inner.state.translation_engine_available
                        && inner.state.translation != DownloadState::Ready
                    {
                        self.start(&mut inner, 1, false).await;
                    }
                }
            }
            ModelSetupCommand::Retry => {
                if inner.state.choice.is_some() {
                    if inner.state.required.can_retry() {
                        self.start(&mut inner, 0, false).await;
                    }
                    if inner.state.choice == Some(ModelSetupChoice::Recommended)
                        && inner.state.translation_engine_available
                        && matches!(
                            inner.state.translation,
                            DownloadState::Idle | DownloadState::Failed(_)
                        )
                    {
                        self.start(&mut inner, 1, false).await;
                    }
                }
            }
            ModelSetupCommand::ContinueTranscription => {
                if inner.state.can_continue_transcription() {
                    inner.state.choice = Some(ModelSetupChoice::TranscriptionOnly);
                    inner.state.revision += 1;
                }
            }
            ModelSetupCommand::Cancel => {
                self.cancel(&mut inner, &[0, 1]).await;
            }
        }
        let snapshot = inner.snapshot();
        drop(inner);
        (self.changed)(snapshot.clone());
        Ok(snapshot)
    }

    pub async fn locations(&self) -> ModelLocations {
        let inner = self.inner.lock().await;
        let transcription = inner.locations.transcription_model();
        let translation = inner.locations.translation_model(inner.state.variant);
        ModelLocations {
            transcription_installed: fast_size_matches(&transcription, TRANSCRIPTION),
            translation_installed: fast_size_matches(&translation, inner.state.variant.asset()),
            transcription,
            translation,
            translation_disk_gb: format!(
                "{:.1}",
                inner.state.variant.asset().size_bytes as f64 / 1_000_000_000.0
            ),
        }
    }

    pub async fn manage(&self, command: ManagementCommand) -> Result<ModelSnapshot, String> {
        let mut inner = self.inner.lock().await;
        if inner.closing {
            return Err("model setup is shutting down".into());
        }
        match command {
            ManagementCommand::Download(kind) => {
                if matches!(kind, ModelKind::Translation)
                    && !inner.state.translation_engine_available
                {
                    return Err("translation engine is not installed".into());
                }
                self.start(&mut inner, kind.index(), true).await;
            }
            ManagementCommand::CancelTranslation => self.cancel(&mut inner, &[1]).await,
            ManagementCommand::RefreshTranslation => {
                // TranslateModelDownloader.refresh checks the actual file first;
                // a transfer retains its progress only while that file is absent.
                let state = if fast_size_matches(
                    &inner.locations.translation_model(inner.state.variant),
                    inner.state.variant.asset(),
                ) {
                    DownloadState::Ready
                } else if inner.state.translation.is_downloading() {
                    inner.state.translation.clone()
                } else {
                    DownloadState::Idle
                };
                inner.set_download_state(1, state);
            }
        }
        let snapshot = inner.snapshot();
        drop(inner);
        (self.changed)(snapshot.clone());
        Ok(snapshot)
    }

    async fn cancel(&self, inner: &mut Inner, indexes: &[usize]) {
        let mut cancelled_jobs = Vec::new();
        for &index in indexes {
            if inner.jobs[index].as_ref().is_some_and(|job| job.cancelling) {
                // A prior caller may disappear while awaiting the join.
                // Repeated cancel still completes that owned cleanup.
                cancelled_jobs.push(index);
                continue;
            }
            let downloading = if index == 0 {
                &inner.state.required
            } else {
                &inner.state.translation
            };
            if !downloading.is_downloading() {
                continue;
            }
            inner.generations[index] += 1;
            let cancelled = if index == 0 {
                DownloadState::Cancelled
            } else if fast_size_matches(
                &inner.locations.translation_model(inner.state.variant),
                inner.state.variant.asset(),
            ) {
                DownloadState::Ready
            } else {
                DownloadState::Idle
            };
            inner.set_download_state(index, cancelled);
            if let Some(active) = inner.jobs[index].as_mut() {
                active.cancelling = true;
                active.task.request_cancel();
                cancelled_jobs.push(index);
            }
        }
        (self.changed)(inner.snapshot());
        for index in cancelled_jobs {
            // Holding the command mutex serializes a following Retry
            // until the old file/OS lock has been released. Workers
            // never acquire this mutex during transfer or cleanup.
            // Keep ownership in the service across await. If the IPC
            // future itself is dropped, Retry/quit can still join it.
            let result = inner.jobs[index]
                .as_mut()
                .expect("cancelled job")
                .task
                .wait()
                .await;
            inner.jobs[index].take();
            match result {
                Ok(DownloadState::Ready) => inner.set_download_state(index, DownloadState::Ready),
                Ok(DownloadState::Failed(message)) => {
                    inner.set_download_state(index, DownloadState::Failed(message))
                }
                Err(error) => {
                    inner.set_download_state(index, DownloadState::Failed(error.to_string()))
                }
                _ => (),
            }
        }
    }

    async fn start(&self, inner: &mut Inner, index: usize, redownload: bool) {
        if let Some(job) = &mut inner.jobs[index] {
            // A terminal watch update can arrive just before the worker returns.
            // Await that final join so a rapid Retry is never silently ignored.
            if !job.cancelling
                && matches!(
                    job.task.state(),
                    DownloadState::Downloading(_) | DownloadState::Verifying
                )
            {
                return;
            }
            match job.task.wait().await {
                Ok(DownloadState::Ready) => {
                    inner.set_download_state(index, DownloadState::Ready);
                    if !redownload {
                        return;
                    }
                }
                Err(error) => {
                    inner.set_download_state(index, DownloadState::Failed(error.to_string()));
                    return;
                }
                _ => (),
            }
            inner.jobs[index].take();
        }
        if inner.downloader.is_none() {
            match Downloader::new() {
                Ok(client) => inner.downloader = Some(client),
                Err(error) => {
                    inner.set_download_state(index, DownloadState::Failed(error.to_string()));
                    return;
                }
            }
        }
        let asset = if index == 0 {
            TRANSCRIPTION
        } else {
            inner.state.variant.asset()
        };
        let client = inner.downloader.as_ref().expect("download client");
        #[cfg(test)]
        let task = if let Some(fixtures) = &inner.fixtures {
            client.fixture_start(
                fixtures[index].0,
                inner.locations.support.clone(),
                fixtures[index].1.clone(),
            )
        } else {
            client.start(asset, inner.locations.support.clone())
        };
        #[cfg(not(test))]
        let task = client.start(asset, inner.locations.support.clone());
        let receiver = task.subscribe();
        inner.generations[index] += 1;
        let generation = inner.generations[index];
        inner.set_download_state(index, DownloadState::Downloading(0.0));
        inner.jobs[index] = Some(Active {
            task,
            cancelling: false,
        });
        let state = Arc::downgrade(&self.inner);
        let changed = self.changed.clone();
        tokio::spawn(observe(state, changed, index, generation, receiver));
    }

    pub async fn shutdown(&self) -> Result<(), String> {
        let mut inner = self.inner.lock().await;
        inner.closing = true;
        for job in inner.jobs.iter_mut().flatten() {
            job.cancelling = true;
            job.task.request_cancel();
        }
        let mut errors = Vec::new();
        for slot in &mut inner.jobs {
            if let Some(job) = slot.as_mut() {
                match job.task.wait().await {
                    Err(error) => errors.push(error.to_string()),
                    Ok(DownloadState::Failed(message)) => errors.push(message),
                    _ => (),
                }
                slot.take();
            }
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("; "))
        }
    }
}

#[cfg(test)]
mod tests;

async fn observe(
    state: Weak<Mutex<Inner>>,
    changed: Changed,
    index: usize,
    generation: u64,
    mut receiver: tokio::sync::watch::Receiver<DownloadState>,
) {
    let interval = std::time::Duration::from_millis(33);
    let mut next_progress = tokio::time::Instant::now();
    loop {
        let value = receiver.borrow_and_update().clone();
        // Coalesce progress at display cadence. State transitions and terminal
        // results bypass the throttle; no unbounded IPC progress queue is kept.
        if value.is_downloading() && tokio::time::Instant::now() < next_progress {
            tokio::select! {
                _ = tokio::time::sleep_until(next_progress) => (),
                result = receiver.changed() => {
                    if result.is_ok() { continue; }
                },
            }
        }
        let terminal = !matches!(
            value,
            DownloadState::Downloading(_) | DownloadState::Verifying
        );
        {
            let Some(shared) = state.upgrade() else {
                return;
            };
            let mut inner = shared.lock().await;
            if inner.closing || inner.generations[index] != generation {
                return;
            }
            inner.set_download_state(index, value);
            let snapshot = inner.snapshot();
            drop(inner);
            changed(snapshot);
            next_progress = tokio::time::Instant::now() + interval;
        }
        if terminal {
            return;
        }
        if receiver.changed().await.is_err() {
            if let Some(shared) = state.upgrade() {
                let mut inner = shared.lock().await;
                if !inner.closing && inner.generations[index] == generation {
                    inner.set_download_state(
                        index,
                        DownloadState::Failed("download worker stopped without completion".into()),
                    );
                    changed(inner.snapshot());
                }
            }
            return;
        }
    }
}
