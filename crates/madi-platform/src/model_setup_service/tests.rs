use super::*;
#[path = "tests_cancellation.rs"]
mod cancellation;
#[path = "tests_management.rs"]
mod management;
use madi_core::assets::RemoteAsset;
use std::{
    io::{Read, Write},
    net::TcpListener,
    path::Path,
    sync::{Mutex as StdMutex, mpsc},
    thread,
    time::{Duration, Instant},
};

fn service(root: &Path, engine: bool) -> (ModelSetupService, Arc<StdMutex<Vec<ModelSnapshot>>>) {
    let executables = root.join("MacOS");
    if engine {
        std::fs::create_dir_all(&executables).unwrap();
        std::fs::write(
            executables.join(format!(
                "translate-engine-4b{}",
                std::env::consts::EXE_SUFFIX
            )),
            b"fixture",
        )
        .unwrap();
    }
    let events = Arc::new(StdMutex::new(Vec::new()));
    let collected = events.clone();
    (
        ModelSetupService::new(
            Locations {
                bundle_resources: root.join("Resources"),
                bundle_executables: executables,
                support: root.join("Madi"),
            },
            48 << 30,
            None,
            |bytes| bytes.to_string(),
            move |snapshot| collected.lock().unwrap().push(snapshot),
        ),
        events,
    )
}

fn fixture(asset: RemoteAsset, url: String) -> (RemoteAsset, String) {
    (
        RemoteAsset {
            size_bytes: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ..asset
        },
        url,
    )
}

async fn configure(service: &ModelSetupService, required: String, translation: String) {
    let mut inner = service.inner.lock().await;
    inner.downloader = Some(Downloader::fixture_client());
    inner.fixtures = Some([
        fixture(TRANSCRIPTION, required),
        fixture(inner.state.variant.asset(), translation),
    ]);
}

// Real loopback HTTP, with a release barrier for cancel/continue/quit races.
fn server(body: &'static [u8], slow: bool) -> (String, mpsc::Sender<()>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let address = listener.local_addr().unwrap();
    let (release, wait) = mpsc::channel();
    let worker = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline, "fixture request never arrived");
                    thread::sleep(Duration::from_millis(2));
                }
                Err(error) => panic!("{error}"),
            }
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            stream.read_exact(&mut byte).unwrap();
            request.push(byte[0]);
            assert!(request.len() < 16384);
        }
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .unwrap();
        stream.write_all(&body[..1]).unwrap();
        stream.flush().unwrap();
        if slow {
            let _ = wait.recv_timeout(Duration::from_secs(5));
        }
        let _ = stream.write_all(&body[1..]);
    });
    (format!("http://{address}/model"), release, worker)
}

