//! Owned decoded WAVs. There is deliberately no constructor from an arbitrary
//! path and no API that deletes an original selected file.
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    fmt, io,
    path::{Path, PathBuf},
    process::Stdio,
};
use tempfile::TempDir;
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    process::Command,
    sync::oneshot,
    task::JoinHandle,
};

#[derive(Debug)]
pub enum DecodeError {
    Cancelled,
    Io(io::Error),
    Native {
        domain: String,
        code: i64,
        reason: Option<String>,
        message: String,
    },
    InvalidOutput(String),
}
impl From<io::Error> for DecodeError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}
impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for DecodeError {}

pub struct PreparedAudio {
    directory: TempDir,
    path: PathBuf,
}
impl PreparedAudio {
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn dispose(self) -> io::Result<()> {
        self.directory.close()
    }
}

/// Only drops an ownership guard already returned by the decoder. A stale or
/// foreign RemovePreparedFile effect cannot turn into an arbitrary unlink.
#[derive(Default)]
pub struct PreparedRegistry(BTreeMap<PathBuf, PreparedAudio>);
impl PreparedRegistry {
    pub fn insert(&mut self, audio: PreparedAudio) -> PathBuf {
        let path = audio.path.clone();
        self.0.insert(path.clone(), audio);
        path
    }
    pub fn release(&mut self, path: &Path) -> io::Result<bool> {
        match self.0.remove(path) {
            Some(audio) => {
                audio.dispose()?;
                Ok(true)
            }
            None => Ok(false),
        }
    }
}

pub struct DecodeTask {
    cancel: Option<oneshot::Sender<()>>,
    task: Option<JoinHandle<Result<PreparedAudio, DecodeError>>>,
}
impl DecodeTask {
    /// The helper path is supplied by the trusted host (bundled native adapter),
    /// never by frontend IPC. macOS uses the build's AVFoundation helper.
    pub fn start(
        helper: &Path,
        original: &Path,
        scratch_parent: &Path,
    ) -> Result<Self, DecodeError> {
        tokio::runtime::Handle::try_current().map_err(io::Error::other)?;
        let helper = helper.canonicalize()?;
        let original = original.canonicalize()?;
        let directory = tempfile::Builder::new()
            .prefix("madi-import-")
            .tempdir_in(scratch_parent)?;
        let mut command = Command::new(helper);
        command
            .arg(original)
            .arg(directory.path())
            .env("TMPDIR", directory.path())
            .current_dir(directory.path())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        #[cfg(windows)]
        command.creation_flags(0x08000000);
        let mut child = command.spawn()?;
        let mut stdout = child
            .stdout
            .take()
            .ok_or_else(|| io::Error::other("missing decode stdout"))?;
        let mut stderr = child
            .stderr
            .take()
            .ok_or_else(|| io::Error::other("missing decode stderr"))?;
        let (cancel, cancelled) = oneshot::channel();
        let task = tokio::spawn(async move {
            let mut diagnostics = tokio::io::sink();
            let execution = tokio::select! {
                result = async { tokio::try_join!(child.wait(), read_reply(&mut stdout), tokio::io::copy(&mut stderr, &mut diagnostics)) } => Some(result),
                _ = cancelled => None,
            };
            let (status, bytes, _) = match execution {
                None => {
                    child.kill().await?;
                    return Err(DecodeError::Cancelled);
                }
                Some(Err(error)) => {
                    // Reap before dropping the directory, including malformed
                    // helper output that fills stdout without closing it.
                    let _ = child.kill().await;
                    return Err(DecodeError::Io(error));
                }
                Some(Ok(result)) => result,
            };
            let reply: Reply = serde_json::from_slice(&bytes)
                .map_err(|e| DecodeError::InvalidOutput(e.to_string()))?;
            match reply {
                Reply::Error {
                    domain,
                    code,
                    reason,
                    message,
                } => Err(DecodeError::Native {
                    domain,
                    code,
                    reason,
                    message,
                }),
                Reply::Ok { path } if status.success() => {
                    validate_owned_wav(directory, Path::new(&path))
                }
                Reply::Ok { .. } => Err(DecodeError::InvalidOutput(format!(
                    "decoder exit: {status}"
                ))),
            }
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
    pub async fn wait(&mut self) -> Result<PreparedAudio, DecodeError> {
        let result = match self.task.as_mut() {
            Some(task) => task.await,
            None => {
                return Err(DecodeError::InvalidOutput(
                    "decode result already consumed".into(),
                ));
            }
        };
        self.task.take();
        self.cancel.take();
        result.map_err(io::Error::other)?
    }
}
impl Drop for DecodeTask {
    fn drop(&mut self) {
        self.cancel();
    }
}

#[derive(Deserialize)]
#[serde(tag = "status", rename_all = "lowercase")]
enum Reply {
    Ok {
        path: String,
    },
    Error {
        domain: String,
        code: i64,
        reason: Option<String>,
        message: String,
    },
}

async fn read_reply(reader: &mut (impl AsyncRead + Unpin)) -> io::Result<Vec<u8>> {
    let mut result = Vec::new();
    let mut bytes = [0; 4096];
    loop {
        let count = reader.read(&mut bytes).await?;
        if count == 0 {
            return Ok(result);
        }
        if result.len() + count > 64 * 1024 {
            return Err(io::Error::other("decode reply too large"));
        }
        result.extend_from_slice(&bytes[..count]);
    }
}

fn validate_owned_wav(directory: TempDir, candidate: &Path) -> Result<PreparedAudio, DecodeError> {
    let root = directory.path().canonicalize()?;
    let path = candidate.canonicalize()?;
    if !path.starts_with(&root)
        || path == root
        || path.extension().and_then(|e| e.to_str()) != Some("wav")
    {
        return Err(DecodeError::InvalidOutput(
            "decoded WAV is outside its owned directory".into(),
        ));
    }
    let mut file = std::fs::File::open(&path)?;
    let mut header = [0; 44];
    io::Read::read_exact(&mut file, &mut header)?;
    let file_bytes = file.metadata()?.len();
    let data_bytes = u32::from_le_bytes(header[40..44].try_into().unwrap());
    if &header[..4] != b"RIFF"
        || &header[8..16] != b"WAVEfmt "
        || header[20..24] != [1, 0, 1, 0]
        || u32::from_le_bytes(header[4..8].try_into().unwrap()) as u64 + 8 != file_bytes
        || u32::from_le_bytes(header[16..20].try_into().unwrap()) != 16
        || u32::from_le_bytes(header[24..28].try_into().unwrap()) != 16_000
        || u32::from_le_bytes(header[28..32].try_into().unwrap()) != 32_000
        || header[32..34] != [2, 0]
        || header[34..36] != [16, 0]
        || &header[36..40] != b"data"
        || file_bytes != u64::from(data_bytes) + 44
        || data_bytes == 0
        || data_bytes % 2 != 0
    {
        return Err(DecodeError::InvalidOutput(
            "decoder did not return canonical 16kHz mono PCM16 WAV".into(),
        ));
    }
    Ok(PreparedAudio { directory, path })
}

/// Build artifact for local development/tests only. Installed apps must resolve
/// their bundled helper; an OUT_DIR path is not a distributable runtime location.
#[cfg(target_os = "macos")]
pub fn development_helper() -> &'static Path {
    Path::new(env!("MADI_BUILT_AUDIO_DECODER"))
}

#[cfg(all(test, target_os = "macos"))]
mod tests;
