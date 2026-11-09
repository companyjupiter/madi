//! Serialized workspace settings and generation-bound, read-only scans.
use crate::{
    workspace_preferences::{Preferences, Store},
    workspace_scan::{self, Node},
};
use madi_core::workspace::Stats;
use serde::{Deserialize, Serialize};
use std::{
    io,
    path::{Path, PathBuf},
    sync::{Arc, Mutex as StdMutex},
};
use tokio::{
    sync::{Mutex, mpsc, oneshot, watch},
    task::JoinHandle,
};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub revision: u64,
    pub generation: u64,
    pub root_revision: u64,
    pub loading: bool,
    pub auto_save: bool,
    pub folder: PathBuf,
    pub folder_name: String,
    pub entries: Vec<Entry>,
    pub stats: Stats,
    pub total_words_label: String,
    pub average_speakers_label: String,
    pub stats_loading: bool,
    pub error: Option<String>,
    #[serde(skip)]
    pub editor_settings: madi_core::transcript::export::EditorSettings,
}
#[derive(Deserialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum Action {
    AutoSave(bool),
    ShowStats(bool),
}
#[derive(Default)]
pub struct Change {
    pub auto_save: Option<bool>,
    pub folder: Option<PathBuf>,
}
type Reply = oneshot::Sender<io::Result<Snapshot>>;
enum Command {
    Change {
        root_revision: Option<u64>,
        change: Change,
        reply: Reply,
    },
    Scanned {
        generation: u64,
        result: io::Result<Vec<Node>>,
    },
    Stats {
        generation: u64,
        token: u64,
        value: Stats,
    },
    ShowStats(bool),
    Reload,
    Saved {
        path: PathBuf,
        session: u64,
    },
    Shutdown,
}
type Scan = Arc<dyn Fn(&Path) -> io::Result<Vec<Node>> + Send + Sync>;
type Statistics = Arc<dyn Fn(&[Node]) -> Stats + Send + Sync>;
struct Owner {
    commands: mpsc::UnboundedSender<Command>,
    snapshot: watch::Receiver<Snapshot>,
    task: Mutex<Option<JoinHandle<()>>>,
}
impl Drop for Owner {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Shutdown);
    }
}
#[derive(Clone)]
pub struct Workspace {
    owner: Arc<Owner>,
}
impl Workspace {
    pub fn new(store: Store, changed: impl Fn(Snapshot) + Send + Sync + 'static) -> Self {
        Self::with_backend(
            store,
            changed,
            Arc::new(workspace_scan::scan),
            Arc::new(|nodes| {
                #[cfg(target_os = "macos")]
                {
                    workspace_scan::macos::statistics(
                        nodes,
                        std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_secs_f64(),
                    )
                }
                #[cfg(not(target_os = "macos"))]
                {
                    let _ = nodes;
                    Stats::default()
                }
            }),
        )
    }
    fn with_backend(
        store: Store,
        changed: impl Fn(Snapshot) + Send + Sync + 'static,
        scan: Scan,
        statistics: Statistics,
    ) -> Self {
        let value = store.value();
        let state = Snapshot {
            revision: 0,
            generation: 1,
            root_revision: 0,
            loading: true,
            auto_save: value.auto_save,
            folder: value.folder.clone(),
            folder_name: folder_name(&value.folder),
            entries: Vec::new(),
            stats: Stats::default(),
            total_words_label: "0".into(),
            average_speakers_label: "0.0".into(),
            stats_loading: false,
            error: None,
            editor_settings: value.editor_settings.clone(),
        };
        let (commands, input) = mpsc::unbounded_channel();
        let (output, snapshot) = watch::channel(state.clone());
        let worker = Worker {
            store: Arc::new(StdMutex::new(store)),
            state,
            nodes: Vec::new(),
            commands: commands.clone(),
            input,
            output,
            changed: Box::new(changed),
            scan,
            statistics,
            stats_wanted: false,
            stats_token: 0,
            last_saved: None,
        };
        let task = tokio::spawn(worker.run());
        Self {
            owner: Arc::new(Owner {
                commands,
                snapshot,
                task: Mutex::new(Some(task)),
            }),
        }
    }
    pub fn snapshot(&self) -> Snapshot {
        self.owner.snapshot.borrow().clone()
    }
    pub fn resolve(&self, generation: u64, id: &str) -> Option<PathBuf> {
        let state = self.owner.snapshot.borrow();
        if state.generation != generation || state.loading {
            return None;
        }
        state
            .entries
            .iter()
            .find(|entry| entry.id == id)
            .map(|entry| entry.path.clone())
    }
    pub async fn change(&self, root_revision: Option<u64>, change: Change) -> io::Result<Snapshot> {
        let (reply, result) = oneshot::channel();
        self.owner
            .commands
            .send(Command::Change {
                root_revision,
                change,
                reply,
            })
            .map_err(|_| closed())?;
        result.await.map_err(|_| closed())?
    }
    pub fn show_stats(&self, visible: bool) -> io::Result<()> {
        self.send(Command::ShowStats(visible))
    }
    pub fn reload(&self) -> io::Result<()> {
        self.send(Command::Reload)
    }
    pub fn note_saved(&self, path: &Path, session: u64) -> io::Result<()> {
        self.send(Command::Saved {
            path: path.to_owned(),
            session,
        })
    }
    fn send(&self, command: Command) -> io::Result<()> {
        self.owner.commands.send(command).map_err(|_| closed())
    }
    pub async fn shutdown(&self) -> io::Result<()> {
        let _ = self.owner.commands.send(Command::Shutdown);
        let mut task = self.owner.task.lock().await;
        let result = match task.as_mut() {
            Some(task) => task.await,
            None => return Ok(()),
        };
        task.take();
        result.map_err(io::Error::other)
    }
}
pub fn total_words_label(value: usize) -> String {
    #[cfg(target_os = "macos")]
    {
        objc2::rc::autoreleasepool(|_| {
            use objc2_foundation::{NSNumber, NSNumberFormatter, NSNumberFormatterStyle};
            let formatter = NSNumberFormatter::new();
            formatter.setNumberStyle(NSNumberFormatterStyle::DecimalStyle);
            formatter
                .stringFromNumber(&NSNumber::new_u64(value as u64))
                .map(|text| text.to_string())
                .unwrap_or_else(|| value.to_string())
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        value.to_string()
    }
}
fn folder_name(folder: &Path) -> String {
    #[cfg(target_os = "macos")]
    {
        objc2::rc::autoreleasepool(|_| crate::media_file::summary(folder).name)
    }
    #[cfg(not(target_os = "macos"))]
    {
        folder
            .file_name()
            .unwrap_or(folder.as_os_str())
            .to_string_lossy()
            .into_owned()
    }
}
fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "workspace closed")
}
struct Worker {
    store: Arc<StdMutex<Store>>,
    state: Snapshot,
    nodes: Vec<Node>,
    commands: mpsc::UnboundedSender<Command>,
    input: mpsc::UnboundedReceiver<Command>,
    output: watch::Sender<Snapshot>,
    changed: Box<dyn Fn(Snapshot) + Send + Sync>,
    scan: Scan,
    statistics: Statistics,
    stats_wanted: bool,
    stats_token: u64,
    last_saved: Option<(u64, PathBuf)>,
}
impl Worker {
    fn publish(&mut self) {
        self.state.revision = self.state.revision.wrapping_add(1);
        self.output.send_replace(self.state.clone());
        (self.changed)(self.state.clone());
    }
    fn scan(&self) {
        let folder = self.state.folder.clone();
        let generation = self.state.generation;
        let scan = self.scan.clone();
        let sender = self.commands.clone();
        // Read-only work may outlive a superseded request. It cannot publish
        // without passing the worker's generation check, or write any file.
        tokio::task::spawn_blocking(move || {
            let result = scan(&folder);
            let _ = sender.send(Command::Scanned { generation, result });
        });
    }
    fn reload(&mut self) {
        self.state.generation = self.state.generation.wrapping_add(1);
        self.state.loading = true;
        self.scan();
        self.publish();
    }
    fn stats(&mut self) {
        if !self.stats_wanted || self.state.loading {
            return;
        }
        self.stats_token = self.stats_token.wrapping_add(1);
        let token = self.stats_token;
        let generation = self.state.generation;
        let nodes = self.nodes.clone();
        let statistics = self.statistics.clone();
        let sender = self.commands.clone();
        self.state.stats_loading = true;
        tokio::task::spawn_blocking(move || {
            let value = statistics(&nodes);
            let _ = sender.send(Command::Stats {
                generation,
                token,
                value,
            });
        });
    }
    async fn change(&mut self, root_revision: Option<u64>, change: Change) -> io::Result<Snapshot> {
        if root_revision.is_some_and(|revision| revision != self.state.root_revision) {
            return Ok(self.state.clone());
        }
        // Swift WorkspaceTree.setRoot reloads even when the selected URL is
        // unchanged; reselecting a folder also refreshes external file changes.
        let folder_selected = change.folder.is_some();
        let store = self.store.clone();
        let value = tokio::task::spawn_blocking(move || {
            let mut store = store
                .lock()
                .map_err(|_| io::Error::other("workspace preferences unavailable"))?;
            let mut value = store.value().clone();
            if let Some(enabled) = change.auto_save {
                value.auto_save = enabled;
            }
            if let Some(folder) = change.folder {
                value.folder = folder;
            }
            store.save(value.clone())?;
            Ok::<Preferences, io::Error>(value)
        })
        .await
        .map_err(io::Error::other)??;
        self.state.auto_save = value.auto_save;
        self.state.error = None;
        if folder_selected {
            self.state.folder = value.folder;
            self.state.folder_name = folder_name(&self.state.folder);
            self.state.root_revision = self.state.root_revision.wrapping_add(1);
            self.reload();
        } else {
            self.publish();
        }
        Ok(self.state.clone())
    }
    async fn run(mut self) {
        self.scan();
        while let Some(command) = self.input.recv().await {
            match command {
                Command::Change {
                    root_revision,
                    change,
                    reply,
                } => {
                    let result = self.change(root_revision, change).await;
                    let _ = reply.send(result);
                }
                Command::Reload => self.reload(),
                Command::Saved { path, session } => {
                    let checkpoint = (session, path);
                    if self.last_saved.as_ref() != Some(&checkpoint) {
                        self.last_saved = Some(checkpoint);
                        self.reload();
                    } else if self.stats_wanted {
                        self.stats();
                        self.publish();
                    }
                }
                Command::Scanned { generation, result } => {
                    if generation != self.state.generation {
                        continue;
                    }
                    self.state.loading = false;
                    match result {
                        Ok(nodes) => {
                            self.state.entries = workspace_scan::recent(&nodes)
                                .iter()
                                .enumerate()
                                .map(|(index, node)| Entry {
                                    id: index.to_string(),
                                    name: node.name.clone(),
                                    path: node.path.clone(),
                                })
                                .collect();
                            self.nodes = nodes;
                            self.state.error = None;
                        }
                        Err(error) => {
                            self.nodes.clear();
                            self.state.entries.clear();
                            self.state.error = Some(error.to_string());
                        }
                    }
                    self.stats();
                    self.publish();
                }
                Command::Stats {
                    generation,
                    token,
                    value,
                } => {
                    if generation != self.state.generation
                        || token != self.stats_token
                        || !self.stats_wanted
                    {
                        continue;
                    }
                    self.state.total_words_label = total_words_label(value.total_words);
                    self.state.average_speakers_label = format!("{:.1}", value.avg_speakers);
                    self.state.stats = value;
                    self.state.stats_loading = false;
                    self.publish();
                }
                Command::ShowStats(visible) => {
                    self.stats_wanted = visible;
                    if visible {
                        self.stats();
                    } else {
                        self.state.stats_loading = false;
                    }
                    self.publish();
                }
                Command::Shutdown => return,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    async fn ready(workspace: &Workspace) -> Snapshot {
        tokio::time::timeout(Duration::from_secs(5), async {
            let mut watch = workspace.owner.snapshot.clone();
            loop {
                let state = watch.borrow_and_update().clone();
                if !state.loading {
                    return state;
                }
                watch.changed().await.unwrap();
            }
        })
        .await
        .unwrap()
    }
    fn node(folder: &Path) -> Node {
        Node {
            path: folder.join("meeting.md"),
            name: "meeting.md".into(),
            is_dir: false,
            children: None,
            is_transcript: true,
            is_summary: false,
            modified: Some(1.0),
        }
    }
    #[tokio::test]
    async fn superseded_scan_cannot_replace_root_or_authorize_stale_rows() {
        let root = tempfile::tempdir().unwrap();
        let old = root.path().join("old");
        let new = root.path().join("new");
        let (started, received) = oneshot::channel();
        let started = Arc::new(StdMutex::new(Some(started)));
        let (release, blocked) = std::sync::mpsc::channel();
        let blocked = Arc::new(StdMutex::new(blocked));
        let old_scan = old.clone();
        let scan = Arc::new(move |folder: &Path| {
            if folder == old_scan {
                if let Some(started) = started.lock().unwrap().take() {
                    let _ = started.send(());
                }
                blocked
                    .lock()
                    .unwrap()
                    .recv_timeout(Duration::from_secs(5))
                    .unwrap();
            }
            Ok(vec![node(folder)])
        });
        let prefs = Preferences::from_legacy(Default::default(), old);
        let workspace = Workspace::with_backend(
            Store::load(root.path().join("prefs.json"), prefs).unwrap(),
            |_| {},
            scan,
            Arc::new(|_| Stats::default()),
        );
        received.await.unwrap();
        let first = workspace.snapshot();
        assert!(workspace.resolve(first.generation, "0").is_none());
        workspace
            .change(
                Some(first.root_revision),
                Change {
                    folder: Some(new.clone()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        let current = ready(&workspace).await;
        assert_eq!(
            workspace.resolve(current.generation, "0"),
            Some(new.join("meeting.md"))
        );
        assert!(workspace.resolve(first.generation, "0").is_none());
        release.send(()).unwrap();
        workspace
            .owner
            .commands
            .send(Command::Scanned {
                generation: first.generation,
                result: Ok(vec![node(&first.folder)]),
            })
            .unwrap();
        // The command after an obsolete completion observes the unchanged root.
        let state = workspace
            .change(
                Some(first.root_revision),
                Change {
                    folder: Some(root.path().join("stale picker")),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(state.folder, new);
        assert_eq!(state.root_revision, current.root_revision);
        workspace.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn settings_persist_and_same_checkpoint_does_not_rescan() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("workspace");
        let path = root.path().join("prefs.json");
        let prefs = Preferences::from_legacy(Default::default(), folder.clone());
        let workspace = Workspace::with_backend(
            Store::load(path.clone(), prefs.clone()).unwrap(),
            |_| {},
            Arc::new(|folder| Ok(vec![node(folder)])),
            Arc::new(|_| Stats::default()),
        );
        let first = ready(&workspace).await;
        let disabled = workspace
            .change(
                None,
                Change {
                    auto_save: Some(false),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(disabled.generation, first.generation);
        assert!(!disabled.auto_save);
        workspace.note_saved(&folder.join("meeting.md"), 1).unwrap();
        let after = workspace.change(None, Change::default()).await.unwrap();
        assert_ne!(after.generation, first.generation);
        workspace.note_saved(&folder.join("meeting.md"), 1).unwrap();
        let unchanged = workspace.change(None, Change::default()).await.unwrap();
        assert_eq!(unchanged.generation, after.generation);
        // If the old archive was removed externally, a new session can allocate
        // the same filename. Its first checkpoint must still refresh the list.
        workspace.note_saved(&folder.join("meeting.md"), 2).unwrap();
        let next_session = workspace.change(None, Change::default()).await.unwrap();
        assert_ne!(next_session.generation, unchanged.generation);
        workspace.shutdown().await.unwrap();
        assert!(!Store::load(path, prefs).unwrap().value().auto_save);
    }
    #[tokio::test]
    async fn reselecting_the_same_folder_refreshes_files_and_invalidates_old_rows() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("workspace");
        std::fs::create_dir(&folder).unwrap();
        std::fs::write(folder.join("meeting.md"), "existing").unwrap();
        let scan = Arc::new(|folder: &Path| {
            let mut nodes = vec![node(folder)];
            let added = folder.join("new.md");
            if added.exists() {
                let mut extra = node(folder);
                extra.name = "new.md".into();
                extra.path = added;
                nodes.push(extra);
            }
            Ok(nodes)
        });
        let prefs = Preferences::from_legacy(Default::default(), folder.clone());
        let workspace = Workspace::with_backend(
            Store::load(root.path().join("prefs.json"), prefs).unwrap(),
            |_| {},
            scan,
            Arc::new(|_| Stats::default()),
        );
        let first = ready(&workspace).await;
        assert_eq!(first.entries.len(), 1);
        std::fs::write(folder.join("new.md"), "externally added").unwrap();
        workspace
            .change(
                Some(first.root_revision),
                Change {
                    folder: Some(folder),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        let refreshed = ready(&workspace).await;
        assert_eq!(refreshed.entries.len(), 2);
        assert_ne!(refreshed.generation, first.generation);
        assert!(
            workspace
                .resolve(first.generation, &first.entries[0].id)
                .is_none()
        );
        assert!(
            workspace
                .resolve(refreshed.generation, &refreshed.entries[1].id)
                .is_some()
        );
        workspace.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn late_statistics_cannot_replace_new_folder_or_hidden_tab() {
        let root = tempfile::tempdir().unwrap();
        let old = root.path().join("old");
        let new = root.path().join("new");
        let (started, received) = oneshot::channel();
        let started = Arc::new(StdMutex::new(Some(started)));
        let (release, blocked) = std::sync::mpsc::channel();
        let blocked = Arc::new(StdMutex::new(blocked));
        let old_stats = old.clone();
        let statistics = Arc::new(move |nodes: &[Node]| {
            let is_old = nodes[0].path.parent() == Some(old_stats.as_path());
            if is_old {
                if let Some(started) = started.lock().unwrap().take() {
                    let _ = started.send(());
                }
                blocked
                    .lock()
                    .unwrap()
                    .recv_timeout(Duration::from_secs(5))
                    .unwrap();
            }
            Stats {
                meeting_count: if is_old { 1 } else { 2 },
                ..Default::default()
            }
        });
        let prefs = Preferences::from_legacy(Default::default(), old);
        let workspace = Workspace::with_backend(
            Store::load(root.path().join("prefs.json"), prefs).unwrap(),
            |_| {},
            Arc::new(|folder| Ok(vec![node(folder)])),
            statistics,
        );
        let first = ready(&workspace).await;
        workspace.show_stats(true).unwrap();
        received.await.unwrap();
        workspace
            .change(
                None,
                Change {
                    folder: Some(new),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            let mut watch = workspace.owner.snapshot.clone();
            loop {
                let state = watch.borrow_and_update().clone();
                if state.stats.meeting_count == 2 {
                    break;
                }
                watch.changed().await.unwrap();
            }
        })
        .await
        .unwrap();
        release.send(()).unwrap();
        // Deliver the stale result deterministically before a settings barrier.
        workspace
            .send(Command::Stats {
                generation: first.generation,
                token: 1,
                value: Stats {
                    meeting_count: 99,
                    ..Default::default()
                },
            })
            .unwrap();
        let after = workspace.change(None, Change::default()).await.unwrap();
        assert_eq!(after.stats.meeting_count, 2);
        workspace.show_stats(false).unwrap();
        workspace
            .send(Command::Stats {
                generation: after.generation,
                token: 2,
                value: Stats {
                    meeting_count: 99,
                    ..Default::default()
                },
            })
            .unwrap();
        let hidden = workspace.change(None, Change::default()).await.unwrap();
        assert_eq!(hidden.stats.meeting_count, 2);
        assert!(!hidden.stats_loading);
        workspace.shutdown().await.unwrap();
    }
}
