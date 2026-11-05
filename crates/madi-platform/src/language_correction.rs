//! Owned line-sized audio and bounded forced-language ASR. No renderer paths.
use crate::{asr_config::Resources, capture_pipeline::OwnedWav};
use madi_core::reconcile::audio;
use std::{
    io::{self, Write},
    path::Path,
    process::Stdio,
    time::Duration,
};
use tempfile::NamedTempFile;
use tokio::{io::AsyncReadExt, process::Command, sync::oneshot, task::JoinHandle};

pub struct Configuration {
    pub resources: Resources,
    pub language_token: i64,
    deadline: Duration,
    #[cfg(test)]
    arguments: Vec<std::ffi::OsString>,
}
impl Configuration {
    pub fn new(resources: Resources, language_token: i64) -> Self {
        Self {
            resources,
            language_token,
            deadline: Duration::from_secs(45),
            #[cfg(test)]
            arguments: Vec::new(),
        }
    }
}
struct Clip {
    // Remove the new clip before releasing the source directory lease.
    file: NamedTempFile,
    _source: OwnedWav,
}
impl Clip {
    fn crop(source: OwnedWav, start: f64, end: f64) -> io::Result<Self> {
        let bytes = audio::crop(&std::fs::read(source.path())?, start, end, 0.2)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{e:?}")))?;
        let mut file = tempfile::Builder::new()
            .prefix("madi-correction-")
            .suffix(".wav")
            .tempfile_in(source.directory())?;
        file.write_all(&bytes)?;
        file.flush()?;
        Ok(Self {
            file,
            _source: source,
        })
    }
    fn path(&self) -> &Path {
        self.file.path()
    }
}

pub struct CorrectionTask {
    cancel: Option<oneshot::Sender<()>>,
    task: Option<JoinHandle<io::Result<Option<String>>>>,
}
impl CorrectionTask {
    pub fn start(
        config: Configuration,
        source: OwnedWav,
        start: f64,
        end: f64,
    ) -> io::Result<Self> {
        tokio::runtime::Handle::try_current().map_err(io::Error::other)?;
        let (cancel, mut cancelled) = oneshot::channel();
        let task = tokio::spawn(async move {
            // Even cancellation joins the blocking crop before retiring its
            // directory. Dropping a JoinHandle would detach that ownership.
            let clip = tokio::task::spawn_blocking(move || Clip::crop(source, start, end))
                .await
                .map_err(io::Error::other)??;
            if !matches!(
                cancelled.try_recv(),
                Err(oneshot::error::TryRecvError::Empty)
            ) {
                return Ok(None);
            }
            let mut command = Command::new(&config.resources.executable);
            #[cfg(test)]
            command.args(&config.arguments);
            command
                .arg(&config.resources.model)
                .arg(clip.path())
                .arg(&config.resources.bpe)
                .current_dir(&config.resources.assets)
                .env("DIAR", "0")
                .env("AUDIO_CTX", "auto")
                .env("WHISPER_LANG_ID", config.language_token.to_string())
                .env_remove("STREAM")
                .env_remove("APP_FILE")
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .kill_on_drop(true);
            #[cfg(windows)]
            command.creation_flags(0x08000000);
            let mut child = command.spawn()?;
            let mut stdout = child
                .stdout
                .take()
                .ok_or_else(|| io::Error::other("missing correction stdout"))?;
            let mut bytes = Vec::new();
            let completed = tokio::select! {
                biased;
                _ = &mut cancelled => None,
                _ = tokio::time::sleep(config.deadline) => None,
                result = async { tokio::try_join!(child.wait(), stdout.read_to_end(&mut bytes)) } => Some(result),
            };
            let result = match completed {
                Some(Ok((status, _))) if status.success() => {
                    // Swift String(data:encoding:) rejects invalid UTF-8.
                    Ok(std::str::from_utf8(&bytes)
                        .ok()
                        .and_then(audio::parse_transcription))
                }
                Some(Ok(_)) => Ok(None),
                other => {
                    if child.try_wait()?.is_none() {
                        let _ = crate::engine_process::request_termination(&mut child);
                        match tokio::time::timeout(Duration::from_secs(2), child.wait()).await {
                            Ok(status) => {
                                status?;
                            }
                            Err(_) => {
                                child.kill().await?;
                            }
                        }
                    }
                    match other {
                        Some(Err(error)) => Err(error),
                        _ => Ok(None),
                    }
                }
            };
            // Keep both clip and original audio leases until child wait and
            // output draining finish, including timeout/cancellation paths.
            drop(stdout);
            drop(clip);
            result
        });
        Ok(Self {
            cancel: Some(cancel),
            task: Some(task),
        })
    }
    pub fn cancel(&mut self) {
        if let Some(cancel) = self.cancel.take() {
            let _ = cancel.send(());
        }
    }
    pub async fn wait(&mut self) -> io::Result<Option<String>> {
        let result = self
            .task
            .as_mut()
            .ok_or_else(|| io::Error::other("correction result already consumed"))?
            .await;
        self.task.take();
        self.cancel.take();
        result.map_err(io::Error::other)?
    }
}
impl Drop for CorrectionTask {
    fn drop(&mut self) {
        self.cancel();
    }
}

#[cfg(test)]
mod tests;
