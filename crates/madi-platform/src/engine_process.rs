//! Token-tagged ASR process transport. Only trusted Rust configuration can spawn
//! it; this is not a frontend shell command or the complete session executor.
use madi_core::session::Token;
use madi_protocol::stream::{EventStream, Output};
use std::{
    collections::{BTreeMap, VecDeque},
    ffi::OsString,
    fs::File,
    io::{self, Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    process::{ExitStatus, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};
use tempfile::TempDir;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::{Child, ChildStdin, Command},
    sync::mpsc,
    task::JoinHandle,
    time::Instant,
};

/// Paths and environment resolved by the native host, never deserialized from
/// UI messages. EVENTS_FILE is always replaced with an adapter-owned path.
pub struct Launch {
    pub executable: PathBuf,
    pub arguments: Vec<OsString>,
    pub working_directory: PathBuf,
    /// None removes an inherited variable. Several engine switches test only
    /// presence, so setting a file-mode STREAM variable to "0" is not removal.
    pub environment: BTreeMap<OsString, Option<OsString>>,
}

#[derive(Debug, PartialEq)]
pub enum Event {
    Protocol(Output),
    Capabilities(Vec<String>),
    /// Internal diagnostics; the product executor maps failures to localized UI.
    IoFailure {
        operation: &'static str,
        message: String,
    },
}

#[derive(Debug, PartialEq)]
pub struct Message {
    pub token: Token,
    pub event: Event,
}

enum Control {
    Line(Vec<u8>),
    CloseInput,
    Terminate,
}

pub struct EngineProcess {
    commands: mpsc::UnboundedSender<Control>,
    events: mpsc::UnboundedReceiver<Message>,
    input_closed: AtomicBool,
    task: Option<JoinHandle<io::Result<()>>>,
    events_path: PathBuf,
}

impl EngineProcess {
    /// Requires a running Tokio runtime with IO/time enabled. scratch_parent
    /// must be an application-owned scratch location. No caller-provided path
    /// is ever registered for cleanup: only the newly created child directory.
    pub fn spawn(launch: Launch, token: Token, scratch_parent: &Path) -> io::Result<Self> {
        tokio::runtime::Handle::try_current().map_err(io::Error::other)?;
        let scratch = tempfile::Builder::new()
            .prefix("madi-engine-")
            .tempdir_in(scratch_parent)?;
        let events_path = scratch.path().join("events.jsonl");
        let mut command = Command::new(&launch.executable);
        command
            .args(launch.arguments)
            .current_dir(launch.working_directory)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        for (key, value) in launch.environment {
            if let Some(value) = value {
                command.env(key, value);
            } else {
                command.env_remove(key);
            }
        }
        // This path is owned regardless of configuration/environment overrides.
        command.env("EVENTS_FILE", &events_path);
        #[cfg(windows)]
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW: no console flash.
        let child = command.spawn()?;
        let (commands, control) = mpsc::unbounded_channel();
        let (output, events) = mpsc::unbounded_channel();
        let task = tokio::spawn(supervise(child, token, scratch, control, output));
        Ok(Self {
            commands,
            events,
            input_closed: AtomicBool::new(false),
            task: Some(task),
            events_path,
        })
    }

    /// Queue one protocol line. The supervisor writes incrementally so a blocked
    /// child stdin can never prevent stdout draining or cancellation.
    pub fn send_line(&self, line: &str) -> io::Result<()> {
        if line.contains(['\n', '\r', '\0']) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "expected one protocol line",
            ));
        }
        if self.input_closed.load(Ordering::Acquire) {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "engine input closed",
            ));
        }
        let mut bytes = line.as_bytes().to_vec();
        bytes.push(b'\n');
        self.commands
            .send(Control::Line(bytes))
            .map_err(|_| io::ErrorKind::BrokenPipe.into())
    }

    /// EOF follows all already-queued lines, including a final FLUSH.
    pub fn close_input(&self) {
        if !self.input_closed.swap(true, Ordering::AcqRel) {
            let _ = self.commands.send(Control::CloseInput);
        }
    }

    /// Graceful user Stop is a protocol FLUSH, not this resource teardown.
    /// macOS teardown starts with SIGTERM as Foundation.Process does, then
    /// escalates after two seconds if the child ignores it.
    pub fn terminate(&self) {
        self.input_closed.store(true, Ordering::Release);
        let _ = self.commands.send(Control::Terminate);
    }

    pub async fn next(&mut self) -> Option<Message> {
        self.events.recv().await
    }

    /// Wait for the child, stdout tail and owned-file cleanup. Output remains
    /// available in `next`; callers should normally consume it while running.
    pub async fn wait(&mut self) -> io::Result<()> {
        let result = match self.task.as_mut() {
            Some(task) => task.await,
            None => return Ok(()),
        };
        // Keep the handle in self until await completes: cancelling a wait must
        // not detach supervision or make the next wait report premature success.
        self.task.take();
        result.map_err(io::Error::other)?
    }

    pub fn events_path(&self) -> &Path {
        &self.events_path
    }
}

impl Drop for EngineProcess {
    fn drop(&mut self) {
        // Keep the supervisor alive to reap/drain/clean its own resources.
        // Dropping a Tokio JoinHandle detaches it; it does not abort the task.
        self.terminate();
    }
}

struct EventFile {
    path: PathBuf,
    offset: u64,
}
impl EventFile {
    fn read_appended(&mut self) -> Vec<u8> {
        let mut bytes = Vec::new();
        // Like Swift, unavailable EVENTS_FILE reads are non-fatal. The original
        // may not have created it yet. Read only at protocol barriers, not EOF.
        if let Ok(mut file) = File::open(&self.path)
            && file.seek(SeekFrom::Start(self.offset)).is_ok()
            && file.read_to_end(&mut bytes).is_ok()
        {
            self.offset += bytes.len() as u64;
            return bytes;
        }
        Vec::new()
    }
}

