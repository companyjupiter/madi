use super::*;
use crate::{
    file_session::tests::{fixture, marker},
    model_assets::Locations,
    preferences,
};
use madi_core::{
    assets::TranslationVariant,
    settings::{LegacySettings, SettingsCommand},
};
use std::path::Path;
use tokio::time::timeout;

const WORDS: &str = r#"
with open(os.environ['EVENTS_FILE'],'w',encoding='utf-8') as out:
 out.write(json.dumps({'t':'seg','idx':0,'t0':0,'t1':1,'avg_logprob':-1.2,'fallback':'none'})+'\n')
for i,speaker in enumerate([1,2,1,255]):
 print(f'SPK {i*4} {speaker} 1 '+('0.2' if i==0 else '0.8'),flush=True)
 print('=== WORD TIMESTAMPS ===',flush=True)
 print(f'[{i*4}s-{i*4+.8}s] Row{i+1}. «conf 0.99»',flush=True)
print('<<SEG_END>>\n<<FLUSH_END>>',flush=True)
"#;
const DNA: &str = r#"
import os,sys,pathlib,time,json
root=pathlib.Path(sys.argv[1]);n=0
with (root/'launches').open('a',encoding='utf-8') as f:f.write(str(os.getpid())+'\n')
os.write(1,b'READY\n')
for raw in sys.stdin.buffer:
 n+=1
 pending=root/f'turn-{n}.pending';pending.write_bytes(raw);pending.replace(root/f'turn-{n}')
 os.write(1,b'[perf] prefill: 1 tok\n')
 while not (root/f'release-{n}').exists():time.sleep(.005)
 answer=(root/f'reply-{n}').read_text(encoding='utf-8')
 os.write(1,answer.encode()+b'\n[perf] generation: 1 tok\n> ')
