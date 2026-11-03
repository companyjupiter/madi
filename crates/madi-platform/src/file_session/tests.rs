use super::*;
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::time::{sleep, timeout};

// These are real child processes with synthetic audio, not inference claims.
// Python occupies the decoder and engine executable slots on both CI platforms.
pub(crate) fn fixture(
    decoder_extra: &str,
    engine_extra: &str,
) -> (tempfile::TempDir, Configuration, PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let python_name = std::env::var_os("MADI_TEST_PYTHON").unwrap_or_else(|| {
        if cfg!(windows) {
            "python".into()
        } else {
            "python3".into()
        }
    });
    let output = std::process::Command::new(python_name)
        .args([
            "-c",
            "import sys;sys.stdout.reconfigure(encoding='utf-8');print(sys.executable)",
        ])
        .output()
        .unwrap();
    assert!(output.status.success());
    let python = PathBuf::from(String::from_utf8(output.stdout).unwrap().trim());
    let decoder = root.path().join("original decoder fixture.py");
    std::fs::write(&decoder, format!(r#"import json,os,pathlib,sys,time,wave
sys.stdout.reconfigure(encoding='utf-8')
root=pathlib.Path(__file__).parent
scratch=pathlib.Path(sys.argv[1])
{decoder_extra}
path=scratch/'prepared.wav'
with wave.open(str(path),'wb') as wav:
    wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(16000);wav.writeframes(b'\x01\x00'*16000)
print(json.dumps({{'status':'ok','path':str(path)}}),flush=True)
"#)).unwrap();
    let model = root.path().join("engine fixture.py");
    std::fs::write(
        &model,
        format!(
            r#"import json,os,pathlib,signal,subprocess,sys,time
# The real engine writes UTF-8 bytes regardless of the host console code page.
# Python's Windows pipe default can neither encode the arrow nor preserve conf
# markers as UTF-8; give the fixture the engine's actual wire contract.
sys.stdout.reconfigure(encoding='utf-8')
root=pathlib.Path(__file__).parent
wav=pathlib.Path(sys.argv[1])
assert wav.exists() and wav.read_bytes()[:4]==b'RIFF'
assert sys.stdin.buffer.read()==b''
(root/'engine-started').write_text(str(wav))
{engine_extra}
"#
        ),
    )
    .unwrap();
    let configuration = Configuration {
        resources: Resources {
            executable: python.clone(),
            model,
            bpe: root.path().join("unused.bpe"),
            assets: root.path().to_owned(),
        },
        decoder: python,
        scratch_parent: root.path().to_owned(),
    };
    (root, configuration, decoder)
}

const SUCCESS: &str = r#"
with open(os.environ['EVENTS_FILE'],'w',encoding='utf-8') as out:
    out.write(json.dumps({'t':'seg','idx':0,'t0':0,'t1':1,'text':'kept tail 한글'})+'\n')
print('<<SEG_END>>',flush=True)
print('<<FLUSH_END>>',flush=True)
"#;

pub(crate) fn scratch_count(root: &Path) -> usize {
    std::fs::read_dir(root)
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("madi-"))
        .count()
}

pub(crate) async fn marker(path: &Path) {
    timeout(Duration::from_secs(8), async {
        while !path.exists() {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
}

async fn terminal(session: &mut FileSession, run: RunId) -> Vec<Update> {
    let mut updates = Vec::new();
    loop {
        let update = timeout(Duration::from_secs(8), session.next())
            .await
            .unwrap()
            .expect("session ended early");
        let done = update.run == run
            && matches!(
                update.kind,
                UpdateKind::Finished | UpdateKind::Failed | UpdateKind::Fault(_)
            );
        updates.push(update);
        if done {
            return updates;
        }
    }
}

#[tokio::test]
async fn completes_after_json_tail_and_cleanup_then_can_start_again() {
    let (root, configuration, original) = fixture("", SUCCESS);
    let original_bytes = std::fs::read(&original).unwrap();
    let mut session = FileSession::new(configuration).unwrap();
    let first = session
        .start(original.clone(), FileSettings::default())
        .await
        .unwrap()
        .unwrap();
    let updates = terminal(&mut session, first).await;
    assert!(matches!(
        updates.first().unwrap().kind,
        UpdateKind::Phase(Phase::Processing)
    ));
    let segment = updates.iter().position(|event| matches!(&event.kind, UpdateKind::Output(Output::Structured(madi_protocol::structured::Event::Segment(segment))) if segment.text == "kept tail 한글")).unwrap();
    let done = updates
        .iter()
        .position(|event| event.kind == UpdateKind::Phase(Phase::Done))
        .unwrap();
    assert!(segment < done && done < updates.len() - 1);
    assert_eq!(updates.last().unwrap().kind, UpdateKind::Finished);
    assert_eq!(scratch_count(root.path()), 0);
    let second = session
        .start(original.clone(), FileSettings::default())
        .await
        .unwrap()
        .unwrap();
    assert_ne!(first, second);
    assert!(
        terminal(&mut session, second)
            .await
            .iter()
            .all(|event| event.run == second)
    );
    session.shutdown().await.unwrap();
    assert_eq!(scratch_count(root.path()), 0);
    assert_eq!(std::fs::read(original).unwrap(), original_bytes);
}

#[tokio::test]
async fn reset_reaps_engine_before_removing_wav_and_isolates_the_next_run() {
    let engine = format!(
        r#"
if not (root/'finish-next').exists():
    def stopped(signum, frame):
        (root/'wav-at-termination').write_text(str(wav.exists()))
        sys.exit(0)
    signal.signal(signal.SIGTERM,stopped)
    (root/'handler-ready').write_text('ready')
    print('holding',flush=True)
    while True: time.sleep(.01)
{SUCCESS}
"#
    );
    let (root, configuration, original) = fixture("", &engine);
    let mut session = FileSession::new(configuration).unwrap();
    let first = session
        .start(original.clone(), FileSettings::default())
        .await
        .unwrap()
        .unwrap();
    marker(&root.path().join("handler-ready")).await;
    assert!(
        session
            .start(original.clone(), FileSettings::default())
            .await
            .unwrap()
            .is_none()
    );
    let wav = PathBuf::from(std::fs::read_to_string(root.path().join("engine-started")).unwrap());
    assert!(wav.exists());
    session.reset().await.unwrap();
    assert!(!wav.exists());
    assert_eq!(scratch_count(root.path()), 0);
    #[cfg(unix)]
    assert_eq!(
        std::fs::read_to_string(root.path().join("wav-at-termination")).unwrap(),
        "True"
    );
    std::fs::write(root.path().join("finish-next"), b"go").unwrap();
    let second = session
        .start(original.clone(), FileSettings::default())
        .await
        .unwrap()
        .unwrap();
    let updates = terminal(&mut session, second).await;
    assert_ne!(first, second);
    assert!(!updates.iter().any(|event| event.run == first
        && matches!(event.kind, UpdateKind::Finished | UpdateKind::Failed)));
    let new_start = updates
        .iter()
        .position(|event| event.run == second)
        .unwrap();
    assert!(updates[new_start..].iter().all(|event| event.run == second));
    session.shutdown().await.unwrap();
    assert!(original.exists());
}

#[tokio::test]
async fn preparation_cancel_and_owner_drop_reap_before_returning_resources() {
    let (root, configuration, original) = fixture(
        "(root/'decode-started').write_text('started')\nwhile not (root/'decode-go').exists(): time.sleep(.01)",
        SUCCESS,
    );
    let session = FileSession::new(configuration).unwrap();
    session
        .start(original.clone(), FileSettings::default())
        .await
        .unwrap()
        .unwrap();
    marker(&root.path().join("decode-started")).await;
    session.reset().await.unwrap();
    assert_eq!(scratch_count(root.path()), 0);
    assert!(!root.path().join("engine-started").exists());
    std::fs::remove_file(root.path().join("decode-started")).unwrap();
    session
        .start(original.clone(), FileSettings::default())
        .await
        .unwrap()
        .unwrap();
    marker(&root.path().join("decode-started")).await;
    drop(session);
    timeout(Duration::from_secs(8), async {
        while scratch_count(root.path()) != 0 {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert!(original.exists());
    assert!(!root.path().join("engine-started").exists());
}

#[tokio::test]
async fn dropping_running_owner_keeps_the_wav_until_child_teardown() {
    let engine = r#"
def stopped(signum, frame):
    (root/'wav-at-termination').write_text(str(wav.exists()))
    sys.exit(0)
signal.signal(signal.SIGTERM,stopped)
(root/'handler-ready').write_text('ready')
while True: time.sleep(.01)
"#;
    let (root, configuration, original) = fixture("", engine);
    let session = FileSession::new(configuration).unwrap();
    session
        .start(original.clone(), FileSettings::default())
        .await
        .unwrap()
        .unwrap();
    marker(&root.path().join("handler-ready")).await;
    let wav = PathBuf::from(std::fs::read_to_string(root.path().join("engine-started")).unwrap());
    assert!(wav.exists());
    drop(session);
    timeout(Duration::from_secs(8), async {
        while scratch_count(root.path()) != 0 {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    #[cfg(unix)]
    assert_eq!(
        std::fs::read_to_string(root.path().join("wav-at-termination")).unwrap(),
        "True"
    );
    assert!(!wav.exists());
    assert!(original.exists());
}

#[tokio::test]
async fn spawn_failure_and_nonzero_exit_fail_once_without_deleting_original() {
    for missing in [true, false] {
        let (root, mut configuration, original) = fixture("", "sys.exit(7)");
        if missing {
            configuration.resources.executable = root.path().join("absent-engine");
        }
        let mut session = FileSession::new(configuration).unwrap();
        let run = session
            .start(original.clone(), FileSettings::default())
            .await
            .unwrap()
            .unwrap();
        let updates = terminal(&mut session, run).await;
        assert_eq!(
            updates
                .iter()
                .filter(|event| event.kind == UpdateKind::Failed)
                .count(),
            1
        );
        assert!(
            updates
                .iter()
                .any(|event| matches!(event.kind, UpdateKind::Phase(Phase::Error(_))))
        );
        assert!(
            !updates
                .iter()
                .any(|event| event.kind == UpdateKind::Finished)
        );
        assert_eq!(scratch_count(root.path()), 0);
        assert!(original.exists());
        session.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn teardown_drain_failure_never_reports_success() {
    let engine = "subprocess.Popen([sys.executable,'-c',\"import pathlib,time;time.sleep(4);pathlib.Path('descendant-ended').write_text('done')\"])\nprint('<<FLUSH_END>>',flush=True)";
    let (root, configuration, original) = fixture("", engine);
    let mut session = FileSession::new(configuration).unwrap();
    let run = session
        .start(original.clone(), FileSettings::default())
        .await
        .unwrap()
        .unwrap();
    let updates = terminal(&mut session, run).await;
    assert!(matches!(updates.last().unwrap().kind, UpdateKind::Fault(_)));
    assert!(
        !updates
            .iter()
            .any(|event| event.kind == UpdateKind::Finished)
    );
    assert!(session.shutdown().await.is_err());
    assert_eq!(scratch_count(root.path()), 0);
    assert!(original.exists());
    // Let the deliberately inherited-pipe fixture exit before deleting its cwd
    // (especially on Windows, where an open cwd can prevent TempDir removal).
    marker(&root.path().join("descendant-ended")).await;
}
