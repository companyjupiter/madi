//! One supervised DNA process shared by native caption/AI clients. This API is
//! deliberately not a renderer IPC surface. Product translation consumers are
//! connected separately, preserving their revision and session identities.
use madi_core::dna::{self, Candidate, Priority};
use madi_protocol::translate::{Event as WireEvent, TranslateStreamParser};
use std::{
    collections::{BTreeSet, VecDeque},
    io,
    path::PathBuf,
    process::Stdio,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::{Child, ChildStdin, ChildStdout, Command},
    sync::{mpsc, oneshot},
    task::JoinHandle,
    time::Instant,
};

// IDs survive owner replacement, so a token from an older broker can never
// accidentally authorize work in a new broker instance.
static NEXT_CLIENT: AtomicU64 = AtomicU64::new(1);
static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Launch {
    pub engine: PathBuf,
    pub model: PathBuf,
    // Test engines speak the real wire protocol without loading model weights.
    #[cfg(test)]
    pub(crate) arguments: Vec<std::ffi::OsString>,
}

impl Launch {
    pub fn new(engine: impl Into<PathBuf>, model: impl Into<PathBuf>) -> Self {
        Self {
            engine: engine.into(),
            model: model.into(),
            #[cfg(test)]
            arguments: Vec::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct ClientId(u64);
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RequestId(u64);

#[derive(Clone, Debug)]
pub enum Request {
    Turn {
        prompt: String,
        preserve_newlines: bool,
    },
    Prefix {
        slot: u8,
        text: String,
    },
}

impl Request {
    pub fn turn(prompt: impl Into<String>) -> Self {
        Self::Turn {
            prompt: prompt.into(),
            preserve_newlines: false,
        }
    }
    fn text(&self) -> &str {
        match self {
            Self::Turn { prompt, .. } => prompt,
            Self::Prefix { text, .. } => text,
        }
    }
    fn normalize(&mut self) -> io::Result<()> {
        let text = match self {
            Self::Turn { prompt, .. } => prompt,
            Self::Prefix { text, .. } => text,
        };
        if text.contains('\0') {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "NUL in DNA request",
            ));
        }
        *text = dna::one_line(text);
        Ok(())
    }
    fn wire(&self) -> Vec<u8> {
        match self {
            Self::Turn { prompt, .. } => format!("{prompt}\n").into_bytes(),
            Self::Prefix { slot, text } => format!("%%PFX {slot} {text}\n").into_bytes(),
        }
    }
    fn preserve_newlines(&self) -> bool {
        matches!(
            self,
            Self::Turn {
                preserve_newlines: true,
                ..
            }
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopReason {
    Detached,
    Shutdown,
    Timeout,
    Exited,
    IoFailure,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Started {
        generation: u64,
        pid: u32,
    },
    Ready {
        client: ClientId,
        generation: u64,
        capabilities: BTreeSet<String>,
    },
    Partial {
        client: ClientId,
        request: RequestId,
        generation: u64,
        text: String,
    },
    /// Prefix success is PFX_OK, matching the native broker callback. Failed,
    /// empty and cancelled requests complete once with None.
    Completed {
        client: ClientId,
        request: RequestId,
        text: Option<String>,
    },
    CaptionBusy(bool),
    TimedOut {
        generation: u64,
        request: RequestId,
    },
    Stopped {
        generation: u64,
        code: Option<i32>,
        reason: StopReason,
    },
    /// There will be no READY after this stop: drain queues owned by clients,
    /// including after a failed relaunch or exhausted watchdog restart budget.
    Unavailable {
        generation: u64,
        reason: StopReason,
    },
    Fault {
        operation: &'static str,
        message: String,
    },
}

pub(crate) struct ClientLease {
    pub(crate) client: ClientId,
    pub(crate) generation: u64,
    cleanup: Option<mpsc::UnboundedSender<Control>>,
}
impl ClientLease {
    pub(crate) async fn detach(&mut self) -> io::Result<()> {
        if let Some(commands) = &self.cleanup {
            let (tx, rx) = oneshot::channel();
            commands
                .send(Control::Detach(self.client, tx))
                .map_err(io::Error::other)?;
            rx.await.map_err(io::Error::other)?;
            self.cleanup = None;
        }
        Ok(())
    }
}
impl Drop for ClientLease {
    fn drop(&mut self) {
        if let Some(commands) = self.cleanup.take() {
            let (tx, _) = oneshot::channel();
            let _ = commands.send(Control::Detach(self.client, tx));
        }
    }
}
struct AttachRequest {
    launch: Launch,
    cleanup: mpsc::UnboundedSender<Control>,
    reply: oneshot::Sender<io::Result<ClientLease>>,
}
enum Control {
    Attach(AttachRequest),
    Submit(
        ClientId,
        Request,
        Priority,
        oneshot::Sender<io::Result<RequestId>>,
    ),
    Cancel(ClientId, oneshot::Sender<()>),
    Detach(ClientId, oneshot::Sender<()>),
    Pressure(i64),
    Shutdown,
}

pub struct DnaBroker {
    commands: mpsc::UnboundedSender<Control>,
    events: mpsc::UnboundedReceiver<Event>,
    task: Option<JoinHandle<()>>,
    shutdown_requested: Arc<AtomicBool>,
}

impl DnaBroker {
    pub fn new() -> io::Result<Self> {
        let override_seconds = std::env::var("MADI_DNA_TIMEOUT_MS")
            .ok()
            .as_deref()
            .and_then(dna::timeout_override);
        Self::with_timeout(override_seconds.and_then(|s| Duration::try_from_secs_f64(s).ok()))
    }
    pub(crate) fn with_timeout(timeout: Option<Duration>) -> io::Result<Self> {
        tokio::runtime::Handle::try_current().map_err(io::Error::other)?;
        let (commands, input) = mpsc::unbounded_channel();
        let (output, events) = mpsc::unbounded_channel();
        let shutdown_requested = Arc::new(AtomicBool::new(false));
        let task =
            tokio::spawn(Owner::new(input, output, timeout, shutdown_requested.clone()).run());
        Ok(Self {
            commands,
            events,
            task: Some(task),
            shutdown_requested,
        })
    }
    pub async fn attach(&self, launch: Launch) -> io::Result<ClientId> {
        self.attach_owned(launch).await.map(|mut a| {
            a.cleanup = None;
            a.client
        })
    }
    pub(crate) async fn attach_owned(&self, launch: Launch) -> io::Result<ClientLease> {
        let (tx, rx) = oneshot::channel();
        self.send(Control::Attach(AttachRequest {
            launch,
            cleanup: self.commands.clone(),
            reply: tx,
        }))?;
        rx.await.map_err(io::Error::other)?
    }
    pub(crate) async fn attach_caption(&self, launch: Launch) -> io::Result<CaptionLease> {
        let mut attached = self.attach_owned(launch).await?;
        Ok(CaptionLease {
            client: attached.client,
            generation: attached.generation,
            commands: attached.cleanup.take().expect("unclaimed attachment"),
            detached: false,
        })
    }
    pub async fn submit(
        &self,
        client: ClientId,
        request: Request,
        priority: Priority,
    ) -> io::Result<RequestId> {
        let (tx, rx) = oneshot::channel();
        self.send(Control::Submit(client, request, priority, tx))?;
        rx.await.map_err(io::Error::other)?
    }
    pub async fn cancel_pending(&self, client: ClientId) -> io::Result<()> {
        let (tx, rx) = oneshot::channel();
        self.send(Control::Cancel(client, tx))?;
        rx.await.map_err(io::Error::other)
    }
    /// The final detach acknowledges only after the old child is reaped. A
    /// subsequent attach cannot overlap model allocations with a dying process.
    pub async fn detach(&self, client: ClientId) -> io::Result<()> {
        let (tx, rx) = oneshot::channel();
        self.send(Control::Detach(client, tx))?;
        rx.await.map_err(io::Error::other)
    }
    pub fn report_caption_pressure(&self, depth: i64) -> io::Result<()> {
        self.send(Control::Pressure(depth))
    }
    pub fn shutdown(&self) {
        self.shutdown_requested.store(true, Ordering::Release);
        let _ = self.commands.send(Control::Shutdown);
    }
    pub async fn next(&mut self) -> Option<Event> {
        self.events.recv().await
    }
    pub async fn wait(&mut self) -> io::Result<()> {
        if let Some(task) = self.task.as_mut() {
            task.await.map_err(io::Error::other)?;
        }
        self.task.take();
        Ok(())
    }
    fn send(&self, command: Control) -> io::Result<()> {
        if self.shutdown_requested.load(Ordering::Acquire) {
            return Err(io::ErrorKind::BrokenPipe.into());
        }
        self.commands
            .send(command)
            .map_err(|_| io::ErrorKind::BrokenPipe.into())
    }
}

/// A session adapter may be dropped while an async detach is cancelled. Keep
/// native client release owned even when its caller cannot await cleanup.
pub(crate) struct CaptionLease {
    pub(crate) client: ClientId,
    pub(crate) generation: u64,
    commands: mpsc::UnboundedSender<Control>,
    detached: bool,
}
impl CaptionLease {
    pub(crate) async fn detach(&mut self) -> io::Result<()> {
        if self.detached {
            return Ok(());
        }
        let (tx, rx) = oneshot::channel();
        self.commands
            .send(Control::Detach(self.client, tx))
            .map_err(io::Error::other)?;
        rx.await.map_err(io::Error::other)?;
        self.detached = true;
        Ok(())
    }
}
impl Drop for CaptionLease {
    fn drop(&mut self) {
        if !self.detached {
            let _ = self.commands.send(Control::Pressure(0));
            let (tx, _) = oneshot::channel();
            let _ = self.commands.send(Control::Detach(self.client, tx));
        }
    }
}
impl Drop for DnaBroker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

struct Pending {
    id: RequestId,
    client: ClientId,
    request: Request,
    priority: Priority,
    enqueued: Instant,
}

struct Process {
    child: Child,
    input: ChildStdin,
    output: ChildStdout,
    launch: Launch,
    generation: u64,
    parser: TranslateStreamParser,
    capabilities: BTreeSet<String>,
    ready: bool,
    bytes: Vec<u8>,
    written: usize,
    active: Option<Pending>,
    deadline: Option<Instant>,
    stopping: Option<StopReason>,
    kill_at: Option<Instant>,
    exited: Option<std::process::ExitStatus>,
    eof: bool,
    drain_until: Option<Instant>,
}

impl Process {
    fn spawn(launch: Launch, generation: u64) -> io::Result<Self> {
        let mut command = Command::new(&launch.engine);
        #[cfg(test)]
        command.args(&launch.arguments);
        command
            .arg(&launch.model)
            .env_remove("SOV_DEBUG")
            .env("SOV_NSTEPS", dna::GENERATION_STEPS.to_string())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        #[cfg(windows)]
        command.creation_flags(0x08000000);
        let mut child = command.spawn()?;
        Ok(Self {
            input: child
                .stdin
                .take()
                .ok_or_else(|| io::Error::other("missing DNA stdin"))?,
            output: child
                .stdout
                .take()
                .ok_or_else(|| io::Error::other("missing DNA stdout"))?,
            child,
            launch,
            generation,
            parser: TranslateStreamParser::default(),
            capabilities: BTreeSet::new(),
            ready: false,
            bytes: Vec::new(),
            written: 0,
            active: None,
            deadline: None,
            stopping: None,
            kill_at: None,
            exited: None,
            eof: false,
            drain_until: None,
        })
    }
    fn terminate(&mut self, reason: StopReason) {
        if self.stopping.is_some() {
            return;
        }
        self.stopping = Some(reason);
        self.ready = false;
        self.deadline = None;
        self.bytes.clear();
        self.written = 0;
        if self.exited.is_some() {
            return;
        }
        #[cfg(unix)]
        if let Some(id) = self.child.id() {
            // SAFETY: this task exclusively owns the unreaped child.
            if unsafe { libc::kill(id as libc::pid_t, libc::SIGTERM) } != 0 {
                let _ = self.child.start_kill();
            }
        }
        #[cfg(not(unix))]
        let _ = self.child.start_kill();
        self.kill_at = Some(Instant::now() + Duration::from_secs(2));
    }
}

struct Owner {
    commands: mpsc::UnboundedReceiver<Control>,
    events: mpsc::UnboundedSender<Event>,
    clients: BTreeSet<ClientId>,
    pending: VecDeque<Pending>,
    process: Option<Process>,
    generation: u64,
    wedges: u32,
    pressure: i64,
    busy: bool,
    timeout: Option<Duration>,
    detach_replies: Vec<oneshot::Sender<()>>,
    deferred_attach: VecDeque<AttachRequest>,
    shutting_down: bool,
    shutdown_requested: Arc<AtomicBool>,
}

enum Signal {
    Command(Option<Control>),
    Read(io::Result<usize>),
    Written(io::Result<usize>),
    Exited(io::Result<std::process::ExitStatus>),
    Timeout,
    Kill,
    DrainExpired,
}

impl Owner {
    fn new(
        commands: mpsc::UnboundedReceiver<Control>,
        events: mpsc::UnboundedSender<Event>,
        timeout: Option<Duration>,
        shutdown_requested: Arc<AtomicBool>,
    ) -> Self {
        Self {
            commands,
            events,
            clients: BTreeSet::new(),
            pending: VecDeque::new(),
            process: None,
            generation: 0,
            wedges: 0,
            pressure: 0,
            busy: false,
            timeout,
            detach_replies: Vec::new(),
            deferred_attach: VecDeque::new(),
            shutting_down: false,
            shutdown_requested,
        }
    }
    fn emit(&self, event: Event) {
        let _ = self.events.send(event);
    }
    fn fault(&self, operation: &'static str, error: impl std::fmt::Display) {
        self.emit(Event::Fault {
            operation,
            message: error.to_string(),
        });
    }
    fn launch(&mut self, launch: Launch) -> io::Result<()> {
        self.generation += 1;
        let process = Process::spawn(launch, self.generation)?;
        self.emit(Event::Started {
            generation: self.generation,
            pid: process.child.id().unwrap_or(0),
        });
        self.process = Some(process);
        Ok(())
    }
    fn complete(&self, request: Pending, text: Option<String>) {
        if self.clients.contains(&request.client) {
            self.emit(Event::Completed {
                client: request.client,
                request: request.id,
                text,
            });
        }
    }
    fn report_busy(&mut self) {
        let busy = self.pending.iter().any(|r| r.priority.is_caption())
            || self
                .process
                .as_ref()
                .and_then(|p| p.active.as_ref())
                .is_some_and(|r| r.priority.is_caption());
        if self.busy != busy {
            self.busy = busy;
            self.emit(Event::CaptionBusy(busy));
        }
    }
    fn pump(&mut self) {
        let Some(process) = self.process.as_mut() else {
            return;
        };
        if !process.ready || process.active.is_some() || process.exited.is_some() || process.eof {
            return;
        }
        let now = Instant::now();
        let candidates: Vec<_> = self
            .pending
            .iter()
            .map(|r| Candidate {
                priority: r.priority as i32,
                sequence: r.id.0,
                waited_seconds: now.duration_since(r.enqueued).as_secs_f64(),
            })
            .collect();
        let Some(index) =
            dna::eligible_index(&candidates, self.pressure, dna::BACKGROUND_AGING_SECONDS)
        else {
            return;
        };
        let request = self.pending.remove(index).unwrap();
        process.parser = TranslateStreamParser::new(request.request.preserve_newlines());
        let derived = Duration::from_secs_f64(dna::turn_budget_seconds(
            request.request.text().len() as i64,
            dna::GENERATION_STEPS,
            &process.launch.engine.to_string_lossy(),
        ));
        process.deadline = Some(
            now.checked_add(self.timeout.unwrap_or(derived))
                .unwrap_or(now + derived),
        );
        process.bytes = request.request.wire();
        process.written = 0;
        process.active = Some(request);
    }

    fn control(&mut self, command: Control) {
        match command {
            Control::Attach(AttachRequest {
                launch,
                cleanup,
                reply,
            }) => {
                if reply.is_closed() {
                    return;
                }
                if self.shutdown_requested.load(Ordering::Acquire) || self.shutting_down {
                    let _ = reply.send(Err(io::ErrorKind::BrokenPipe.into()));
                    return;
                }
                if self.process.as_ref().is_some_and(|p| p.stopping.is_some()) {
                    self.deferred_attach.push_back(AttachRequest {
                        launch,
                        cleanup,
                        reply,
                    });
                    return;
                }
                if self.process.as_ref().is_some_and(|p| p.launch != launch) {
                    let _ = reply.send(Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "DNA clients must share one engine/model",
                    )));
                    return;
                }
                if self.process.is_none()
                    && let Err(error) = self.launch(launch)
                {
                    let _ = reply.send(Err(error));
                    return;
                }
                let client = ClientId(NEXT_CLIENT.fetch_add(1, Ordering::Relaxed));
                self.clients.insert(client);
                if let Some(p) = &self.process
                    && p.ready
                {
                    self.emit(Event::Ready {
                        client,
                        generation: p.generation,
                        capabilities: p.capabilities.clone(),
                    });
                }
                // A cancelled attach must not leave an invisible resident client.
                let generation = self.process.as_ref().expect("attached process").generation;
                if reply
                    .send(Ok(ClientLease {
                        client,
                        generation,
                        cleanup: Some(cleanup),
                    }))
                    .is_err()
                {
                    self.clients.remove(&client);
                    if self.clients.is_empty()
                        && let Some(p) = self.process.as_mut()
                    {
                        p.terminate(StopReason::Detached);
                    }
                }
            }
            Control::Submit(client, mut request, priority, reply) => {
                let result = if !self.clients.contains(&client) {
                    Err(io::Error::new(
                        io::ErrorKind::NotConnected,
                        "DNA client detached",
                    ))
                } else if self.process.is_none() {
                    Err(io::Error::new(
                        io::ErrorKind::NotConnected,
                        "DNA engine unavailable",
                    ))
                } else {
                    request.normalize()
                };
                if let Err(error) = result {
                    let _ = reply.send(Err(error));
                    return;
                }
                let id = RequestId(NEXT_REQUEST.fetch_add(1, Ordering::Relaxed));
                self.pending.push_back(Pending {
                    id,
                    client,
                    request,
                    priority,
                    enqueued: Instant::now(),
                });
                if reply.send(Ok(id)).is_err() {
                    self.pending.pop_back();
                }
            }
            Control::Cancel(client, reply) => {
                let mut retained = VecDeque::new();
                while let Some(request) = self.pending.pop_front() {
                    if request.client == client {
                        self.complete(request, None);
                    } else {
                        retained.push_back(request);
                    }
                }
                self.pending = retained;
                let _ = reply.send(());
            }
            Control::Detach(client, reply) => {
                self.clients.remove(&client);
                self.pending.retain(|r| r.client != client);
                if self.clients.is_empty() {
                    self.wedges = 0;
                    if let Some(p) = self.process.as_mut() {
                        p.terminate(StopReason::Detached);
                        self.detach_replies.push(reply);
                    } else {
                        let _ = reply.send(());
                    }
                } else {
                    let _ = reply.send(());
                }
            }
            Control::Pressure(depth) => self.pressure = depth,
            Control::Shutdown => {
                self.shutting_down = true;
                if let Some(p) = self.process.as_mut() {
                    p.terminate(StopReason::Shutdown);
                }
            }
        }
    }

    fn ingest(&mut self, bytes: &[u8]) {
        let Some(process) = self.process.as_mut() else {
            return;
        };
        if process.stopping.is_some() {
            return;
        }
        let generation = process.generation;
        let events = process.parser.ingest(bytes);
        for event in events {
            let p = self.process.as_mut().unwrap();
            match event {
                WireEvent::Capabilities(tokens) => p.capabilities = tokens.into_iter().collect(),
                WireEvent::Ready => {
                    p.ready = true;
                    let capabilities = p.capabilities.clone();
                    for &client in &self.clients { self.emit(Event::Ready { client, generation, capabilities: capabilities.clone() }); }
                }
                WireEvent::ReplyDelta(text) => {
                    if let Some(r) = &p.active && self.clients.contains(&r.client) && matches!(r.request, Request::Turn { .. }) {
                        let event = Event::Partial { client: r.client, request: r.id, generation, text };
                        self.emit(event);
                    }
                }
                WireEvent::PrefixReady(slot) => {
                    if p.active.as_ref().is_some_and(|r| matches!(r.request, Request::Prefix { slot: expected, .. } if i64::from(expected) == slot)) {
                        let request = p.active.take().unwrap(); p.deadline = None;
                        self.wedges = 0;
                        self.complete(request, Some("PFX_OK".into()));
                    }
                }
                WireEvent::TurnComplete(text) => {
                    if let Some(request) = p.active.take() {
                        p.deadline = None;
                        self.wedges = 0;
                        let value = (matches!(request.request, Request::Turn { .. }) && !text.is_empty()).then_some(text);
                        self.complete(request, value);
                    }
                }
            }
        }
    }

    fn finished(&mut self) {
        let mut process = self.process.take().unwrap();
        let reason = process.stopping.unwrap_or(StopReason::Exited);
        let generation = process.generation;
        let code = process.exited.and_then(|s| s.code());
        let launch = process.launch.clone();
        let mut orphans = std::mem::take(&mut self.pending);
        if let Some(active) = process.active.take() {
            orphans.push_back(active);
        }
        self.emit(Event::Stopped {
            generation: process.generation,
            code,
            reason,
        });
        // The old child is reaped before replacing the parser and file handles.
        drop(process);
        if reason == StopReason::Timeout
            && !self.clients.is_empty()
            && !self.commands.is_closed()
            && !self.shutdown_requested.load(Ordering::Acquire)
            && self.wedges < dna::MAX_WEDGE_RESTARTS
        {
            self.wedges += 1;
            if let Err(error) = self.launch(launch) {
                self.fault("relaunch", error);
            }
        }
        // Reset/relaunch before completions: next-turn submissions from a
        // completion consumer cannot be erased by the old process reset.
        if self.process.is_none() && !self.clients.is_empty() {
            self.emit(Event::Unavailable { generation, reason });
        }
        for request in orphans {
            self.complete(request, None);
        }
        for reply in self.detach_replies.drain(..) {
            let _ = reply.send(());
        }
        // A cancelled attach can itself start teardown. Handle each deferred
        // command once, leaving any re-deferred work for the next reap.
        for request in std::mem::take(&mut self.deferred_attach) {
            self.control(Control::Attach(request));
        }
    }

    async fn run(mut self) {
        let mut buffer = [0u8; 16 * 1024];
        loop {
            if self.shutdown_requested.load(Ordering::Acquire) && !self.shutting_down {
                self.control(Control::Shutdown);
            }
            self.pump();
            self.report_busy();
            if self.shutting_down && self.process.is_none() {
                break;
            }
            let signal = if let Some(p) = self.process.as_mut() {
                // During termination, no request is written and late output is
                // quarantined. Detach/cancel/shutdown still change ownership.
                tokio::select! {
                    command = self.commands.recv(), if !self.commands.is_closed() => Signal::Command(command),
                    result = p.output.read(&mut buffer), if !p.eof => Signal::Read(result),
                    result = p.input.write(&p.bytes[p.written..]), if p.written < p.bytes.len() && p.exited.is_none() && p.stopping.is_none() => Signal::Written(result),
                    result = p.child.wait(), if p.exited.is_none() => Signal::Exited(result),
                    _ = tokio::time::sleep_until(p.deadline.unwrap_or_else(Instant::now)), if p.deadline.is_some() => Signal::Timeout,
                    _ = tokio::time::sleep_until(p.kill_at.unwrap_or_else(Instant::now)), if p.kill_at.is_some() && p.exited.is_none() => Signal::Kill,
                    _ = tokio::time::sleep_until(p.drain_until.unwrap_or_else(Instant::now)), if p.drain_until.is_some() => Signal::DrainExpired,
                }
            } else {
                Signal::Command(self.commands.recv().await)
            };
            match signal {
                Signal::Command(command) => self.control(command.unwrap_or(Control::Shutdown)),
                Signal::Read(Ok(0)) => {
                    let p = self.process.as_mut().unwrap();
                    p.eof = true;
                    // A child that closes stdout without exiting can never
                    // answer queued clients. Bound that half-closed state.
                    if p.exited.is_none() {
                        p.drain_until = Some(Instant::now() + Duration::from_secs(2));
                    }
                }
                Signal::Read(Ok(count)) => self.ingest(&buffer[..count]),
                Signal::Written(Ok(0)) => {
                    self.fault("write", "DNA stdin returned zero bytes");
                    self.process
                        .as_mut()
                        .unwrap()
                        .terminate(StopReason::IoFailure);
                }
                Signal::Written(Ok(count)) => self.process.as_mut().unwrap().written += count,
                Signal::Read(Err(error)) | Signal::Written(Err(error)) => {
                    self.fault("pipe", error);
                    self.process
                        .as_mut()
                        .unwrap()
                        .terminate(StopReason::IoFailure);
                }
                Signal::Exited(Ok(status)) => {
                    let p = self.process.as_mut().unwrap();
                    p.exited = Some(status);
                    p.kill_at = None;
                    p.deadline = None;
                    p.drain_until = Some(Instant::now() + Duration::from_secs(2));
                }
                Signal::Exited(Err(error)) => {
                    self.fault("wait", error);
                    self.process
                        .as_mut()
                        .unwrap()
                        .terminate(StopReason::IoFailure);
                }
                Signal::Timeout => {
                    let p = self.process.as_ref().unwrap();
                    if let Some(request) = p.active.as_ref() {
                        self.emit(Event::TimedOut {
                            generation: p.generation,
                            request: request.id,
                        });
                    }
                    self.process
                        .as_mut()
                        .unwrap()
                        .terminate(StopReason::Timeout);
                }
                Signal::Kill => {
                    let p = self.process.as_mut().unwrap();
                    if let Err(error) = p.child.start_kill() {
                        self.fault("kill", error);
                    }
                    self.process.as_mut().unwrap().kill_at = None;
                }
                Signal::DrainExpired => {
                    self.fault("drain", "DNA child/pipe did not close together");
                    let p = self.process.as_mut().unwrap();
                    p.eof = true;
                    p.drain_until = None;
                    p.terminate(StopReason::IoFailure);
                }
            }
            if self
                .process
                .as_ref()
                .is_some_and(|p| p.exited.is_some() && (p.eof || p.stopping.is_some()))
            {
                self.finished();
            }
        }
    }
}

#[cfg(test)]
mod tests;
