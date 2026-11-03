//! Owned model transfer, full verification and atomic publication.
//! URLs/paths come from the native pinned manifest, never WebView arguments.
use crate::model_assets;
use madi_core::assets::RemoteAsset;
pub use madi_core::model_setup::ModelDownloadState as DownloadState;
use std::{
    fs::{File, OpenOptions},
    io,
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::{io::AsyncWriteExt, sync::watch, task::JoinHandle};

#[derive(Clone)]
pub struct Downloader {
    client: reqwest::Client,
}

impl Downloader {
    #[cfg(test)]
    pub(crate) fn fixture_client() -> Self {
        Self {
            client: reqwest::Client::builder()
                .no_proxy()
                .read_timeout(Duration::from_secs(3))
                .build()
                .unwrap(),
        }
    }

    #[cfg(test)]
    pub(crate) fn fixture_start(
        &self,
        asset: RemoteAsset,
        support: PathBuf,
        url: String,
    ) -> DownloadTask {
        self.start_url(asset, support, url)
    }

    pub fn new() -> Result<Self, reqwest::Error> {
        Ok(Self {
            client: reqwest::Client::builder()
                .tls_backend_native()
                .https_only(true)
                .connect_timeout(Duration::from_secs(60))
                .read_timeout(Duration::from_secs(60))
                .timeout(Duration::from_secs(7 * 24 * 60 * 60))
                .build()?,
        })
    }

    /// No I/O occurs until an explicit native start. The persistent lock is per
    /// asset and shared across app instances; stale partial bytes are restarted
    /// only after this process has acquired the lock.
    pub fn start(&self, asset: RemoteAsset, support: PathBuf) -> DownloadTask {
        self.start_url(asset, support, asset.url.to_owned())
    }

    fn start_url(&self, asset: RemoteAsset, support: PathBuf, url: String) -> DownloadTask {
        let (cancel, cancelled) = watch::channel(false);
        let (state, receiver) = watch::channel(DownloadState::Downloading(0.0));
        let client = self.client.clone();
        let worker = tokio::spawn(async move {
            let result = execute(client, url, asset, support, cancelled, &state).await;
            let final_state = match result {
                Ok(state) => state,
                Err(error) => DownloadState::Failed(error),
            };
            state.send_replace(final_state.clone());
            final_state
        });
        DownloadTask {
            cancel,
            receiver,
            worker: Some(worker),
        }
    }
}

pub struct DownloadTask {
    cancel: watch::Sender<bool>,
    receiver: watch::Receiver<DownloadState>,
    worker: Option<JoinHandle<DownloadState>>,
}

impl DownloadTask {
    pub fn state(&self) -> DownloadState {
        self.receiver.borrow().clone()
    }
    pub fn is_finished(&self) -> bool {
        self.worker.as_ref().is_none_or(JoinHandle::is_finished)
    }
    /// A coalescing UI stream: the final state is published only after cleanup.
    pub fn subscribe(&self) -> watch::Receiver<DownloadState> {
        self.receiver.clone()
    }
    pub fn request_cancel(&self) {
        self.cancel.send_replace(true);
    }
    /// Cancellation of this wait retains the worker handle for a later wait.
    pub async fn wait(&mut self) -> io::Result<DownloadState> {
        if let Some(worker) = self.worker.as_mut() {
            let result = worker.await.map_err(io::Error::other);
            self.worker.take();
            result
        } else {
            Ok(self.state())
        }
    }
    pub async fn cancel_and_wait(&mut self) -> io::Result<DownloadState> {
        self.request_cancel();
        self.wait().await
    }
}

impl Drop for DownloadTask {
    fn drop(&mut self) {
        // Keep the worker alive to flush/close files and release its lock. The
        // app must await cancel_and_wait before shutting its Tokio runtime down.
        self.request_cancel();
    }
}

async fn cancellation(cancel: &mut watch::Receiver<bool>) {
    if !*cancel.borrow() {
        let _ = cancel.changed().await;
    }
}

async fn execute(
    client: reqwest::Client,
    url: String,
    asset: RemoteAsset,
    support: PathBuf,
    mut cancel: watch::Receiver<bool>,
    states: &watch::Sender<DownloadState>,
) -> Result<DownloadState, String> {
    let stage =
        Stage::open(&support, asset.name).map_err(|error| format!("install failed: {error}"))?;
    let response = tokio::select! {
        biased;
        _ = cancellation(&mut cancel) => None,
        response = client.get(url).send() => Some(response),
    };
    let result = match response {
        None => Ok(false),
        Some(Err(error)) => Err(error.to_string()),
        Some(Ok(mut response)) => {
            // URLSession's original downloaders validate the received file even
            // for HTTP error bodies. Preserve that flow; only pinned bytes can
            // pass verification and become an installed model.
            let total = response
                .content_length()
                .filter(|total| *total > 0)
                .unwrap_or(asset.size_bytes);
            let mut writer = tokio::fs::File::from_std(
                stage
                    .file
                    .as_ref()
                    .expect("open stage")
                    .try_clone()
                    .map_err(|error| error.to_string())?,
            );
            let mut written = 0u64;
            let transfer = async {
                loop {
                    let chunk = tokio::select! {
                        biased;
                        _ = cancellation(&mut cancel) => return Ok(false),
                        chunk = response.chunk() => chunk.map_err(|error| error.to_string())?,
                    };
                    let Some(chunk) = chunk else { break };
                    written = written
                        .checked_add(chunk.len() as u64)
                        .ok_or_else(|| "SHA-256 mismatch — re-download".to_owned())?;
                    if written > asset.size_bytes {
                        return Err("SHA-256 mismatch — re-download".to_owned());
                    }
                    writer
                        .write_all(&chunk)
                        .await
                        .map_err(|error| format!("move failed: {error}"))?;
                    states.send_replace(DownloadState::Downloading(
                        (written as f64 / total.max(1) as f64).min(1.0),
                    ));
                }
                Ok(true)
            }
            .await;
            // Flush is deliberately not cancelled: a pending Tokio file write
            // must finish before dropping/removing the staging file on Windows.
            let flushed = writer.flush().await;
            drop(writer);
            match (transfer, flushed) {
                (Err(error), _) => Err(error),
                (_, Err(error)) => Err(format!("move failed: {error}")),
                (Ok(value), Ok(())) => Ok(value),
            }
        }
    };
    let downloaded = match result {
        Ok(value) => value,
        Err(error) => {
            stage
                .cleanup()
                .map_err(|cleanup| format!("{error}; cleanup failed: {cleanup}"))?;
            return Err(error);
        }
    };
    if !downloaded || *cancel.borrow() {
        stage
            .cleanup()
            .map_err(|error| format!("install failed: {error}"))?;
        return Ok(DownloadState::Cancelled);
    }
    states.send_replace(DownloadState::Verifying);
    let (stage, valid) = tokio::task::spawn_blocking(move || {
        let valid = model_assets::file_is_valid(&stage.path, asset.size_bytes, asset.sha256);
        (stage, valid)
    })
    .await
    .map_err(|error| format!("verification failed: {error}"))?;
    if *cancel.borrow() {
        stage
            .cleanup()
            .map_err(|error| format!("install failed: {error}"))?;
        return Ok(DownloadState::Cancelled);
    }
    if !valid {
        stage
            .cleanup()
            .map_err(|error| format!("install failed: {error}"))?;
        return Err("SHA-256 mismatch — re-download".into());
    }
    stage
        .publish()
        .map_err(|error| format!("install failed: {error}"))?;
    Ok(DownloadState::Ready)
}

/// Deterministic app-owned staging supports restart after a hard interruption.
/// The lock file remains on disk; unlinking it would let another process lock a
/// different inode while an older writer still owns the original lock.
struct Stage {
    path: PathBuf,
    destination: PathBuf,
    file: Option<File>,
    _lock: File,
}

impl Stage {
    fn open(support: &Path, name: &str) -> io::Result<Self> {
        if Path::new(name).file_name().is_none_or(|file| file != name) || name.contains(['/', '\\'])
        {
            return Err(io::Error::other("invalid model filename"));
        }
        std::fs::create_dir_all(support)?;
        let support = support.canonicalize()?;
        let folder = support.join(".madi-downloads");
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        match builder.create(&folder) {
            Ok(()) => (),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
            Err(error) => return Err(error),
        }
        if !std::fs::symlink_metadata(&folder)?.is_dir() || folder.canonicalize()? != folder {
            return Err(io::Error::other("invalid model staging directory"));
        }
        let lock = regular_writer(&folder.join(format!("{name}.lock")))?;
        lock.try_lock().map_err(|error| {
            io::Error::other(format!(
                "model download already active or lock unavailable: {error}"
            ))
        })?;
        let path = folder.join(format!("{name}.partial"));
        let file = regular_writer(&path)?;
        file.set_len(0)?;
        Ok(Self {
            path,
            destination: support.join(name),
            file: Some(file),
            _lock: lock,
        })
    }
    fn cleanup(mut self) -> io::Result<()> {
        self.file.take();
        match std::fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        }
    }
    fn publish(mut self) -> io::Result<()> {
        // Keep an existing model intact on every transfer/verification failure.
        // Never follow an unexpected destination link or replace a directory.
        match std::fs::symlink_metadata(&self.destination) {
            Ok(metadata) if !metadata.is_file() => {
                return Err(io::Error::other("model destination is not a regular file"));
            }
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
            _ => (),
        }
        self.file.take();
        std::fs::rename(&self.path, &self.destination)
    }
}

impl Drop for Stage {
    fn drop(&mut self) {
        self.file.take();
        let _ = std::fs::remove_file(&self.path);
    }
}

fn regular_writer(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .mode(0o600);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(io::Error::other("model staging path is a reparse point"));
        }
    }
    if !metadata.is_file() {
        return Err(io::Error::other("model staging path is not a regular file"));
    }
    Ok(file)
}

#[cfg(test)]
mod tests;
