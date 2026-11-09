//! One persistent personal glossary shared by settings and file sessions.
use madi_core::{glossary::Glossary, personal_vocabulary::Correction};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, Write},
    path::PathBuf,
    sync::Arc,
    thread,
};
use tokio::sync::{Mutex, mpsc, oneshot, watch};

pub struct Store {
    path: PathBuf,
    value: Glossary,
}
impl Store {
    pub fn load(path: PathBuf, fallback: Glossary) -> io::Result<Self> {
        let value = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => fallback,
            Err(error) => return Err(error),
        };
        Ok(Self { path, value })
    }
    pub fn value(&self) -> &Glossary {
        &self.value
    }
    fn save(&mut self, value: Glossary) -> io::Result<()> {
        let parent = self.path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "missing glossary directory")
        })?;
        fs::create_dir_all(parent)?;
        let mut pending = tempfile::Builder::new()
            .prefix(".madi-glossary-")
            .tempfile_in(parent)?;
        serde_json::to_writer_pretty(&mut pending, &value)?;
        pending.write_all(b"\n")?;
        pending.as_file().sync_all()?;
        pending
            .persist(&self.path)
            .map_err(|failure| failure.error)?;
        self.value = value;
        Ok(())
    }
}
#[cfg(target_os = "macos")]
pub fn read_legacy(defaults: &objc2_foundation::NSUserDefaults) -> Glossary {
    defaults
        .dataForKey(&objc2_foundation::NSString::from_str("personalGlossary"))
        .and_then(|data| serde_json::from_slice(&data.to_vec()).ok())
        .unwrap_or_default()
}
pub fn legacy() -> io::Result<Glossary> {
    #[cfg(target_os = "macos")]
    {
        use objc2::{AllocAnyThread, rc::autoreleasepool};
        use objc2_foundation::{NSString, NSUserDefaults};
        autoreleasepool(|_| {
            let defaults = NSUserDefaults::initWithSuiteName(
                NSUserDefaults::alloc(),
                Some(&NSString::from_str("com.companyjupiter.madi")),
            )
            .ok_or_else(|| io::Error::other("legacy glossary unavailable"))?;
            Ok(read_legacy(&defaults))
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(Glossary::default())
    }
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayEntry {
    pub wrong: String,
    pub right: String,
    pub hits_label: String,
    pub active: bool,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub revision: u64,
    pub glossary: Glossary,
    pub display_entries: Vec<DisplayEntry>,
    pub minimum_hits_label: String,
    pub active_count: usize,
}
impl Snapshot {
    fn new(revision: u64, glossary: Glossary) -> Self {
        let display_entries = glossary
            .display_entries()
            .into_iter()
            .map(|entry| DisplayEntry {
                wrong: entry.wrong.clone(),
                right: entry.right.clone(),
                hits_label: entry.hits.to_string(),
                active: entry.hits >= glossary.min_hits.max(1),
            })
            .collect();
        Self {
            revision,
            display_entries,
            minimum_hits_label: glossary.min_hits.to_string(),
            active_count: glossary.active_entries().len(),
            glossary,
        }
    }
}
#[derive(Debug, Deserialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum SettingsCommand {
    Enabled(bool),
    MinimumHits(u8),
    Forget(String),
    Clear,
}
type Reply = oneshot::Sender<io::Result<Snapshot>>;
enum Command {
    Settings(SettingsCommand, Reply),
    Learn(Vec<Correction>, bool, Reply),
    Current(Reply),
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
pub struct GlossaryService {
    owner: Arc<Owner>,
}
impl GlossaryService {
    pub fn new(mut store: Store, changed: impl Fn(Snapshot) + Send + 'static) -> io::Result<Self> {
        let initial = Snapshot::new(0, store.value.clone());
        let (commands, mut input) = mpsc::unbounded_channel();
        let (output, snapshot) = watch::channel(initial.clone());
        let task = thread::Builder::new()
            .name("madi-glossary".into())
            .spawn(move || {
                let mut state = initial;
                while let Some(command) = input.blocking_recv() {
                    let mut next = state.glossary.clone();
                    let (reply, result) = match command {
                        Command::Shutdown => break,
                        Command::Current(reply) => {
                            let _ = reply.send(Ok(state.clone()));
                            continue;
                        }
                        Command::Settings(command, reply) => {
                            let result = match command {
                                SettingsCommand::Enabled(enabled) => {
                                    next.enabled = enabled;
                                    Ok(())
                                }
                                SettingsCommand::MinimumHits(value) if (1..=5).contains(&value) => {
                                    next.min_hits = value.into();
                                    Ok(())
                                }
                                SettingsCommand::MinimumHits(_) => {
                                    Err("invalid glossary minimum hits")
                                }
                                SettingsCommand::Forget(wrong) => {
                                    next.forget(&wrong);
                                    Ok(())
                                }
                                SettingsCommand::Clear => {
                                    next.clear();
                                    Ok(())
                                }
                            };
                            (reply, result)
                        }
                        Command::Learn(corrections, force, reply) => {
                            if corrections.is_empty() && !force {
                                let _ = reply.send(Ok(state.clone()));
                                continue;
                            }
                            let result = corrections
                                .iter()
                                .try_for_each(|pair| next.learn(&pair.wrong, &pair.right));
                            (reply, result)
                        }
                    };
                    if let Err(error) = result {
                        let _ = reply.send(Err(io::Error::new(io::ErrorKind::InvalidInput, error)));
                        continue;
                    }
                    if let Err(error) = store.save(next.clone()) {
                        let _ = reply.send(Err(error));
                        continue;
                    }
                    state = Snapshot::new(state.revision.wrapping_add(1), next);
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
    pub fn with_value<T>(&self, read: impl FnOnce(&Glossary) -> T) -> T {
        read(&self.owner.snapshot.borrow().glossary)
    }
    async fn request(&self, command: impl FnOnce(Reply) -> Command) -> io::Result<Snapshot> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(command(reply))
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }
    pub async fn current(&self) -> io::Result<Snapshot> {
        self.request(Command::Current).await
    }
    pub async fn settings(&self, command: SettingsCommand) -> io::Result<Snapshot> {
        self.request(|reply| Command::Settings(command, reply))
            .await
    }
    pub async fn learn(
        &self,
        corrections: Vec<Correction>,
        force_save: bool,
    ) -> io::Result<Snapshot> {
        self.request(|reply| Command::Learn(corrections, force_save, reply))
            .await
    }
    pub async fn shutdown(&self) -> io::Result<()> {
        if let Some(task) = self.owner.task.lock().await.take() {
            let _ = self.owner.commands.send(Command::Shutdown);
            tokio::task::spawn_blocking(move || task.join())
                .await
                .map_err(io::Error::other)?
                .map_err(|_| io::Error::other("glossary owner panicked"))?;
        }
        Ok(())
    }
}
fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "glossary owner closed")
}

#[cfg(test)]
mod tests {
    use super::*;
    fn correction() -> Correction {
        Correction {
            wrong: "소버림".into(),
            right: "소버린".into(),
        }
    }

    #[tokio::test]
    async fn settings_projection_keeps_swift_order_and_exact_integer_labels_across_save() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("glossary.json");
        let glossary: Glossary = serde_json::from_str(
            r#"{"enabled":false,"minHits":2,"entries":{
            "big":{"wrong":"big","right":"large","hits":9223372036854775807},
            "\uE000":{"wrong":"\uE000","right":"bmp","hits":2},
            "😀":{"wrong":"😀","right":"supplementary","hits":2},
            "low":{"wrong":"low","right":"once","hits":1}
        }}"#,
        )
        .unwrap();
        let service =
            GlossaryService::new(Store::load(path.clone(), glossary).unwrap(), |_| {}).unwrap();
        let state = service.current().await.unwrap();
        assert!(!path.exists());
        assert_eq!(
            state.active_count, 3,
            "source counts eligibility even when disabled"
        );
        assert_eq!(state.minimum_hits_label, "2");
        assert_eq!(
            state
                .display_entries
                .iter()
                .map(|entry| entry.wrong.as_str())
                .collect::<Vec<_>>(),
            vec!["big", "\u{E000}", "😀", "low"]
        );
        let ipc = serde_json::to_value(&state).unwrap();
        assert_eq!(ipc["displayEntries"][0]["hitsLabel"], "9223372036854775807");
        assert!(!state.display_entries[3].active);
        service
            .settings(SettingsCommand::Enabled(true))
            .await
            .unwrap();
        let persisted: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert!(
            persisted.get("displayEntries").is_none(),
            "presentation fields never enter storage"
        );
        assert_eq!(persisted["entries"]["big"]["hits"].as_i64(), Some(i64::MAX));
        let removed = service
            .settings(SettingsCommand::Forget("😀".into()))
            .await
            .unwrap();
        assert_eq!(removed.display_entries.len(), 3);
        assert_eq!(removed.active_count, 2);
        service.shutdown().await.unwrap();
        let reopened =
            GlossaryService::new(Store::load(path, Glossary::default()).unwrap(), |_| {}).unwrap();
        let state = reopened.current().await.unwrap();
        assert_eq!(state.display_entries[0].hits_label, "9223372036854775807");
        assert_eq!(state.display_entries[1].wrong, "\u{E000}");
        reopened.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn learning_is_durable_while_disabled_and_survives_canceled_replies_and_relaunch() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("glossary.json");
        let mut fallback = Glossary::default();
        fallback.learn("소버림", "소버린").unwrap();
        let check_path = path.clone();
        let service =
            GlossaryService::new(Store::load(path.clone(), fallback).unwrap(), move |state| {
                assert_eq!(
                    Store::load(check_path.clone(), Glossary::default())
                        .unwrap()
                        .value(),
                    &state.glossary
                );
            })
            .unwrap();
        assert!(!path.exists());
        let (reply, receive) = oneshot::channel();
        drop(receive);
        service
            .owner
            .commands
            .send(Command::Learn(vec![correction()], false, reply))
            .unwrap();
        assert!(!service.current().await.unwrap().glossary.enabled);
        assert_eq!(service.snapshot().glossary.exact("소버림").unwrap().hits, 2);
        service
            .settings(SettingsCommand::Enabled(true))
            .await
            .unwrap();
        let mut tasks = Vec::new();
        for _ in 0..8 {
            let worker = service.clone();
            tasks.push(tokio::spawn(async move {
                worker.learn(vec![correction()], false).await.unwrap();
            }));
        }
        for task in tasks {
            task.await.unwrap();
        }
        service.shutdown().await.unwrap();
        let restored = Store::load(path, Glossary::default()).unwrap();
        assert!(restored.value().enabled);
        assert_eq!(restored.value().exact("소버림").unwrap().hits, 10);
        assert!(service.current().await.is_err());
    }

    #[tokio::test]
    async fn failed_save_and_invalid_settings_preserve_last_snapshot_and_original_bytes() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("glossary.json");
        let service = GlossaryService::new(
            Store::load(path.clone(), Glossary::default()).unwrap(),
            |_| {},
        )
        .unwrap();
        assert!(
            service
                .settings(SettingsCommand::MinimumHits(0))
                .await
                .is_err()
        );
        assert!(!path.exists());
        fs::create_dir(&path).unwrap();
        assert!(service.learn(vec![correction()], false).await.is_err());
        assert_eq!(service.snapshot().revision, 0);
        assert_eq!(service.snapshot().glossary.entries().count(), 0);
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
        fs::remove_dir(&path).unwrap();
        service.learn(vec![correction()], false).await.unwrap();
        let saved = fs::read(&path).unwrap();
        assert!(
            service
                .settings(SettingsCommand::MinimumHits(6))
                .await
                .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), saved);
        service.shutdown().await.unwrap();
        fs::write(&path, b"malformed original").unwrap();
        assert!(Store::load(path.clone(), Glossary::default()).is_err());
        assert_eq!(fs::read(path).unwrap(), b"malformed original");
    }
}
