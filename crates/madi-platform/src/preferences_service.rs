//! One native owner serializes disk commits, setup intents and file admission.
//! An accepted command outlives its IPC caller and is joined at app shutdown.
use crate::{media_file, preferences::Store};
use madi_core::{
    preferences::{Preferences, Presentation, PresentationCommand},
    setup::{SetupCommand, SetupState},
};
use serde::Serialize;
use std::{io, path::PathBuf, sync::Arc, thread};
use tokio::sync::{Mutex, mpsc, oneshot, watch};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub revision: u64,
    pub setup: SetupState,
    pub presentation: Presentation,
}
type Reply<T> = oneshot::Sender<io::Result<T>>;
enum Command {
    Setup(SetupCommand, Reply<Snapshot>),
    Presentation(PresentationCommand, Reply<Snapshot>),
    Stage(PathBuf, Reply<Snapshot>),
    Take(Reply<Option<(PathBuf, SetupState)>>),
    Shutdown,
}
struct Owner {
    commands: mpsc::UnboundedSender<Command>,
    snapshot: watch::Receiver<Snapshot>,
    task: Mutex<Option<thread::JoinHandle<()>>>,
}
impl Drop for Owner {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Shutdown);
    }
}
#[derive(Clone)]
pub struct PreferencesService {
    owner: Arc<Owner>,
}
impl PreferencesService {
    pub fn new(mut store: Store, changed: impl Fn(Snapshot) + Send + 'static) -> io::Result<Self> {
        let state = Snapshot {
            revision: 0,
            setup: store.value().setup(),
            presentation: store.value().presentation.clone(),
        };
        let (commands, mut input) = mpsc::unbounded_channel();
        let (output, snapshot) = watch::channel(state.clone());
        let task = thread::Builder::new()
            .name("madi-preferences".into())
            .spawn(move || {
                let mut state = state;
                let mut selected = None;
                while let Some(command) = input.blocking_recv() {
                    // An explicit durable choice must survive relaunch even
                    // when it equals the imported fallback. Transient native
                    // selection alone must never create a preferences file.
                    let explicit = matches!(&command, Command::Presentation(..)) ||
                        matches!(&command, Command::Setup(action, _) if !matches!(action, SetupCommand::InputDevice(_) | SetupCommand::ClearStagedFile));
                    let mut next = state.clone();
                    let mut next_selected = selected.clone();
                    let reply = match command {
                        Command::Shutdown => break,
                        Command::Take(reply) => {
                            let result = selected.take().map(|path| {
                                state
                                    .setup
                                    .apply(SetupCommand::ClearStagedFile)
                                    .expect("clear selection");
                                state.revision += 1;
                                output.send_replace(state.clone());
                                changed(state.clone());
                                (path, state.setup.clone())
                            });
                            let _ = reply.send(Ok(result));
                            continue;
                        }
                        Command::Setup(command, reply) => {
                            if let Err(error) = next.setup.apply(command) {
                                let _ = reply
                                    .send(Err(io::Error::new(io::ErrorKind::InvalidInput, error)));
                                continue;
                            }
                            reply
                        }
                        Command::Presentation(command, reply) => {
                            next.presentation.apply(command);
                            reply
                        }
                        Command::Stage(path, reply) => {
                            next.setup.staged_file = Some(media_file::summary(&path));
                            next.setup.revision += 1;
                            next_selected = Some(path);
                            reply
                        }
                    };
                    let durable = Preferences::project(&next.setup, next.presentation.clone());
                    if (durable != *store.value() || explicit && !store.is_persisted())
                        && let Err(error) = store.save(durable)
                    {
                        let _ = reply.send(Err(error));
                        continue;
                    }
                    selected = if next.setup.staged_file.is_none() {
                        None
                    } else {
                        next_selected
                    };
                    next.revision += 1;
                    state = next;
                    output.send_replace(state.clone());
                    changed(state.clone());
                    let _ = reply.send(Ok(state.clone()));
                }
            })?;
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
    async fn request<T>(&self, command: impl FnOnce(Reply<T>) -> Command) -> io::Result<T> {
        let (send, receive) = oneshot::channel();
        self.owner
            .commands
            .send(command(send))
            .map_err(|_| closed())?;
        receive.await.map_err(|_| closed())?
    }
    pub async fn setup(&self, command: SetupCommand) -> io::Result<Snapshot> {
        self.request(|reply| Command::Setup(command, reply)).await
    }
    pub async fn presentation(&self, command: PresentationCommand) -> io::Result<Snapshot> {
        self.request(|reply| Command::Presentation(command, reply))
            .await
    }
    pub async fn stage(&self, path: PathBuf) -> io::Result<Snapshot> {
        self.request(|reply| Command::Stage(path, reply)).await
    }
    pub async fn take_file(&self) -> io::Result<Option<(PathBuf, SetupState)>> {
        self.request(Command::Take).await
    }
    pub async fn shutdown(&self) -> io::Result<()> {
        let mut task = self.owner.task.lock().await;
        if let Some(handle) = task.take() {
            let _ = self.owner.commands.send(Command::Shutdown);
            tokio::task::spawn_blocking(move || handle.join())
                .await
                .map_err(|error| io::Error::other(error.to_string()))?
                .map_err(|_| io::Error::other("preferences owner panicked"))?;
        }
        Ok(())
    }
}
fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "preferences owner closed")
}

#[cfg(test)]
mod tests {
    use super::*;
    use madi_core::{
        preferences::{Legacy, UILanguage},
        setup::{Language, MeetingMode},
    };
    fn baseline() -> Preferences {
        Preferences::from_legacy(Legacy::default())
    }