async fn until(
    service: &ModelSetupService,
    condition: impl Fn(&ModelSnapshot) -> bool,
) -> ModelSnapshot {
    let result = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let state = service.snapshot().await;
            if condition(&state) {
                return state;
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await;
    match result {
        Ok(snapshot) => snapshot,
        Err(error) => panic!("{error}: {:?}", service.snapshot().await),
    }
}
fn receiving(state: &DownloadState) -> bool {
    matches!(state, DownloadState::Downloading(p) if *p > 0.0)
}
fn no_partial(root: &Path) {
    for asset in [TRANSCRIPTION, TranslationVariant::Quality4B.asset()] {
        assert!(
            !root
                .join("Madi/.madi-downloads")
                .join(format!("{}.partial", asset.name))
                .exists()
        );
    }
}

#[tokio::test]
async fn initialization_and_unselected_retry_are_read_only_and_existing_installs_enter() {
    let root = tempfile::tempdir().unwrap();
    let (empty, _) = service(root.path(), false);
    let snapshot = empty.command(ModelSetupCommand::Retry).await.unwrap();
    assert_eq!(snapshot.state.required, DownloadState::Idle);
    assert!(!snapshot.can_enter_app);
    assert!(!root.path().join("Madi").exists());
    assert!(empty.inner.lock().await.downloader.is_none());
    std::fs::create_dir(root.path().join("Madi")).unwrap();
    let model = std::fs::File::create(root.path().join("Madi").join(TRANSCRIPTION.name)).unwrap();
    model.set_len(TRANSCRIPTION.size_bytes).unwrap();
    drop(model); // Sparse size-only launch fixture, never claimed hash-valid.
    let (existing, _) = service(root.path(), true);
    let snapshot = existing.snapshot().await;
    assert!(snapshot.can_enter_app);
    assert_eq!(snapshot.state.choice, None);
    assert_eq!(snapshot.transcription_download_size, "0");
    assert!(existing.inner.lock().await.downloader.is_none());
    existing.shutdown().await.unwrap();
    empty.shutdown().await.unwrap();
}

#[tokio::test]
async fn recommended_cancel_retry_serializes_both_jobs_and_rejects_late_results() {
    let root = tempfile::tempdir().unwrap();
    let (service, events) = service(root.path(), true);
    let (a, release_a, server_a) = server(b"abc", true);
    let (b, release_b, server_b) = server(b"abc", true);
    configure(&service, a, b).await;
    service
        .command(ModelSetupCommand::Start(ModelSetupChoice::Recommended))
        .await
        .unwrap();
    until(&service, |s| {
        receiving(&s.state.required) && receiving(&s.state.translation)
    })
    .await;
    let generations = service.inner.lock().await.generations;
    service
        .command(ModelSetupCommand::Start(
            ModelSetupChoice::TranscriptionOnly,
        ))
        .await
        .unwrap();
    assert_eq!(service.inner.lock().await.generations, generations);
    let cancelled = service.command(ModelSetupCommand::Cancel).await.unwrap();
    assert_eq!(cancelled.state.required, DownloadState::Cancelled);
    assert_eq!(cancelled.state.translation, DownloadState::Idle);
    assert!(cancelled.has_retryable_download);
    no_partial(root.path());
    let (a, _, retry_a) = server(b"abc", false);
    let (b, _, retry_b) = server(b"abc", false);
    configure(&service, a, b).await;
    service.command(ModelSetupCommand::Retry).await.unwrap();
    // The old servers finish after the new tasks start, exercising late work.
    release_a.send(()).unwrap();
    release_b.send(()).unwrap();
    let complete = until(&service, |s| s.can_enter_app).await;
    assert_eq!(complete.state.required, DownloadState::Ready);
    assert_eq!(complete.state.translation, DownloadState::Ready);
    for worker in [server_a, server_b, retry_a, retry_b] {
        worker.join().unwrap();
    }
    service.shutdown().await.unwrap();
    no_partial(root.path());
    for asset in [TRANSCRIPTION, TranslationVariant::Quality4B.asset()] {
        assert_eq!(
            std::fs::read(root.path().join("Madi").join(asset.name)).unwrap(),
            b"abc"
        );
    }
    let history = events.lock().unwrap();
    assert!(
        history
            .windows(2)
            .all(|pair| pair[0].state.revision <= pair[1].state.revision)
    );
    assert!(
        history
            .iter()
            .filter(|s| s.state.revision > cancelled.state.revision)
            .all(|s| s.state.required != DownloadState::Cancelled)
    );
}

#[tokio::test]
async fn continue_enters_with_whisper_and_keeps_translation_transfer_alive() {
    let root = tempfile::tempdir().unwrap();
    let (service, _) = service(root.path(), true);
    let (a, _, server_a) = server(b"abc", false);
    let (b, release, server_b) = server(b"abc", true);
    configure(&service, a, b).await;
    service
        .command(ModelSetupCommand::Start(ModelSetupChoice::Recommended))
        .await
        .unwrap();
    let waiting = until(&service, |s| {
        s.can_continue_transcription && receiving(&s.state.translation)
    })
    .await;
    assert!(!waiting.can_enter_app);
    let continued = service
        .command(ModelSetupCommand::ContinueTranscription)
        .await
        .unwrap();
    assert!(continued.can_enter_app);
    assert_eq!(
        continued.state.choice,
        Some(ModelSetupChoice::TranscriptionOnly)
    );
    assert!(receiving(&continued.state.translation));
    release.send(()).unwrap();
    until(&service, |s| s.state.translation == DownloadState::Ready).await;
    server_a.join().unwrap();
    server_b.join().unwrap();
    service.shutdown().await.unwrap();
    no_partial(root.path());
}

#[tokio::test]
async fn corrupt_download_can_retry_and_shutdown_joins_transfer_before_returning() {
    let root = tempfile::tempdir().unwrap();
    let (service, _) = service(root.path(), false);
    let (url, _, failed_server) = server(b"bad", false);
    configure(
        &service,
        url,
        "http://127.0.0.1:1/must-not-be-requested".into(),
    )
    .await;
    // An absent DNA engine suppresses its task even for a native recommended intent.
    service
        .command(ModelSetupCommand::Start(ModelSetupChoice::Recommended))
        .await
        .unwrap();
    let failed = until(&service, |s| {
        matches!(s.state.required, DownloadState::Failed(_))
    })
    .await;
    assert!(failed.has_retryable_download);
    assert_eq!(failed.state.translation, DownloadState::Idle);
    assert!(service.inner.lock().await.jobs[1].is_none());
    failed_server.join().unwrap();
    let (url, release, retry_server) = server(b"abc", true);
    configure(
        &service,
        url,
        "http://127.0.0.1:1/must-not-be-requested".into(),
    )
    .await;
    service.command(ModelSetupCommand::Retry).await.unwrap();
    until(&service, |s| receiving(&s.state.required)).await;
    service.shutdown().await.unwrap();
    no_partial(root.path());
    assert!(!root.path().join("Madi").join(TRANSCRIPTION.name).exists());
    assert!(service.command(ModelSetupCommand::Retry).await.is_err());
    release.send(()).unwrap();
    retry_server.join().unwrap();
}