fn exit_code(status: ExitStatus) -> i32 {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        status.code().or_else(|| status.signal()).unwrap_or(-1)
    }
    #[cfg(not(unix))]
    status.code().unwrap_or(-1)
}

fn request_termination(child: &mut Child) -> io::Result<()> {
    #[cfg(unix)]
    if let Some(id) = child.id() {
        // SAFETY: the supervisor owns this unreaped child and is the only code
        // polling it. Its process id cannot be reused before wait completes.
        let status = unsafe { libc::kill(id as libc::pid_t, libc::SIGTERM) };
        if status != 0 {
            return Err(io::Error::last_os_error());
        }
        return Ok(());
    }
    #[cfg(not(unix))]
    return child.start_kill();
    #[cfg(unix)]
    Ok(())
}

async fn write_pending(
    input: &mut Option<ChildStdin>,
    pending: &mut VecDeque<Vec<u8>>,
    offset: &mut usize,
) -> io::Result<()> {
    let bytes = pending.front().expect("write branch requires queued data");
    let count = input
        .as_mut()
        .expect("write branch requires stdin")
        .write(&bytes[*offset..])
        .await?;
    if count == 0 {
        return Err(io::ErrorKind::WriteZero.into());
    }
    *offset += count;
    if *offset == bytes.len() {
        pending.pop_front();
        *offset = 0;
    }
    Ok(())
}

async fn supervise(
    mut child: Child,
    token: Token,
    scratch: TempDir,
    mut commands: mpsc::UnboundedReceiver<Control>,
    output: mpsc::UnboundedSender<Message>,
) -> io::Result<()> {
    let mut input = child.stdin.take();
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("missing engine stdout"))?;
    let emit = |event| {
        let _ = output.send(Message { token, event });
    };
    let fault = |operation, error: io::Error| {
        emit(Event::IoFailure {
            operation,
            message: error.to_string(),
        })
    };
    let mut events = EventFile {
        path: scratch.path().join("events.jsonl"),
        offset: 0,
    };
    let mut parser = EventStream::default();
    let mut capabilities = Vec::new();
    let mut pending = VecDeque::new();
    let mut write_offset = 0;
    let mut close_input = false;
    let mut terminating = false;
    let mut force_kill_at = None;
    let mut drain_deadline = None;
    let mut control_open = true;
    let mut stdout_open = true;
    let mut status = None;
    let mut bytes = [0; 8192];
    loop {
        if close_input && pending.is_empty() {
            input.take();
        }
        if status.is_some() && !stdout_open {
            break;
        }
        tokio::select! {
            control = commands.recv(), if control_open && !terminating => {
                match control {
                    Some(Control::Line(bytes)) if !close_input && input.is_some() => pending.push_back(bytes),
                    Some(Control::Line(_)) => {},
                    Some(Control::CloseInput) => close_input = true,
                    Some(Control::Terminate) | None => {
                        control_open = false;
                        terminating = true;
                        pending.clear(); input.take();
                        if let Err(error) = request_termination(&mut child) { fault("terminate", error); }
                        force_kill_at = Some(Instant::now() + Duration::from_secs(2));
                    }
                }
            }
            _ = output.closed(), if !terminating => {
                terminating = true;
                pending.clear(); input.take();
                if let Err(error) = request_termination(&mut child) { fault("terminate", error); }
                force_kill_at = Some(Instant::now() + Duration::from_secs(2));
            }
            result = stdout.read(&mut bytes), if stdout_open => {
                match result {
                    Ok(0) => stdout_open = false,
                    Ok(count) => {
                        let parsed = parser.ingest_stdout(&bytes[..count], || events.read_appended());
                        let current: Vec<_> = parser.capabilities().iter().cloned().collect();
                        if capabilities != current {
                            capabilities = current;
                            emit(Event::Capabilities(capabilities.clone()));
                        }
                        for event in parsed { emit(Event::Protocol(event)); }
                    }
                    Err(error) => {
                        fault("read stdout", error);
                        stdout_open = false;
                        terminating = true;
                        let _ = child.start_kill();
                    }
                }
            }
            result = write_pending(&mut input, &mut pending, &mut write_offset), if input.is_some() && !pending.is_empty() => {
                if let Err(error) = result {
                    fault("write stdin", error);
                    input.take(); pending.clear();
                }
            }
            result = child.wait(), if status.is_none() => {
                status = Some(result?);
                input.take(); pending.clear();
                // A descendant inheriting stdout must not keep a dead engine's
                // supervisor alive forever. Normal exit drains every queued byte.
                drain_deadline = Some(Instant::now() + Duration::from_secs(2));
            }
            _ = tokio::time::sleep_until(force_kill_at.unwrap_or_else(Instant::now)), if force_kill_at.is_some() && status.is_none() => {
                if let Err(error) = child.start_kill() { fault("force terminate", error); }
                force_kill_at = None;
            }
            _ = tokio::time::sleep_until(drain_deadline.unwrap_or_else(Instant::now)), if drain_deadline.is_some() && stdout_open => {
                fault("drain stdout", io::Error::new(io::ErrorKind::TimedOut, "pipe remained open after engine exit"));
                stdout_open = false;
            }
        }
    }
    for event in parser.finish(
        exit_code(status.expect("exit status before finish")),
        || events.read_appended(),
    ) {
        emit(Event::Protocol(event));
    }
    drop(stdout);
    scratch.close()
}

#[cfg(test)]
mod tests;
