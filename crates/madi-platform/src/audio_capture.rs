//! In-process macOS capture boundary. No raw pointers or PCM cross WebView IPC.
//! Every handle owns a unique native endpoint; dropping it cancels only that
//! endpoint. The app's main run loop must remain alive through `Stopped`.
use madi_core::setup::AudioSource;
use std::{
    collections::BTreeMap,
    ffi::{CStr, c_char},
    io,
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};
use tokio::sync::mpsc;

#[derive(Debug, PartialEq)]
pub enum Event {
    Started,
    Samples { microphone: bool, pcm: Vec<i16> },
    Fault(String),
    Stopped,
}

// 20 seconds of queued mono PCM. A stalled consumer becomes an explicit fault;
// it cannot silently lose audio or let native callbacks grow memory forever.
const MAX_QUEUED_SAMPLES: usize = 16_000 * 20;
struct Endpoint {
    sender: mpsc::UnboundedSender<Event>,
    queued: usize,
    failed: bool,
}
static ENDPOINTS: OnceLock<Mutex<BTreeMap<u64, Endpoint>>> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
fn endpoints() -> std::sync::MutexGuard<'static, BTreeMap<u64, Endpoint>> {
    ENDPOINTS
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

type Callback = extern "C" fn(u64, u32, *const i16, usize, *const c_char) -> u8;
unsafe extern "C" {
    fn madi_capture_start(id: u64, source: u32, device: u32, callback: Callback);
    fn madi_capture_stop(id: u64);
    fn madi_capture_switch_input(id: u64, device: u32);
    #[cfg(debug_assertions)]
    fn madi_capture_replay(id: u64, path: *const c_char, chunk: u32, callback: Callback);
    #[cfg(debug_assertions)]
    fn madi_capture_pump();
}

// Called only by the linked Swift bridge. Pointers are borrowed through return
// and Swift's main actor serializes every callback, including final Stopped.
extern "C" fn receive(
    id: u64,
    kind: u32,
    pcm: *const i16,
    count: usize,
    error: *const c_char,
) -> u8 {
    let mut owners = endpoints();
    if kind == 5 {
        return owners
            .remove(&id)
            .is_some_and(|owner| owner.sender.send(Event::Stopped).is_ok()) as u8;
    }
    let Some(owner) = owners.get_mut(&id) else {
        return 0;
    };
    if owner.failed {
        return 0;
    }
    let event = match kind {
        1 => Event::Started,
        2 | 3 => {
            if count == 0 {
                return 1;
            }
            if pcm.is_null() || count > MAX_QUEUED_SAMPLES - owner.queued {
                owner.failed = true;
                let _ = owner
                    .sender
                    .send(Event::Fault("native audio consumer fell behind".into()));
                return 0;
            }
            // SAFETY: the linked bridge passes a valid Int16 array for this call.
            let samples = unsafe { std::slice::from_raw_parts(pcm, count) }.to_vec();
            owner.queued += count;
            Event::Samples {
                microphone: kind == 2,
                pcm: samples,
            }
        }
        4 => {
            let message = if error.is_null() {
                "native audio capture failed".into()
            } else {
                // SAFETY: Swift withCString keeps the NUL-terminated UTF-8 alive.
                unsafe { CStr::from_ptr(error) }
                    .to_string_lossy()
                    .into_owned()
            };
            Event::Fault(message)
        }
        _ => return 0,
    };
    owner.sender.send(event).is_ok() as u8
}

pub struct Capture {
    id: u64,
    events: mpsc::UnboundedReceiver<Event>,
}
impl Capture {
    fn register() -> io::Result<Self> {
        let mut id = NEXT_ID.load(Ordering::Relaxed);
        loop {
            let next = id
                .checked_add(1)
                .ok_or_else(|| io::Error::other("audio capture identity exhausted"))?;
            match NEXT_ID.compare_exchange_weak(id, next, Ordering::Relaxed, Ordering::Relaxed) {
                Ok(_) => break,
                Err(current) => id = current,
            }
        }
        let (sender, events) = mpsc::unbounded_channel();
        endpoints().insert(
            id,
            Endpoint {
                sender,
                queued: 0,
                failed: false,
            },
        );
        Ok(Self { id, events })
    }

