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
async fn archive_checkpoints_finish_and_reopen_keep_session_ownership() {
    let (root, configuration, original) = fixture("", &format!("{WORDS}\n{HOLD}"));
    let folder = root.path().join("archives");
    let workflow = FileWorkflow::with_archive(
        configuration,
        Some(ArchiveSettings {
            enabled: true,
            folder: folder.clone(),
        }),
        |_| {},
    )
    .unwrap();
    let started = workflow
        .start(original.clone(), FileSettings::default(), None)
        .await
        .unwrap();
    let streamed = state_when(&workflow, |state| !state.lines.is_empty()).await;
    let readonly = root.path().join("read-only.md");
    std::fs::write(&readonly, "- **[00:01] Name** archived").unwrap();
    assert_eq!(
        workflow
            .open_archive(started.generation, readonly.clone())
            .await
            .unwrap()
            .generation,
        started.generation
    );
    assert_eq!(workflow.snapshot().phase, ViewPhase::Processing);
    // Exercise the production 30-second clock with real children and disk I/O.
    let checkpoint = timeout(Duration::from_secs(45), async {
        let mut watch = workflow.owner.snapshot.clone();
        loop {
            let state = watch.borrow_and_update().clone();
            if state.archive.transcript.is_some() {
                break state;
            }
            watch.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
    assert_eq!(checkpoint.phase, ViewPhase::Processing);
    let saved = checkpoint.archive.transcript.unwrap();
    let before = std::fs::read_to_string(&saved).unwrap();
    assert!(before.contains("Hello"));
    workflow
        .edit(
            started.generation,
            Edit::Line {
                id: streamed.lines[0].line.id.to_string(),
                text: "Final edit".into(),
            },
        )
        .await
        .unwrap();
    // An inline edit alone does not invent a new native autosave trigger.
    assert_eq!(std::fs::read_to_string(&saved).unwrap(), before);
    // A folder switch applies to the next session, not to this already-owned
    // checkpoint. Rapid opposite toggle changes preserve their queue order.
    let next_folder = root.path().join("next-archives");
    workflow
        .archive_settings_changed(ArchiveSettings {
            enabled: false,
            folder: next_folder.clone(),
        })
        .unwrap();
    let updated = workflow
        .set_archive_settings(ArchiveSettings {
            enabled: true,
            folder: next_folder.clone(),
        })
        .await
        .unwrap();
    assert!(updated.archive.enabled);
    assert_eq!(updated.archive.folder, Some(next_folder.clone()));
    std::fs::write(root.path().join("finish"), "finish").unwrap();
    let finished = state_when(&workflow, |state| state.phase == ViewPhase::Done).await;
    assert_eq!(
        finished.archive.transcript.as_deref(),
        Some(saved.as_path())
    );
    assert!(
        std::fs::read_to_string(&saved)
            .unwrap()
            .contains("Final edit")
    );
    let archive_bytes = std::fs::read(&saved).unwrap();
    let reopened = workflow
        .open_archive(finished.generation, saved.clone())
        .await
        .unwrap();
    assert_ne!(reopened.generation, finished.generation);
    assert_eq!(reopened.phase, ViewPhase::Done);
    assert_eq!(reopened.lines[0].text, "Final edit");
    assert!(reopened.archive.transcript.is_none());
    assert!(reopened.lines.iter().all(|line| {
        line.line
            .words
            .iter()
            .all(|word| word.t0 == line.line.start && word.t1 == line.line.start)
    }));
    let invalid = root.path().join("not-transcript.md");
    std::fs::write(&invalid, "# summary only").unwrap();
    assert_eq!(
        workflow
            .open_archive(reopened.generation, invalid)
            .await
            .unwrap()
            .generation,
        reopened.generation
    );
    assert_eq!(
        workflow
            .open_archive(finished.generation, readonly)
            .await
            .unwrap()
            .generation,
        reopened.generation
    );
    let refused = workflow
        .start(
            original.clone(),
            FileSettings::default(),
            Some("admission fixture".into()),
        )
        .await
        .unwrap();
    assert!(refused.archive.transcript.is_none());
    assert_eq!(refused.lines[0].text, "Final edit");
    // A subsequent actual session allocates a fresh path instead of acquiring
    // the reopened archive as its writable checkpoint target.
    workflow
        .start(original, FileSettings::default(), None)
        .await
        .unwrap();
    let next = state_when(&workflow, |state| state.phase == ViewPhase::Done).await;
    let new_path = next.archive.transcript.unwrap();
    assert_eq!(new_path.parent(), Some(next_folder.as_path()));
    assert_ne!(new_path, saved);
    assert_eq!(std::fs::read(&saved).unwrap(), archive_bytes);
    assert!(
        std::fs::read_to_string(new_path)
            .unwrap()
            .contains("Hello world.")
    );
    workflow.shutdown().await.unwrap();
    cleaned(root.path()).await;
}

#[tokio::test]
async fn failed_transcription_saves_partial_and_archive_failure_does_not_replace_phase() {
    for blocked in [false, true] {
        let (root, configuration, original) = fixture("", &format!("{WORDS}\nsys.exit(7)"));
        let folder = root.path().join("archive");
        if blocked {
            std::fs::write(&folder, "foreign file").unwrap();
        }
        let workflow = FileWorkflow::with_archive(
            configuration,
            Some(ArchiveSettings {
                enabled: true,
                folder: folder.clone(),
            }),
            |_| {},
        )
        .unwrap();
        workflow
            .start(original, FileSettings::default(), None)
            .await
            .unwrap();
        let ended = state_when(&workflow, |state| {
            matches!(state.phase, ViewPhase::Error { .. }) && !state.lines.is_empty()
        })
        .await;
        assert!(matches!(ended.phase,ViewPhase::Error {message} if message.contains("코드 7")));
        if blocked {
            assert!(ended.archive.transcript.is_none() && ended.archive.error.is_some());
            assert_eq!(std::fs::read_to_string(folder).unwrap(), "foreign file");
        } else {
            assert!(ended.archive.error.is_none());
            let path = ended.archive.transcript.unwrap();
            assert!(
                std::fs::read_to_string(path)
                    .unwrap()
                    .contains("Hello world.")
            );
        }
        let reset = workflow.reset(ended.generation).await.unwrap();
        assert!(reset.archive.transcript.is_none() && reset.archive.error.is_none());
        assert!(reset.archive.enabled);
        workflow.shutdown().await.unwrap();
        cleaned(root.path()).await;
    }
}

#[tokio::test]
async fn disabled_archive_does_not_create_folder_and_reopen_preserves_imported_translations() {
    let (root, configuration, original) = fixture("", WORDS);
    let folder = root.path().join("must-not-create");
    let workflow = FileWorkflow::with_archive(
        configuration,
        Some(ArchiveSettings {
            enabled: false,
            folder: folder.clone(),
        }),
        |_| {},
    )
    .unwrap();
    workflow
        .start(original, FileSettings::default(), None)
        .await
        .unwrap();
    let done = state_when(&workflow, |state| state.phase == ViewPhase::Done).await;
    assert!(!folder.exists());
    assert!(done.archive.transcript.is_none());
    let archived = root.path().join("import.md");
    std::fs::write(
        &archived,
        "- **[00:01] Ada** *low* next\n  - [번역:ko] 가져온 번역\n- **[00:02] 미확인** unknown\n",
    )
    .unwrap();
    let reopened = workflow
        .open_archive(done.generation, archived)
        .await
        .unwrap();
    assert_eq!(
        reopened.speaker_names.get(&0).map(String::as_str),
        Some("Ada")
    );
    assert_eq!(reopened.lines[1].line.speaker, 255);
    assert_eq!(reopened.lines[0].line.words[0].conf, 0.3);
    assert!(reopened.lines[0].line.edited_translations.contains("ko"));
    assert_eq!(
        reopened.lines[0]
            .line
            .translations
            .get("ko")
            .map(String::as_str),
        Some("가져온 번역")
    );
    assert!(reopened.archive.transcript.is_none());
    workflow.shutdown().await.unwrap();
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

#[tokio::test]
async fn manual_export_uses_authoritative_edits_and_remains_owned_after_caller_cancellation() {
    use crate::transcript_export::Format;
    let (root, configuration, _) = fixture("", "");
    let source = root.path().join("source.md");
    let original = "- **[00:01] Ada** old text\n  > ko: 원문\n";
    std::fs::write(&source, original).unwrap();
    let workflow = FileWorkflow::new(configuration, |_| {}).unwrap();
    let opened = workflow.open_archive(0, source.clone()).await.unwrap();
    workflow
        .edit(
            opened.generation,
            Edit::Line {
                id: opened.lines[0].line.id.to_string(),
                text: "Latest edited words".into(),
            },
        )
        .await
        .unwrap();
    // Display publication is coalesced. Export must read the store immediately,
    // including user edits, rather than wait for that publication timer.
    let text = workflow
        .render_export(opened.generation, Format::Txt, Default::default())
        .await
        .unwrap()
        .unwrap();
    assert!(text.contains("Latest edited words"));
    assert!(!text.contains("old text"));
    for format in [
        Format::Md,
        Format::Srt,
        Format::Vtt,
        Format::Txt,
        Format::Json,
    ] {
        let path = root.path().join(format!("selected.{}", format.extension()));
        std::fs::write(&path, "confirmed overwrite").unwrap();
        workflow
            .export_to(opened.generation, path.clone(), format, Default::default())
            .await
            .unwrap();
        let result = std::fs::read_to_string(path).unwrap();
        assert!(result.contains("Latest edited words"));
        assert!(!result.contains("confirmed overwrite"));
    }
    let blocked = root.path().join("selected-directory");
    std::fs::create_dir(&blocked).unwrap();
    std::fs::write(blocked.join("keep"), "foreign").unwrap();
    assert!(
        workflow
            .export_to(
                opened.generation,
                blocked.clone(),
                Format::Txt,
                Default::default()
            )
            .await
            .is_err()
    );
    assert_eq!(
        std::fs::read_to_string(blocked.join("keep")).unwrap(),
        "foreign"
    );
    let stale = root.path().join("stale.txt");
    std::fs::write(&stale, "keep").unwrap();
    workflow
        .export_to(
            opened.generation + 1,
            stale.clone(),
            Format::Txt,
            Default::default(),
        )
        .await
        .unwrap();
    assert_eq!(std::fs::read_to_string(&stale).unwrap(), "keep");
    let final_path = root.path().join("cancelled-caller.txt");
    let mut pending = Box::pin(workflow.export_to(
        opened.generation,
        final_path.clone(),
        Format::Txt,
        Default::default(),
    ));
    std::future::poll_fn(|context| {
        assert!(pending.as_mut().poll(context).is_pending());
        std::task::Poll::Ready(())
    })
    .await;
    drop(pending);
    workflow.shutdown().await.unwrap();
    assert!(
        std::fs::read_to_string(final_path)
            .unwrap()
            .contains("Latest edited words")
    );
    assert_eq!(std::fs::read_to_string(source).unwrap(), original);
    assert!(!std::fs::read_dir(root.path()).unwrap().any(|entry| {
        entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".madi-export-")
    }));
}
