use super::*;
use crate::file_session::tests::{fixture, marker, scratch_count};
use std::path::Path;
use tokio::time::{sleep, timeout};

const WORDS: &str = r#"
print('[8] audio: fixture → 2 chunks',flush=True)
print('[perf] chunk 1',flush=True)
print('SPK 0 2 5 1',flush=True)
print('=== WORD TIMESTAMPS ===',flush=True)
print('[0.0s-0.4s] Hello «conf 0.99»',flush=True)
print('[0.5s-0.9s] world. «conf 0.98»',flush=True)
print('<<SEG_END>>',flush=True)
"#;
const HOLD: &str = r#"
def stopped(signum, frame):
    (root/'wav-at-termination').write_text(str(wav.exists()))
    sys.exit(0)
signal.signal(signal.SIGTERM,stopped)
(root/'handler-ready').write_text('ready')
while not (root/'finish').exists(): time.sleep(.01)
print('<<FLUSH_END>>',flush=True)
"#;

async fn state_when(workflow: &FileWorkflow, test: impl Fn(&Snapshot) -> bool) -> Snapshot {
    timeout(Duration::from_secs(10), async {
        let mut changes = workflow.owner.snapshot.clone();
        loop {
            let state = changes.borrow_and_update().clone();
            if test(&state) {
                return state;
            }
            changes
                .changed()
                .await
                .expect("workflow closed before expected state");
        }
    })
    .await
    .expect("expected workflow state did not arrive")
}
async fn cleaned(root: &Path) {
    timeout(Duration::from_secs(8), async {
        while scratch_count(root) != 0 {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn publishes_stream_edits_and_speaker_fixes_then_finalizes_after_cleanup() {
    let engine = format!(
        r#"{WORDS}
while not (root/'fix').exists(): time.sleep(.01)
print('SPKFIX 0 3 5 1',flush=True)
print('SPKNAME 3 자동 이름',flush=True)
print('[perf] chunk 2',flush=True)
print('[perf] chunk 1',flush=True)
{HOLD}"#
    );
    let (root, configuration, original) = fixture("", &engine);
    let bytes = std::fs::read(&original).unwrap();
    let events = Arc::new(std::sync::Mutex::new(Vec::new()));
    let recorded = events.clone();
    let workflow = FileWorkflow::new(configuration, move |value| {
        recorded.lock().unwrap().push(value)
    })
    .unwrap();
    let started = workflow
        .start(original.clone(), FileSettings::default(), None)
        .await
        .unwrap();
    assert_eq!(started.phase, ViewPhase::Processing);
    let streamed = state_when(&workflow, |s| s.lines.len() == 1 && s.chunks_done == 1).await;
    assert_eq!(streamed.lines[0].text, "Hello world.");
    assert_eq!(streamed.lines[0].line.speaker, 2);
    assert_eq!(streamed.chunks_total, 2);
    let id = streamed.lines[0].line.id.to_string();
    workflow
        .edit(
            started.generation,
            Edit::Line {
                id: id.clone(),
                text: "Edited words.".into(),
            },
        )
        .await
        .unwrap();
    let edited = state_when(&workflow, |s| {
        s.lines.first().is_some_and(|l| l.text == "Edited words.")
    })
    .await;
    assert_eq!(edited.lines[0].line.id.to_string(), id);
    workflow
        .edit(
            started.generation,
            Edit::Translation {
                id: id.clone(),
                language: "ko".into(),
                text: "수정한 문장.".into(),
            },
        )
        .await
        .unwrap();
    state_when(&workflow, |s| {
        s.lines[0]
            .line
            .translations
            .get("ko")
            .is_some_and(|t| t == "수정한 문장.")
    })
    .await;
    std::fs::write(root.path().join("fix"), b"go").unwrap();
    let fixed = state_when(&workflow, |s| {
        s.lines[0].line.speaker == 3 && s.chunks_done == 2
    })
    .await;
    assert_eq!(fixed.lines[0].line.id.to_string(), id);
    assert_eq!(fixed.lines[0].text, "Edited words.");
    assert_eq!(fixed.speaker_names.get(&3).unwrap(), "자동 이름");
    workflow
        .edit(
            started.generation,
            Edit::SpeakerName {
                speaker: 3,
                name: "\u{200b} 이름 \u{200b}".into(),
            },
        )
        .await
        .unwrap();
    assert_eq!(workflow.snapshot().speaker_names.get(&3).unwrap(), "이름");
    marker(&root.path().join("handler-ready")).await;
    std::fs::write(root.path().join("finish"), b"go").unwrap();
    let done = state_when(&workflow, |s| s.phase == ViewPhase::Done).await;
    assert_eq!(done.lines[0].text, "Edited words.");
    assert_eq!(
        done.lines[0].line.translations.get("ko").unwrap(),
        "수정한 문장."
    );
    assert_eq!(
        scratch_count(root.path()),
        0,
        "Done must follow owned WAV cleanup"
    );
    workflow.shutdown().await.unwrap();
    assert_eq!(std::fs::read(original).unwrap(), bytes);
    let events = events.lock().unwrap();
    assert!(events.windows(2).all(|w| w[0].revision < w[1].revision));
    assert!(
        events
            .iter()
            .filter(|s| s.phase == ViewPhase::Done)
            .all(|s| s.lines[0].text == "Edited words.")
    );
}

#[tokio::test]
async fn cancel_reaps_child_duplicate_start_and_stale_generation_cannot_replace_session() {
    let (root, configuration, original) = fixture("", &format!("{WORDS}\n{HOLD}"));
    let workflow = FileWorkflow::new(configuration, |_| {}).unwrap();
    let first = workflow
        .start(original.clone(), FileSettings::default(), None)
        .await
        .unwrap();
    marker(&root.path().join("handler-ready")).await;
    let duplicate = workflow
        .start(
            original.clone(),
            FileSettings::default(),
            Some("must not replace active run".into()),
        )
        .await
        .unwrap();
    assert_eq!(first.generation, duplicate.generation);
    assert_eq!(duplicate.phase, ViewPhase::Processing);
    let idle = workflow.reset(first.generation).await.unwrap();
    assert_eq!(idle.phase, ViewPhase::Idle);
    assert!(idle.lines.is_empty());
    assert_eq!(scratch_count(root.path()), 0);
    #[cfg(unix)]
    assert_eq!(
        std::fs::read_to_string(root.path().join("wav-at-termination")).unwrap(),
        "True"
    );
    let next = workflow
        .start(original.clone(), FileSettings::default(), None)
        .await
        .unwrap();
    let lines = state_when(&workflow, |s| {
        s.generation == next.generation && !s.lines.is_empty()
    })
    .await;
    assert!(next.generation > first.generation);
    let stale = workflow.reset(first.generation).await.unwrap();
    assert_eq!(stale.generation, next.generation);
    assert_eq!(stale.phase, ViewPhase::Processing);
    workflow
        .edit(
            first.generation,
            Edit::Line {
                id: lines.lines[0].line.id.to_string(),
                text: "stale edit".into(),
            },
        )
        .await
        .unwrap();
    assert_eq!(workflow.snapshot().lines[0].text, "Hello world.");
    workflow.reset(next.generation).await.unwrap();
    workflow.shutdown().await.unwrap();
    assert_eq!(scratch_count(root.path()), 0);
    assert!(original.exists());
}

#[tokio::test]
async fn engine_failure_preserves_tail_and_retry_succeeds() {
    let (root, configuration, original) = fixture(
        "",
        &format!(
            "{WORDS}\nif not (root/'retry').exists(): sys.exit(7)\nprint('<<FLUSH_END>>',flush=True)"
        ),
    );
    let workflow = FileWorkflow::new(configuration, |_| {}).unwrap();
    workflow
        .start(original.clone(), FileSettings::default(), None)
        .await
        .unwrap();
    let failed = state_when(&workflow, |s| matches!(s.phase, ViewPhase::Error { .. })).await;
    assert!(matches!(&failed.phase, ViewPhase::Error { message } if message.contains("코드 7")));
    assert_eq!(failed.lines[0].text, "Hello world.");
    assert_eq!(scratch_count(root.path()), 0);
    std::fs::write(root.path().join("retry"), b"go").unwrap();
    let retried = workflow
        .start(original.clone(), FileSettings::default(), None)
        .await
        .unwrap();
    let done = state_when(&workflow, |s| s.phase == ViewPhase::Done).await;
    assert_eq!(done.generation, retried.generation);
    assert_ne!(done.lines[0].line.id, failed.lines[0].line.id);
    assert_eq!(done.lines[0].text, "Hello world.");
    workflow.shutdown().await.unwrap();
}

#[tokio::test]
async fn native_decode_reason_survives_and_admission_failure_preserves_existing_transcript() {
    let decoder = "if not (root/'decode-ok').exists():\n    print(json.dumps({'status':'error','domain':'AudioDecode','code':5,'reason':'오디오 트랙이 없습니다','message':'diagnostic'}),flush=True)\n    sys.exit(1)";
    let (root, configuration, original) = fixture(
        decoder,
        &format!("{WORDS}\nprint('<<FLUSH_END>>',flush=True)"),
    );
    let workflow = FileWorkflow::new(configuration, |_| {}).unwrap();
    workflow
        .start(original.clone(), FileSettings::default(), None)
        .await
        .unwrap();
    let failed = state_when(&workflow, |s| matches!(s.phase, ViewPhase::Error { .. })).await;
    assert!(
        matches!(failed.phase, ViewPhase::Error { message } if message == "'original decoder fixture.py' 을(를) 열 수 없습니다 — 오디오 트랙이 없습니다.")
    );
    assert_eq!(scratch_count(root.path()), 0);
    std::fs::write(root.path().join("decode-ok"), b"go").unwrap();
    workflow
        .start(original.clone(), FileSettings::default(), None)
        .await
        .unwrap();
    let done = state_when(&workflow, |s| s.phase == ViewPhase::Done).await;
    let refused = workflow
        .start(
            original.clone(),
            FileSettings::default(),
            Some("model unavailable".into()),
        )
        .await
        .unwrap();
    assert_eq!(refused.generation, done.generation);
    assert_eq!(refused.lines[0].line.id, done.lines[0].line.id);
    assert_eq!(refused.lines[0].text, "Hello world.");
    workflow.shutdown().await.unwrap();
}

#[tokio::test]
async fn dropped_owner_and_cancelled_shutdown_keep_cleanup_owned() {
    for drop_owner in [true, false] {
        let (root, configuration, original) = fixture(
            "(root/'decode-started').write_text('ready')\nwhile True: time.sleep(.01)",
            "",
        );
        let workflow = FileWorkflow::new(configuration, |_| {}).unwrap();
        workflow
            .start(original.clone(), FileSettings::default(), None)
            .await
            .unwrap();
        marker(&root.path().join("decode-started")).await;
        if drop_owner {
            drop(workflow);
        } else {
            let mut shutdown = Box::pin(workflow.shutdown());
            // Poll exactly once to send Shutdown and acquire the retained handle;
            // yielding early models cancellation of the caller's HTTP/IPC future.
            std::future::poll_fn(|context| {
                assert!(shutdown.as_mut().poll(context).is_pending());
                std::task::Poll::Ready(())
            })
            .await;
            drop(shutdown);
            assert!(workflow.owner.task.lock().await.is_some());
            workflow.shutdown().await.unwrap();
        }
        cleaned(root.path()).await;
        assert!(original.exists());
        assert!(!root.path().join("engine-started").exists());
    }
}

#[tokio::test]
async fn transport_fault_retires_executor_and_allows_retry() {
    let engine = format!(
        r#"{WORDS}
if not (root/'retry').exists():
    subprocess.Popen([sys.executable,'-c',"import pathlib,time;time.sleep(4);pathlib.Path('descendant-ended').write_text('done')"])
print('<<FLUSH_END>>',flush=True)
"#
    );
    let (root, configuration, original) = fixture("", &engine);
    let workflow = FileWorkflow::new(configuration, |_| {}).unwrap();
    workflow
        .start(original.clone(), FileSettings::default(), None)
        .await
        .unwrap();
    let failed = state_when(&workflow, |s| matches!(s.phase, ViewPhase::Error { .. })).await;
    assert_eq!(failed.lines[0].text, "Hello world.");
    assert_eq!(scratch_count(root.path()), 0);
    marker(&root.path().join("descendant-ended")).await;
    std::fs::write(root.path().join("retry"), b"go").unwrap();
    workflow
        .start(original.clone(), FileSettings::default(), None)
        .await
        .unwrap();
    let done = state_when(&workflow, |s| s.phase == ViewPhase::Done).await;
    assert_eq!(done.lines[0].text, "Hello world.");
    assert!(done.generation > failed.generation);
    workflow.shutdown().await.unwrap();
    assert_eq!(scratch_count(root.path()), 0);
}