    /// May cause the OS microphone/screen capture permission prompt. The caller
    /// must wait for Started or Fault; enqueuing start is not capture readiness.
    pub fn start(source: AudioSource, input_device: Option<u32>) -> io::Result<Self> {
        let capture = Self::register()?;
        let source = match source {
            AudioSource::Mic => 0,
            AudioSource::System => 1,
            AudioSource::Both => 2,
        };
        // SAFETY: native commands copy scalar arguments and enqueue on main.
        unsafe { madi_capture_start(capture.id, source, input_device.unwrap_or(0), receive) };
        Ok(capture)
    }

    pub fn switch_input(&mut self, device: Option<u32>) {
        // SAFETY: the native registry looks up this unique, non-reused ID.
        unsafe { madi_capture_switch_input(self.id, device.unwrap_or(0)) };
    }

    /// Stops device input, not Rust segmentation. Drain through Stopped, flush
    /// the Rust mix/segment tail, then acknowledge capture_stopped to Session.
    pub fn stop(&mut self) {
        // SAFETY: stale/duplicate IDs are harmless native registry misses.
        unsafe { madi_capture_stop(self.id) };
    }

    fn consumed(&self, event: &Event) {
        if let Event::Samples { pcm, .. } = event
            && let Some(owner) = endpoints().get_mut(&self.id)
        {
            owner.queued -= pcm.len();
        }
    }
    pub async fn next(&mut self) -> Option<Event> {
        let event = self.events.recv().await?;
        self.consumed(&event);
        Some(event)
    }
    pub fn try_next(&mut self) -> Result<Event, mpsc::error::TryRecvError> {
        let event = self.events.try_recv()?;
        self.consumed(&event);
        Ok(event)
    }

    /// Debug-only deterministic native conversion, with no microphone, screen
    /// capture or permissions. This API is deliberately absent from host IPC.
    #[cfg(debug_assertions)]
    pub fn replay(path: &std::path::Path, chunk_frames: u32) -> io::Result<Self> {
        use std::os::unix::ffi::OsStrExt;
        if chunk_frames == 0 || chunk_frames > 65_536 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid capture chunk size",
            ));
        }
        let path = std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(io::Error::other)?;
        let capture = Self::register()?;
        // SAFETY: Swift copies the path before this call returns.
        unsafe { madi_capture_replay(capture.id, path.as_ptr(), chunk_frames, receive) };
        Ok(capture)
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        endpoints().remove(&self.id);
        self.stop();
    }
}

/// Headless native verification only; production uses Tauri's main run loop.
#[cfg(debug_assertions)]
pub fn pump_verification_run_loop(_: objc2::MainThreadMarker) {
    // SAFETY: MainThreadMarker proves that Foundation's main loop is on main.
    unsafe { madi_capture_pump() };
}

