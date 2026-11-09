use super::*;
use crate::capture_pipeline::{CapturePipeline, Event};
use madi_core::capture_stream;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::time::{sleep, timeout};
const ENGINE: &str = r#"
import os,sys,pathlib,json,wave,hashlib,signal,time
root=pathlib.Path(sys.argv[1]);clip=pathlib.Path(sys.argv[2]);mode=(root/'mode').read_text(encoding='utf-8')
with wave.open(str(clip),'rb') as w:frames=w.getnframes()
record={'pid':os.getpid(),'clip':str(clip),'frames':frames,'sha256':hashlib.sha256(clip.read_bytes()).hexdigest(),'DIAR':os.environ.get('DIAR'),'AUDIO_CTX':os.environ.get('AUDIO_CTX'),'WHISPER_LANG_ID':os.environ.get('WHISPER_LANG_ID'),'STREAM':os.environ.get('STREAM'),'APP_FILE':os.environ.get('APP_FILE')}
(root/'record.json').write_text(json.dumps(record),encoding='utf-8')
if mode=='HOLD':
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 (root/'holding').write_text('ready',encoding='utf-8')
 while True:time.sleep(0.005)
if mode=='EXIT':sys.exit(7)
if mode=='INVALID':os.write(1,b'=== TRANSCRIPTION ===\nvalid then \xff\n');sys.exit(0)
if mode=='EMPTY':os.write(1,b'=== TRANSCRIPTION ===\n');sys.exit(0)
os.write(1,'noise\n=== TRANSCRIPTION ===\n\n  corrected  \n Korean text \n\nignored\n'.encode('utf-8'))
"#;
fn config(root: &Path, mode: &str) -> Configuration {
    std::fs::write(root.join("mode"), mode).unwrap();
    let mut c = Configuration::new(
        Resources {
            executable: std::env::var_os("MADI_TEST_PYTHON")
                .unwrap_or_else(|| {
                    if cfg!(windows) {
                        "python".into()
                    } else {
                        "python3".into()
                    }
                })
                .into(),
            model: root.to_owned(),
            bpe: root.join("BPE"),
            assets: root.to_owned(),
        },
        50264,
    );
    c.arguments = vec!["-u".into(), "-c".into(), ENGINE.into()];
    c
}
fn source(root: &Path) -> OwnedWav {
    let mut pipeline =
        CapturePipeline::new(capture_stream::Configuration::default(), root).unwrap();
    pipeline.start();
    pipeline.ingest(&vec![2000; 48000], true);
    pipeline
        .stop()
        .into_iter()
        .find_map(|e| {
            if let Event::Segment { wav, .. } = e {
                Some(wav)
            } else {
                None
            }
        })
        .unwrap()
}
fn record(root: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(root.join("record.json")).unwrap()).unwrap()
}
async fn file_ready(path: &Path) {
    timeout(Duration::from_secs(5), async {
        while !path.exists() {
            sleep(Duration::from_millis(5)).await
        }
    })
    .await
    .unwrap();
}
fn reaped(record: &Value) {
    #[cfg(unix)]
    assert_ne!(
        unsafe { libc::kill(record["pid"].as_i64().unwrap() as libc::pid_t, 0) },
        0
    );
    assert!(!Path::new(record["clip"].as_str().unwrap()).exists());
}
#[tokio::test]
async fn forced_language_uses_a_padded_owned_clip_and_preserves_input() {
    let root = tempfile::tempdir().unwrap();
    let wav = source(root.path());
    let bytes = std::fs::read(wav.path()).unwrap();
    let expected = audio::crop(&bytes, 0.5, 0.7, 0.2).unwrap();
    let mut task =
        CorrectionTask::start(config(root.path(), "SUCCESS"), wav.clone(), 0.5, 0.7).unwrap();
    assert_eq!(
        task.wait().await.unwrap().as_deref(),
        Some("corrected Korean text")
    );
    let r = record(root.path());
    assert_eq!(r["frames"], 9600);
    assert_eq!(r["sha256"], format!("{:x}", Sha256::digest(expected)));
    assert_eq!(r["DIAR"], "0");
    assert_eq!(r["AUDIO_CTX"], "auto");
    assert_eq!(r["WHISPER_LANG_ID"], "50264");
    assert!(r["STREAM"].is_null() && r["APP_FILE"].is_null());
    assert_eq!(std::fs::read(wav.path()).unwrap(), bytes);
    reaped(&r);
    let dir = wav.directory().to_owned();
    drop(wav);
    assert!(!dir.exists());
}
#[tokio::test]
async fn failed_exit_invalid_output_and_empty_crop_never_invent_corrected_text() {
    let root = tempfile::tempdir().unwrap();
    let wav = source(root.path());
    let bytes = std::fs::read(wav.path()).unwrap();
    let inventory = || -> std::collections::BTreeSet<_> {
        std::fs::read_dir(wav.directory())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect()
    };
    let original_files = inventory();
    for mode in ["EXIT", "INVALID", "EMPTY"] {
        let mut task =
            CorrectionTask::start(config(root.path(), mode), wav.clone(), 0.1, 0.2).unwrap();
        let result = task.wait().await.unwrap();
        assert_eq!(
            result,
            if mode == "EMPTY" {
                Some(String::new())
            } else {
                None
            }
        );
        reaped(&record(root.path()));
    }
    let mut task =
        CorrectionTask::start(config(root.path(), "SUCCESS"), wav.clone(), 100., 101.).unwrap();
    assert_eq!(
        task.wait().await.unwrap_err().kind(),
        io::ErrorKind::InvalidData
    );
    assert_eq!(std::fs::read(wav.path()).unwrap(), bytes);
    assert_eq!(inventory(), original_files);
}
#[tokio::test]
async fn cancelled_wait_timeout_and_drop_keep_cleanup_owned_until_child_reaping() {
    for action in ["cancel", "timeout", "drop"] {
        let root = tempfile::tempdir().unwrap();
        let wav = source(root.path());
        let dir = wav.directory().to_owned();
        let mut c = config(root.path(), "HOLD");
        if action == "timeout" {
            c.deadline = Duration::from_millis(200)
        }
        let mut task = CorrectionTask::start(c, wav, 0.1, 0.2).unwrap();
        file_ready(&root.path().join("holding")).await;
        let r = record(root.path());
        assert!(dir.exists());
        if action == "drop" {
            drop(task);
            timeout(Duration::from_secs(5), async {
                while dir.exists() {
                    sleep(Duration::from_millis(5)).await
                }
            })
            .await
            .unwrap();
        } else {
            if action == "cancel" {
                assert!(
                    timeout(Duration::from_millis(20), task.wait())
                        .await
                        .is_err()
                );
                task.cancel();
            }
            assert!(
                timeout(Duration::from_secs(5), task.wait())
                    .await
                    .unwrap()
                    .unwrap()
                    .is_none()
            );
            assert!(!dir.exists());
        }
        reaped(&r);
    }
}
