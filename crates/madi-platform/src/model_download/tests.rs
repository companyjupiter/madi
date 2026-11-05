use super::*;
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::mpsc,
    thread,
};

const ASSET: RemoteAsset = RemoteAsset {
    name: "model.bin",
    url: "https://example.invalid/model.bin",
    size_bytes: 3,
    sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    approx_runtime_memory_gb: None,
};

fn client() -> Downloader {
    Downloader {
        client: reqwest::Client::builder()
            .no_proxy()
            .read_timeout(Duration::from_secs(3))
            .build()
            .unwrap(),
    }
}

fn serve_fixture(
    body: &'static [u8],
    slow: bool,
    content_length: bool,
) -> (String, mpsc::Sender<()>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let address = listener.local_addr().unwrap();
    let (release, wait) = mpsc::channel();
    let worker = thread::spawn(move || {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    assert!(
                        std::time::Instant::now() < deadline,
                        "fixture request never arrived"
                    );
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
            assert!(request.len() < 16 * 1024);
        }
        let length = if content_length {
            format!("Content-Length: {}\r\n", body.len())
        } else {
            String::new()
        };
        write!(
            stream,
            "HTTP/1.1 200 OK\r\n{length}Connection: close\r\n\r\n"
        )
        .unwrap();
        if slow {
            stream.write_all(&body[..1]).unwrap();
            stream.flush().unwrap();
            let _ = wait.recv_timeout(Duration::from_secs(5));
            let _ = stream.write_all(&body[1..]);
        } else {
            stream.write_all(body).unwrap();
        }
    });
    (format!("http://{address}/model.bin"), release, worker)
}

async fn finish(task: &mut DownloadTask) -> DownloadState {
    tokio::time::timeout(Duration::from_secs(10), task.wait())
        .await
        .unwrap()
        .unwrap()
}

async fn first_byte(task: &DownloadTask) {
    let mut updates = task.subscribe();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if matches!(*updates.borrow(), DownloadState::Downloading(progress) if progress > 0.0) {
                break;
            }
            updates.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
}

fn no_partial(root: &Path) {
    assert!(!root.join(".madi-downloads/model.bin.partial").exists());
}

#[tokio::test]
async fn installs_only_verified_bytes_and_preserves_previous_model_on_corruption() {
    let root = tempfile::tempdir().unwrap();
    let support = root.path().join("Madi");
    let client = client();
    assert!(!support.exists());
    for (body, expected) in [
        (b"abc".as_slice(), true),
        (b"abd".as_slice(), false),
        (b"abcd".as_slice(), false),
        (b"ab".as_slice(), false),
    ] {
        let (url, _release, server) = serve_fixture(body, false, false);
        let mut job = client.start_url(ASSET, support.clone(), url);
        let outcome = finish(&mut job).await;
        assert_eq!(outcome == DownloadState::Ready, expected, "{outcome:?}");
        if !expected {
            assert_eq!(
                outcome,
                DownloadState::Failed("SHA-256 mismatch — re-download".into())
            );
        }
        server.join().unwrap();
        assert_eq!(std::fs::read(support.join(ASSET.name)).unwrap(), b"abc");
        no_partial(&support);
    }
}

#[tokio::test]
async fn cancellation_closes_the_file_and_lock_before_retry_and_old_job_cannot_publish() {
    let root = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join(ASSET.name), b"keep existing").unwrap();
    let client = client();
    let (url, release, server) = serve_fixture(b"abc", true, true);
    let mut job = client.start_url(ASSET, root.path().to_owned(), url.clone());
    first_byte(&job).await;
    // Another app instance/handle cannot truncate the in-flight partial or
    // issue a second request while this asset's OS lock is held.
    let mut duplicate = client.start_url(ASSET, root.path().to_owned(), url);
    assert!(
        matches!(finish(&mut duplicate).await, DownloadState::Failed(message) if message.contains("lock"))
    );
    assert_eq!(
        job.cancel_and_wait().await.unwrap(),
        DownloadState::Cancelled
    );
    no_partial(root.path());
    assert_eq!(
        std::fs::read(root.path().join(ASSET.name)).unwrap(),
        b"keep existing"
    );
    release.send(()).unwrap();
    server.join().unwrap();
    let (url, _release, server) = serve_fixture(b"abc", false, true);
    let mut retry = client.start_url(ASSET, root.path().to_owned(), url);
    assert_eq!(finish(&mut retry).await, DownloadState::Ready);
    server.join().unwrap();
    assert_eq!(job.state(), DownloadState::Cancelled);
    assert_eq!(std::fs::read(root.path().join(ASSET.name)).unwrap(), b"abc");
    no_partial(root.path());
}

#[tokio::test]
async fn abandoned_wait_and_drop_keep_owned_cleanup_alive() {
    let root = tempfile::tempdir().unwrap();
    let (url, release, server) = serve_fixture(b"abc", true, true);
    let mut job = client().start_url(ASSET, root.path().to_owned(), url);
    first_byte(&job).await;
    assert!(
        tokio::time::timeout(Duration::from_millis(10), job.wait())
            .await
            .is_err()
    );
    let mut state = job.subscribe();
    drop(job);
    tokio::time::timeout(Duration::from_secs(5), async {
        while *state.borrow() != DownloadState::Cancelled {
            state.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
    no_partial(root.path());
    assert!(!root.path().join(ASSET.name).exists());
    release.send(()).unwrap();
    server.join().unwrap();
}

#[test]
fn stage_recovers_its_interrupted_partial_and_rejects_links_without_touching_targets() {
    let root = tempfile::tempdir().unwrap();
    let staging = root.path().join(".madi-downloads");
    std::fs::create_dir(&staging).unwrap();
    let partial = staging.join("model.bin.partial");
    std::fs::write(&partial, b"interrupted previous transfer").unwrap();
    let stage = Stage::open(root.path(), ASSET.name).unwrap();
    assert_eq!(std::fs::metadata(&partial).unwrap().len(), 0);
    stage.cleanup().unwrap();
    let original = root.path().join("original.bin");
    std::fs::write(&original, b"must not change").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&original, &partial).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_file(&original, &partial).unwrap();
    assert!(Stage::open(root.path(), ASSET.name).is_err());
    assert_eq!(std::fs::read(&original).unwrap(), b"must not change");
    assert!(partial.is_symlink());
}

#[cfg(unix)]
#[test]
fn completion_explicitly_unlocks_even_with_an_inherited_open_file_description() {
    let root = tempfile::tempdir().unwrap();
    let stage = Stage::open(root.path(), ASSET.name).unwrap();
    // dup shares the same open-file description, as an inherited fork handle
    // does before CLOEXEC closes it. Keep it alive across cleanup and retry.
    let inherited = stage._lock.0.try_clone().unwrap();
    stage.cleanup().unwrap();
    let retry = Stage::open(root.path(), ASSET.name).expect("completion must release the lock");
    retry.cleanup().unwrap();
    drop(inherited);
}