"#;
async fn setup(
    enabled: bool,
    model: bool,
    engine: &str,
) -> (tempfile::TempDir, FileWorkflow, PreferencesService, PathBuf) {
    setup_inner(enabled, model, engine, true).await
}
async fn setup_inner(
    enabled: bool,
    model: bool,
    engine: &str,
    attach: bool,
) -> (tempfile::TempDir, FileWorkflow, PreferencesService, PathBuf) {
    setup_with_memory(enabled, model, engine, attach, 16 * (1 << 30)).await
}
async fn setup_with_memory(
    enabled: bool,
    model: bool,
    engine: &str,
    attach: bool,
    _physical_memory: u64,
) -> (tempfile::TempDir, FileWorkflow, PreferencesService, PathBuf) {
    let (root, config, source) = fixture("", engine);
    let prefs = PreferencesService::new(
        preferences::Store::load(
            root.path().join("prefs.json"),
            preferences::Preferences::from_legacy(preferences::Legacy {
                settings: LegacySettings {
                    ai_reconcile_enabled: Some(enabled),
                    ..Default::default()
                },
                ..Default::default()
            }),
        )
        .unwrap(),
        |_| {},
    )
    .unwrap();
    let mut resources = translation::Resources::new(
        Locations {
            bundle_resources: root.path().into(),
            bundle_executables: root.path().into(),
            support: root.path().into(),
        },
        TranslationVariant::Quality4B,
    );
    resources.test_launch = Some(dna_broker::Launch {
        engine: config.resources.executable.clone(),
        model: root.path().into(),
        arguments: vec!["-u".into(), "-c".into(), DNA.into()],
    });
    // Synthetic children need no model RAM; exercise admission independently
    // of the host (GitHub's Apple Silicon runners have less than 16 GiB).
    #[cfg(target_os = "macos")]
    {
        resources.test_physical_memory = Some(_physical_memory);
    }
    let w = FileWorkflow::with_translation(
        config,
        Some(ArchiveSettings {
            enabled: true,
            folder: root.path().join("archive"),
        }),
        model.then_some(resources),
        |_| {},
    )
    .unwrap();
    if attach {
        w.set_preferences(prefs.clone()).await.unwrap();
    }
    (root, w, prefs, source)
}
async fn until(w: &FileWorkflow, ready: impl Fn(&Snapshot) -> bool) -> Snapshot {
    let mut updates = w.owner.snapshot.clone();
    timeout(Duration::from_secs(15), async {
        loop {
            let s = updates.borrow_and_update().clone();
            if ready(&s) {
                return s;
            }
            updates.changed().await.unwrap();
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "reconciliation workflow deadline; last snapshot: {:?}",
            w.snapshot()
        )
    })
}
fn answer(root: &Path, n: usize, text: &str) {
    std::fs::write(root.join(format!("reply-{n}")), text).unwrap();
    std::fs::write(root.join(format!("release-{n}")), b"go").unwrap();
}
async fn start(w: &FileWorkflow, path: PathBuf) -> Snapshot {
    w.start(
        path,
        FileSettings {
            language_token: Some(50264),
            ..Default::default()
        },
        None,
    )
    .await
    .unwrap();
    until(w, |s| s.phase == ViewPhase::Done).await
}
#[tokio::test]
async fn final_plan_preserves_immediate_save_acoustic_and_unknown_gates_and_no_audio_note() {
    let (root, w, _prefs, source) = setup(true, true, WORDS).await;
    let s = start(&w, source.clone()).await;
    assert_eq!(s.lines.len(), 4);
    assert!(s.reconciling);
    assert_eq!(
        s.status.activity.as_deref(),
        Some("AI가 화자·언어를 검토하는 중")
    );
    let archive = s.archive.transcript.clone().unwrap();
    let before = std::fs::read(&archive).unwrap();
    marker(&root.path().join("turn-1")).await;
    let prompt = std::fs::read_to_string(root.path().join("turn-1")).unwrap();
    assert!(prompt.contains("1△◇ [S1·화자 1] Row1."), "{prompt}");
    assert!(prompt.contains("[S255·미확인]"));
    answer(
        root.path(),
        1,
        "RELABEL 1 2\nRELABEL 2 1\nRELABEL 4 1\nMERGE 255 1\nLANG 3 ko\nLANG 4 ja",
    );
    let done = until(&w, |s| !s.reconciling && s.reconcile_note.is_some()).await;
    assert_eq!(done.lines[0].line.speaker, 2);
    assert_eq!(
        done.lines[1].line.speaker, 2,
        "confident line must keep its speaker"
    );
    assert_eq!(done.lines[3].line.speaker, 255);
    assert_eq!(
        done.reconcile_note.as_deref(),
        Some(
            "AI 교정: 화자 1건 재지정 · 언어 1건 보류(세션 언어와 다름) · 언어 1건 검증만(보존 오디오 없음)"
        )
    );
    assert!(done.has_speaker_corrections);
    assert_ne!(before, std::fs::read(&archive).unwrap());
    let undone = w
        .edit(done.generation, Edit::RevertReconcile)
        .await
        .unwrap();
    assert!(!undone.has_speaker_corrections && undone.reconcile_note.is_none());
    assert_eq!(
        undone
            .lines
            .iter()
            .map(|l| l.line.speaker)
            .collect::<Vec<_>>(),
        vec![1, 2, 1, 255]
    );
    w.reset(done.generation).await.unwrap();
    assert_eq!(w.snapshot().language_corrections_pending, 0);
    assert!(source.exists());
    w.shutdown().await.unwrap();
}
#[tokio::test]
async fn named_merge_is_atomic_reversible_and_rejects_conflicting_identity() {
    for (from, into, merge) in [
        ("Alice", "Bob", false),
        ("  Straße\u{200b}", "STRASSE", true),
    ] {
        let (root, w, _prefs, source) = setup(true, true, WORDS).await;
        let s = start(&w, source).await;
        w.edit(
            s.generation,
            Edit::SpeakerName {
                speaker: 1,
                name: into.into(),
            },
        )
        .await
        .unwrap();
        w.edit(
            s.generation,
            Edit::SpeakerName {
                speaker: 2,
                name: from.into(),
            },
        )
        .await
        .unwrap();
        let names = w.snapshot().speaker_names;
        marker(&root.path().join("turn-1")).await;
        answer(root.path(), 1, "MERGE 2 1");
        let done = until(&w, |s| !s.reconciling).await;
        assert_eq!(done.has_speaker_corrections, merge);
        assert_eq!(
            done.reconcile_note.as_deref(),
            merge.then_some("AI 교정: 화자 1건 병합")
        );
        if merge {
            assert!(!done.speaker_names.contains_key(&2));
            assert!(done.lines.iter().all(|l| l.line.speaker != 2));
            let undone = w
                .edit(done.generation, Edit::RevertReconcile)
                .await
                .unwrap();
            assert_eq!(undone.speaker_names, names);
            assert_eq!(undone.lines[1].line.speaker, 2);
        } else {
            assert_eq!(done.speaker_names, names);
        }
        w.shutdown().await.unwrap();
    }
}
#[tokio::test]
async fn opt_in_model_line_count_and_failed_session_admission_do_not_launch_ai() {
    for (enabled, model, engine) in [
        (false, true, WORDS),
        (true, false, WORDS),
        (true, true, "print('<<FLUSH_END>>',flush=True)"),
        (
            true,
            true,
            "print('=== WORD TIMESTAMPS ===\\n[0s-1s] partial',flush=True);sys.exit(7)",
        ),
    ] {
        let (root, w, _prefs, source) = setup(enabled, model, engine).await;
        w.start(source, Default::default(), None).await.unwrap();
        let s = until(&w, |s| {
            s.phase == ViewPhase::Done || matches!(s.phase, ViewPhase::Error { .. })
        })
        .await;
        assert!(!s.reconciling && s.reconcile_note.is_none());
        w.shutdown().await.unwrap();
        assert!(!root.path().join("launches").exists());
    }
}
#[tokio::test]
async fn reset_retires_held_reply_and_shutdown_drains_the_final_owned_correction() {
    let (root, w, prefs, source) = setup(true, true, WORDS).await;
    let first = start(&w, source.clone()).await;
    marker(&root.path().join("turn-1")).await;
    w.reset(first.generation).await.unwrap();
    prefs
        .settings(SettingsCommand::AIReconcile(false))
        .await
        .unwrap();
    let second = start(&w, source).await;
    answer(root.path(), 1, "MERGE 2 1");
    assert_eq!(second.generation, first.generation + 2);
    let stale = w
        .edit(first.generation, Edit::RevertReconcile)
        .await
        .unwrap();
    assert_eq!(stale.generation, second.generation);
    w.shutdown().await.unwrap();
    assert!(!w.snapshot().has_speaker_corrections);

    let (root, w, _prefs, source) = setup(true, true, WORDS).await;
    let s = start(&w, source).await;
    marker(&root.path().join("turn-1")).await;
    let owner = w.clone();
    let closing = tokio::spawn(async move { owner.shutdown().await });
    tokio::task::yield_now().await;
    assert!(!closing.is_finished());
    answer(root.path(), 1, "MERGE 2 1");
    timeout(Duration::from_secs(10), closing)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let saved =
        archive::parse(&std::fs::read_to_string(s.archive.transcript.unwrap()).unwrap()).unwrap();
    assert!(saved.lines.iter().all(|l| l.speaker != 2));
}