    #[tokio::test]
    async fn explicit_unchanged_choice_is_saved_and_later_legacy_changes_do_not_override_it() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("preferences.json");
        let worker =
            PreferencesService::new(Store::load(path.clone(), baseline()).unwrap(), |_| {})
                .unwrap();
        worker.setup(SetupCommand::Diarize(true)).await.unwrap();
        worker.shutdown().await.unwrap();
        let changed_legacy = Preferences::from_legacy(Legacy {
            diarize_enabled: Some(false),
            ..Legacy::default()
        });
        assert!(Store::load(path, changed_legacy).unwrap().value().diarize);
    }

    #[tokio::test]
    async fn durable_updates_precede_publication_and_survive_relaunch_without_native_authority() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config/preferences.json");
        let probe = path.clone();
        let worker = PreferencesService::new(
            Store::load(path.clone(), baseline()).unwrap(),
            move |snapshot| {
                if probe.exists() {
                    let disk = Store::load(probe.clone(), baseline()).unwrap();
                    assert_eq!(
                        disk.value(),
                        &Preferences::project(&snapshot.setup, snapshot.presentation)
                    );
                }
            },
        )
        .unwrap();
        let media = root.path().join("secret-name.wav");
        std::fs::write(&media, b"fixture").unwrap();
        worker.stage(media.clone()).await.unwrap();
        worker
            .setup(SetupCommand::InputDevice(Some("coreaudio:83".into())))
            .await
            .unwrap();
        assert!(
            !path.exists(),
            "transient selection must not create a preference file"
        );
        worker
            .setup(SetupCommand::MeetingMode(MeetingMode::Lecture))
            .await
            .unwrap();
        worker.setup(SetupCommand::Diarize(true)).await.unwrap();
        worker.setup(SetupCommand::SpeakerCount(4)).await.unwrap();
        worker
            .setup(SetupCommand::InputLanguage(Some(Language::Japanese)))
            .await
            .unwrap();
        worker
            .presentation(PresentationCommand::UILanguage(UILanguage::Ja))
            .await
            .unwrap();
        worker
            .presentation(PresentationCommand::ContentMode(false))
            .await
            .unwrap();
        worker
            .presentation(PresentationCommand::LargerText)
            .await
            .unwrap();
        let (selected, setup) = worker.take_file().await.unwrap().unwrap();
        assert_eq!(selected, media);
        assert_eq!(setup.speaker_count, 4);
        assert!(setup.diarize);
        assert_eq!(setup.language_token(), Some(50266));
        assert!(setup.staged_file.is_none());
        assert!(worker.take_file().await.unwrap().is_none());
        worker.shutdown().await.unwrap();
        let bytes = std::fs::read_to_string(&path).unwrap();
        assert!(
            !bytes.contains("secret-name")
                && !bytes.contains("coreaudio")
                && !bytes.contains("revision")
        );
        let restored =
            PreferencesService::new(Store::load(path, baseline()).unwrap(), |_| {}).unwrap();
        let state = restored.snapshot();
        assert_eq!(state.setup.meeting_mode, MeetingMode::Lecture);
        assert_eq!(state.setup.speaker_count, 4);
        assert!(state.setup.diarize);
        assert!(state.setup.staged_file.is_none() && state.setup.input_device_id.is_none());
        assert_eq!(state.presentation.ui_language, UILanguage::Ja);
        assert!(!state.presentation.content_mode);
        assert_eq!(state.presentation.font_size, 18.0);
        restored.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn failed_disk_commit_preserves_state_selection_and_existing_data() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("preferences.json");
        let worker =
            PreferencesService::new(Store::load(path.clone(), baseline()).unwrap(), |_| {})
                .unwrap();
        let media = root.path().join("source.wav");
        std::fs::write(&media, b"source").unwrap();
        worker.stage(media.clone()).await.unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("foreign"), b"keep").unwrap();
        let before = worker.snapshot();
        assert!(
            worker
                .setup(SetupCommand::MeetingMode(MeetingMode::Lecture))
                .await
                .is_err()
        );
        assert_eq!(worker.snapshot().revision, before.revision);
        assert_eq!(worker.snapshot().setup, before.setup);
        assert_eq!(worker.take_file().await.unwrap().unwrap().0, media);
        assert_eq!(std::fs::read(path.join("foreign")).unwrap(), b"keep");
        worker.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn canceled_reply_does_not_cancel_commit_and_shutdown_joins_the_owner() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("preferences.json");
        let (published, ready) = oneshot::channel();
        let mut published = Some(published);
        let (release, wait) = std::sync::mpsc::channel();
        let callback = std::sync::Mutex::new(move |_| {
            if let Some(ready) = published.take() {
                let _ = ready.send(());
                wait.recv().unwrap();
            }
        });
        let worker = PreferencesService::new(
            Store::load(path.clone(), baseline()).unwrap(),
            move |value| (callback.lock().unwrap())(value),
        )
        .unwrap();
        let (reply, abandoned) = oneshot::channel();
        drop(abandoned);
        worker
            .owner
            .commands
            .send(Command::Setup(SetupCommand::SpeakerCount(5), reply))
            .unwrap();
        ready.await.unwrap();
        let shutdown = worker.clone();
        let mut joined = tokio::spawn(async move { shutdown.shutdown().await });
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), &mut joined)
                .await
                .is_err()
        );
        release.send(()).unwrap();
        joined.await.unwrap().unwrap();
        assert_eq!(
            Store::load(path, baseline()).unwrap().value().speaker_count,
            5
        );
        assert!(worker.setup(SetupCommand::Diarize(false)).await.is_err());
    }
}