/// Headless installed-bundle check. Drives the same native ingress callback and
/// converter without creating AVAudioEngine, SCStream, a window or permissions.
#[cfg(debug_assertions)]
pub fn verify_replay(path: &std::path::Path) -> io::Result<serde_json::Value> {
    use crate::capture_pipeline::{CapturePipeline, Event as PipelineEvent};
    use sha2::{Digest, Sha256};
    use std::time::{Duration, Instant};
    let main = objc2::MainThreadMarker::new()
        .ok_or_else(|| io::Error::other("capture verification requires main thread"))?;
    let mut capture = Capture::replay(path, 4096)?;
    let mut started = false;
    let mut samples = 0;
    let mut digest = Sha256::new();
    let mut fault = None;
    let mut pipeline = CapturePipeline::new(
        madi_core::capture_stream::Configuration::default(),
        &std::env::temp_dir(),
    )?;
    let directory = pipeline.directory().to_owned();
    pipeline.start();
    let mut segments = Vec::new();
    fn record_wavs(
        events: Vec<PipelineEvent>,
        segments: &mut Vec<serde_json::Value>,
    ) -> io::Result<()> {
        for event in events {
            match event {
                PipelineEvent::Segment {
                    offset,
                    wav,
                    had_speech,
                } => {
                    let data = std::fs::read(wav.path())?;
                    segments.push(
                        serde_json::json!({"name":wav.path().file_name().and_then(|n| n.to_str()),
                        "offsetBits":format!("{:016x}",offset.to_bits()),"hadSpeech":had_speech,
                        "wavBytes":data.len(),"wavSHA256":format!("{:x}",Sha256::digest(data))}),
                    );
                }
                PipelineEvent::Level(_) => {}
                PipelineEvent::WriteFailed { error, .. } => return Err(error),
                PipelineEvent::Preview { .. } => {
                    return Err(io::Error::other("unexpected replay preview"));
                }
            }
        }
        Ok(())
    }
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        pump_verification_run_loop(main);
        while let Ok(event) = capture.try_next() {
            match event {
                Event::Started if !started => started = true,
                Event::Samples {
                    microphone: true,
                    pcm,
                } if started => {
                    samples += pcm.len();
                    for sample in &pcm {
                        digest.update(sample.to_le_bytes());
                    }
                    record_wavs(pipeline.ingest(&pcm, true), &mut segments)?;
                }
                Event::Fault(message) => {
                    fault.get_or_insert(message);
                }
                Event::Stopped => {
                    if let Some(message) = fault {
                        return Err(io::Error::other(message));
                    }
                    if !started {
                        return Err(io::Error::other("capture stopped without readiness"));
                    }
                    record_wavs(pipeline.stop(), &mut segments)?;
                    drop(pipeline);
                    if directory.exists() {
                        return Err(io::Error::other("capture replay segment directory leaked"));
                    }
                    return Ok(
                        serde_json::json!({"sampleCount":samples,"pcmSHA256":format!("{:x}",digest.finalize()),"stopped":true,"devicesOpened":false,"segments":segments,"ownedDirectoryCleaned":true}),
                    );
                }
                _ => return Err(io::Error::other("unexpected capture verification event")),
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "native capture verification timed out",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn callbacks_copy_pcm_and_close_only_the_matching_identity() {
        let mut first = Capture::register().unwrap();
        let mut second = Capture::register().unwrap();
        let mut pcm = [i16::MIN, 3, i16::MAX];
        assert_eq!(
            receive(first.id, 2, pcm.as_ptr(), pcm.len(), std::ptr::null()),
            1
        );
        pcm.fill(0);
        assert_eq!(
            first.try_next().unwrap(),
            Event::Samples {
                microphone: true,
                pcm: vec![i16::MIN, 3, i16::MAX]
            }
        );
        assert_eq!(endpoints()[&first.id].queued, 0);
        assert_eq!(
            receive(first.id, 5, std::ptr::null(), 0, std::ptr::null()),
            1
        );
        assert_eq!(first.try_next().unwrap(), Event::Stopped);
        assert_eq!(
            receive(first.id, 2, pcm.as_ptr(), pcm.len(), std::ptr::null()),
            0
        );
        assert_eq!(
            receive(second.id, 1, std::ptr::null(), 0, std::ptr::null()),
            1
        );
        assert_eq!(second.try_next().unwrap(), Event::Started);
    }

    #[test]
    fn slow_consumer_fails_once_and_retains_terminal_acknowledgement() {
        let mut capture = Capture::register().unwrap();
        let pcm = vec![1; MAX_QUEUED_SAMPLES];
        assert_eq!(
            receive(capture.id, 3, pcm.as_ptr(), pcm.len(), std::ptr::null()),
            1
        );
        assert_eq!(receive(capture.id, 3, pcm.as_ptr(), 1, std::ptr::null()), 0);
        assert_eq!(receive(capture.id, 3, pcm.as_ptr(), 1, std::ptr::null()), 0);
        assert_eq!(
            receive(capture.id, 5, std::ptr::null(), 0, std::ptr::null()),
            1
        );
        assert!(matches!(
            capture.try_next(),
            Ok(Event::Samples {
                microphone: false,
                ..
            })
        ));
        assert!(matches!(capture.try_next(), Ok(Event::Fault(_))));
        assert_eq!(capture.try_next().unwrap(), Event::Stopped);
        assert!(capture.try_next().is_err());
    }
}