#[cfg(target_os = "macos")]
mod live {
    use super::*;
    use crate::{
        audio_capture::Event as Capture,
        live_session::{
            Control,
            tests::{input, request},
        },
    };
    async fn timer(w: &FileWorkflow) -> Option<Instant> {
        let (reply, result) = oneshot::channel();
        w.owner
            .commands
            .send(Command::InspectReconciliationTimer(reply))
            .unwrap();
        timeout(Duration::from_secs(8), result)
            .await
            .unwrap()
            .unwrap()
    }
    async fn wait_for_next_tick(w: &FileWorkflow) {
        let elapsed = Instant::now();
        timeout(Duration::from_secs(8), async {
            while timer(w).await.is_none_or(|next| next <= elapsed) {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .expect("reconciliation timer did not rearm");
    }
    const ENGINE: &str = r#"
import os,sys,pathlib,time,json,wave
root=pathlib.Path(__file__).parent
sys.stdout.reconfigure(encoding='utf-8')
if 'STREAM' not in os.environ:
 with (root/'correction-launches').open('a',encoding='utf-8') as f:f.write(str(os.getpid())+'\n')
 n=len((root/'correction-launches').read_text().splitlines())
 clip=pathlib.Path(sys.argv[1]); data=clip.read_bytes()
 record={'clip':str(clip),'bytes':len(data),'sample':int.from_bytes(data[44:46],'little',signed=True),'token':os.environ['WHISPER_LANG_ID'],'diar':os.environ['DIAR']}
 pending=root/f'correction-{n}.pending';pending.write_text(json.dumps(record));pending.replace(root/f'correction-{n}')
 while not (root/f'correct-{n}').exists():time.sleep(.005)
 print('=== TRANSCRIPTION ===\nCorrected'+str(n)+'.\n\n[perf] done',flush=True)
 sys.exit(0)
print('[stream] ready',flush=True)
for raw in sys.stdin:
 if raw.strip()=='FLUSH':print('<<FLUSH_END>>',flush=True);break
 offset,path=raw.rstrip('\n').split(' ',1)
 for i in range(6):
  print(f'SPK {float(offset)+i*3} {i%2+1} 1 0.2\n=== WORD TIMESTAMPS ===\n[{float(offset)+i*3}s-{float(offset)+i*3+.5}s] Live{i+1}. «conf 0.99»',flush=True)
 print('=== WORD TIMESTAMPS ===',flush=True)
 if (root/'hold-segment').exists():
  (root/'segment-held').write_text('ready')
  while not (root/'release-segment').exists():time.sleep(.005)
 print('<<SEG_END>>',flush=True)
"#;
    async fn recording() -> (
        tempfile::TempDir,
        FileWorkflow,
        PreferencesService,
        mpsc::UnboundedSender<Capture>,
        mpsc::UnboundedReceiver<Control>,
    ) {
        recording_with_hold(false).await
    }
    async fn recording_with_hold(
        hold: bool,
    ) -> (
        tempfile::TempDir,
        FileWorkflow,
        PreferencesService,
        mpsc::UnboundedSender<Capture>,
        mpsc::UnboundedReceiver<Control>,
    ) {
        recording_with_memory(hold, 16 * (1 << 30)).await
    }
    async fn recording_with_memory(
        hold: bool,
        memory: u64,
    ) -> (
        tempfile::TempDir,
        FileWorkflow,
        PreferencesService,
        mpsc::UnboundedSender<Capture>,
        mpsc::UnboundedReceiver<Control>,
    ) {
        let (root, w, prefs, _) = setup_with_memory(true, true, "", false, memory).await;
        std::fs::write(root.path().join("engine fixture.py"), ENGINE).unwrap();
        if hold {
            std::fs::write(root.path().join("hold-segment"), b"hold").unwrap();
        }
        let (capture, events, controls) = input();
        let mut req = request(capture);
        req.settings.common.language_token = Some(50264);
        req.capture.first_segment_seconds = 20.;
        req.capture.segment_seconds = 20.;
        req.capture.overlap_seconds = 0.;
        req.capture.preview_enabled = false;
        w.start_live(req, None).await.unwrap();
        until(&w, |s| s.phase == ViewPhase::Ready).await;
        w.set_preferences(prefs.clone()).await.unwrap();
        events.send(Capture::Started).unwrap();
        until(&w, |s| s.phase == ViewPhase::Recording).await;
        events
            .send(Capture::Samples {
                microphone: true,
                pcm: vec![4000; 320000],
            })
            .unwrap();
        until(&w, |s| s.lines.len() == 6).await;
        (root, w, prefs, events, controls)
    }
    async fn stop(
        w: &FileWorkflow,
        events: &mpsc::UnboundedSender<Capture>,
        controls: &mut mpsc::UnboundedReceiver<Control>,
    ) {
        w.live_control(w.snapshot().generation, LiveControl::Stop)
            .await
            .unwrap();
        assert_eq!(
            timeout(Duration::from_secs(10), controls.recv())
                .await
                .unwrap(),
            Some(Control::Stop)
        );
        events.send(Capture::Stopped).unwrap();
        until(w, |s| s.phase == ViewPhase::Done).await;
    }
    #[tokio::test]
    async fn live_corrections_preserve_user_revision_and_translation_provenance_then_checkpoint() {
        let (root, w, _prefs, events, mut controls) = recording().await;
        stop(&w, &events, &mut controls).await;
        let before = w.snapshot();
        let first = before.lines[0].line.id;
        let second = before.lines[1].line.id;
        w.edit(
            before.generation,
            Edit::Translation {
                id: second.to_string(),
                language: "English".into(),
                text: "Old translation".into(),
            },
        )
        .await
        .unwrap();
        marker(&root.path().join("turn-1")).await;
        answer(root.path(), 1, "LANG 1 ko\nLANG 2 ko");
        marker(&root.path().join("correction-1")).await;
        let active = until(&w, |s| s.language_corrections_pending == 2).await;
        assert!(matches!(
            active.status.pipeline,
            madi_core::pipeline_status::Pipeline::Correcting { count: 2 }
        ));
        w.edit(
            before.generation,
            Edit::Line {
                id: first.to_string(),
                text: "Human correction.".into(),
            },
        )
        .await
        .unwrap();
        std::fs::write(root.path().join("correct-1"), b"go").unwrap();
        marker(&root.path().join("correction-2")).await;
        std::fs::write(root.path().join("correct-2"), b"go").unwrap();
        let done = until(&w, |s| {
            s.language_corrections_pending == 0
                && s.reconcile_note.as_deref()
                    == Some("AI 교정: 언어 1건 교정 · 언어 1건 원문 유지")
        })
        .await;
        assert_eq!(
            done.lines.iter().find(|l| l.line.id == first).unwrap().text,
            "Human correction."
        );
        let line = done.lines.iter().find(|l| l.line.id == second).unwrap();
        assert_eq!(line.text, "Corrected2.");
        assert!(line.line.translations.is_empty());
        assert_eq!(
            line.line
                .stale_translations
                .get("English")
                .map(String::as_str),
            Some("Old translation")
        );
        let saved = std::fs::read_to_string(done.archive.transcript.unwrap()).unwrap();
        assert!(saved.contains("Human correction.") && saved.contains("Corrected2."));
        assert!(!saved.contains("Corrected1."));
        for n in 1..=2 {
            let record: serde_json::Value = serde_json::from_slice(
                &std::fs::read(root.path().join(format!("correction-{n}"))).unwrap(),
            )
            .unwrap();
            assert_eq!(record["token"], "50264");
            assert_eq!(record["diar"], "0");
            assert!(!Path::new(record["clip"].as_str().unwrap()).exists());
        }
        w.reset(before.generation).await.unwrap();
        w.shutdown().await.unwrap();
        assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
    }
    #[tokio::test]
    async fn low_memory_disables_mid_session_ai_but_keeps_final_reconciliation() {
        let (root, w, _prefs, events, mut controls) =
            recording_with_memory(false, 16 * (1 << 30) - 1).await;
        until(&w, |s| s.status.activity.as_deref() == Some("듣는 중")).await;
        assert!(timer(&w).await.is_none());
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(121)).await;
        tokio::time::resume();
        w.edit(
            w.snapshot().generation,
            Edit::SpeakerName {
                speaker: 1,
                name: "Named".into(),
            },
        )
        .await
        .unwrap();
        assert!(!w.snapshot().reconciling && !root.path().join("launches").exists());
        stop(&w, &events, &mut controls).await;
        marker(&root.path().join("turn-1")).await;
        answer(root.path(), 1, "OK");
        until(&w, |s| !s.reconciling).await;
        w.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn mid_snapshot_excludes_tail_and_defers_merge_and_final_until_its_reply() {
        let (root, w, _prefs, events, mut controls) = recording().await;
        let baseline = w.snapshot();
        until(&w, |s| s.status.activity.as_deref() == Some("듣는 중")).await;
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(120)).await;
        tokio::time::resume();
        marker(&root.path().join("turn-1")).await;
        let mid = std::fs::read_to_string(root.path().join("turn-1")).unwrap();
        assert!(mid.contains("Live4.") && !mid.contains("Live5.") && !mid.contains("Live6."));
        stop(&w, &events, &mut controls).await;
        assert!(!root.path().join("turn-2").exists());
        answer(root.path(), 1, "MERGE 2 1\nRELABEL 1 2");
        marker(&root.path().join("turn-2")).await;
        let final_prompt = std::fs::read_to_string(root.path().join("turn-2")).unwrap();
        assert!(final_prompt.contains("Live6."));
        let current = w.snapshot();
        assert_eq!(
            current
                .lines
                .iter()
                .find(|l| l.line.id == baseline.lines[0].line.id)
                .unwrap()
                .line
                .speaker,
            2
        );
        assert!(
            current.lines.iter().any(|l| l.line.speaker == 1),
            "mid merges must be deferred"
        );
        answer(root.path(), 2, "MERGE 2 1");
        let done = until(&w, |s| {
            !s.reconciling && s.reconcile_note.as_deref() == Some("AI 교정: 화자 1건 병합")
        })
        .await;
        assert!(done.lines.iter().all(|l| l.line.speaker == 1));
        w.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn reset_during_forced_asr_joins_child_before_releasing_retained_audio() {
        let (root, w, _prefs, events, mut controls) = recording().await;
        stop(&w, &events, &mut controls).await;
        marker(&root.path().join("turn-1")).await;
        answer(root.path(), 1, "LANG 1 ko\nLANG 2 ko");
        marker(&root.path().join("correction-1")).await;
        let pid: i32 = std::fs::read_to_string(root.path().join("correction-launches"))
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let record: serde_json::Value =
            serde_json::from_slice(&std::fs::read(root.path().join("correction-1")).unwrap())
                .unwrap();
        let clip = PathBuf::from(record["clip"].as_str().unwrap());
        assert!(clip.exists());
        let reset = w.reset(w.snapshot().generation).await.unwrap();
        assert!(reset.lines.is_empty() && !reset.reconciling && reset.reconcile_note.is_none());
        assert_eq!(reset.language_corrections_pending, 0);
        assert_eq!(
            unsafe { libc::kill(pid, 0) },
            -1,
            "reset must reap the owned child"
        );
        assert!(!clip.exists());
        assert!(!root.path().join("correction-2").exists());
        w.shutdown().await.unwrap();
        assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
    }
    #[tokio::test]
    async fn language_jobs_select_the_committed_segment_covering_each_line() {
        let (root, w, _prefs, events, mut controls) = recording().await;
        events
            .send(Capture::Samples {
                microphone: true,
                pcm: vec![7000; 320000],
            })
            .unwrap();
        until(&w, |s| s.lines.len() == 12).await;
        stop(&w, &events, &mut controls).await;
        marker(&root.path().join("turn-1")).await;
        answer(root.path(), 1, "LANG 1 ko\nLANG 7 ko");
        for (n, sample) in [(1, 4000), (2, 7000)] {
            marker(&root.path().join(format!("correction-{n}"))).await;
            let record: serde_json::Value = serde_json::from_slice(
                &std::fs::read(root.path().join(format!("correction-{n}"))).unwrap(),
            )
            .unwrap();
            assert_eq!(record["sample"], sample);
            assert_eq!(
                record["bytes"], 22444,
                "each line begins at its own segment offset"
            );
            std::fs::write(root.path().join(format!("correct-{n}")), b"go").unwrap();
        }
        until(&w, |s| {
            s.reconcile_note.as_deref() == Some("AI 교정: 언어 2건 교정")
        })
        .await;
        w.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn mid_timer_waits_for_committed_asr_and_retries_at_the_next_interval() {
        let (root, w, _prefs, events, mut controls) = recording_with_hold(true).await;
        marker(&root.path().join("segment-held")).await;
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(120)).await;
        tokio::time::resume();
        // Commands and timers are separate select! branches: an edit reply
        // does not prove the expired timer ran. Keep ASR held until the timer
        // has actually rearmed, so this tick must observe pending ASR.
        wait_for_next_tick(&w).await;
        w.edit(
            w.snapshot().generation,
            Edit::SpeakerName {
                speaker: 1,
                name: "Named".into(),
            },
        )
        .await
        .unwrap();
        assert!(!w.snapshot().reconciling && !root.path().join("launches").exists());
        std::fs::write(root.path().join("release-segment"), b"go").unwrap();
        // Watch the authoritative pending count's status projection.
        until(&w, |s| s.status.activity.as_deref() == Some("듣는 중")).await;
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(120)).await;
        tokio::time::resume();
        marker(&root.path().join("turn-1")).await;
        answer(root.path(), 1, "OK");
        until(&w, |s| !s.reconciling).await;
        stop(&w, &events, &mut controls).await;
        marker(&root.path().join("turn-2")).await;
        answer(root.path(), 2, "OK");
        until(&w, |s| !s.reconciling).await;
        w.shutdown().await.unwrap();
    }
}

#[cfg(target_os = "macos")]
mod metal_probe;
