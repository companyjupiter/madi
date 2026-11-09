use super::*;
use crate::{
    file_session::tests::{fixture, marker},
    preferences,
};
use madi_core::{settings::SettingsCommand, setup::Language};
use std::path::Path;
use tokio::time::timeout;

const WORDS: &str = r#"
print('=== WORD TIMESTAMPS ===',flush=True)
print('[0.0s-1.4s] 안녕하세요 반가운 아침입니다. «conf 0.99»',flush=True)
print('<<SEG_END>>',flush=True)
print('<<FLUSH_END>>',flush=True)
"#;
const DNA: &str = r#"
import sys,os,pathlib,time
root=pathlib.Path(sys.argv[1])
with (root/'dna-launches').open('a',encoding='utf-8') as f:f.write(str(os.getpid())+'\n')
generation=len((root/'dna-launches').read_text(encoding='utf-8').splitlines())
os.write(1,b'[caps] fp max\nREADY\n')
n=0
for raw in sys.stdin.buffer:
 line=raw.decode('utf-8').rstrip('\n')
 if line.startswith('%%PFX '):
  os.write(1,('PFX_OK '+line.split()[1]+' 12\n').encode());continue
 n+=1
 (root/f'dna-turn-{generation}-{n}').write_text(line,encoding='utf-8')
 japanese=line.startswith('%%TRN 2 ') or 'Target Japanese:' in line
 prefix='日本語の' if japanese else ('Previous ' if n==1 else 'Fresh ')
 os.write(1,('[perf] prefill: 1 tok\n'+prefix).encode())
 if (root/'hold').exists():
  while not (root/f'release-{generation}-{n}').exists():time.sleep(.005)
 if (root/'crash').exists():sys.exit(7)
 os.write(1,(('回答です。' if japanese else 'reply.')+'\n[perf] generation: 3 tok\n> ').encode())
"#;
async fn setup(hold: bool) -> (tempfile::TempDir, FileWorkflow, PreferencesService, PathBuf) {
    setup_with_engine(hold, WORDS).await
}
async fn setup_with_engine(
    hold: bool,
    engine: &str,
) -> (tempfile::TempDir, FileWorkflow, PreferencesService, PathBuf) {
    setup_with_bank(hold, engine, None).await
}
async fn setup_with_bank(
    hold: bool,
    engine: &str,
    bank: Option<Vec<madi_core::translation::cache::Entry>>,
) -> (tempfile::TempDir, FileWorkflow, PreferencesService, PathBuf) {
    let (root, config, source) = fixture("", engine);
    if hold {
        std::fs::write(root.path().join("hold"), b"hold").unwrap();
    }
    let p = PreferencesService::new(
        preferences::Store::load(
            root.path().join("preferences.json"),
            preferences::Preferences::from_legacy(preferences::Legacy {
                translate_targets: vec!["English".into()],
                ..Default::default()
            }),
        )
        .unwrap(),
        |_| {},
    )
    .unwrap();
    let mut resources = Resources::new(
        Locations {
            bundle_resources: root.path().into(),
            bundle_executables: root.path().into(),
            support: root.path().into(),
        },
        TranslationVariant::Quality4B,
    );
    resources.test_launch = Some(Launch {
        engine: config.resources.executable.clone(),
        model: root.path().into(),
        arguments: vec!["-u".into(), "-c".into(), DNA.into()],
    });
    if let Some(entries) = bank {
        let path = root.path().join("faq_translations.json");
        std::fs::write(&path, serde_json::to_vec_pretty(&entries).unwrap()).unwrap();
        resources.faq_path = Some(path);
    }
    let w = FileWorkflow::with_translation(
        config,
        Some(ArchiveSettings {
            enabled: true,
            folder: root.path().join("archives"),
        }),
        Some(resources),
        |_| {},
    )
    .unwrap();
    w.set_preferences(p.clone()).await.unwrap();
    (root, w, p, source)
}
async fn until(w: &FileWorkflow, ready: impl Fn(&Snapshot) -> bool) -> Snapshot {
    let mut changes = w.owner.snapshot.clone();
    timeout(Duration::from_secs(10), async {
        loop {
            let state = changes.borrow_and_update().clone();
            if ready(&state) {
                return state;
            }
            changes.changed().await.unwrap();
        }
    })
    .await
    .expect("workflow deadline")
}
fn release(root: &Path, generation: u32, turn: u32) {
    std::fs::write(root.join(format!("release-{generation}-{turn}")), b"go").unwrap();
}
async fn start(w: &FileWorkflow, source: PathBuf) -> Snapshot {
    w.start(
        source,
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
async fn committed_translation_flows_through_file_owner_and_final_archive() {
    let (root, w, p, source) = setup(false).await;
    let before = std::fs::read(&source).unwrap();
    start(&w, source.clone()).await;
    let translated = until(&w, |s| {
        s.translation_queue_depth == 0
            && s.lines
                .first()
                .is_some_and(|l| l.line.translations.contains_key("English"))
    })
    .await;
    let text = &translated.lines[0].line.translations["English"];
    assert!(text.ends_with("Previous reply."), "{text}");
    let saved = std::fs::read_to_string(translated.archive.transcript.as_ref().unwrap()).unwrap();
    assert!(
        saved.contains(text),
        "late translation must be checkpointed"
    );
    assert_eq!(translated.translation_backlog, 0);
    w.shutdown().await.unwrap();
    p.shutdown().await.unwrap();
    assert_eq!(std::fs::read(source).unwrap(), before);
    assert_eq!(
        std::fs::read_to_string(root.path().join("dna-launches"))
            .unwrap()
            .lines()
            .count(),
        1
    );
}

#[tokio::test]
async fn late_old_source_is_rejected_and_only_edited_revision_is_saved() {
    let (root, w, p, source) = setup(true).await;
    let initial = start(&w, source).await;
    marker(&root.path().join("dna-turn-1-1")).await;
    let waiting = until(&w, |s| s.status.activity.is_some()).await;
    assert_eq!(waiting.phase, ViewPhase::Done);
    assert_eq!(
        waiting.status.pipeline,
        madi_core::pipeline_status::Pipeline::Translating { count: 1 }
    );
    assert_eq!(
        waiting.status.activity.as_deref(),
        Some("번역 중 · 1줄 대기")
    );
    p.presentation(madi_core::preferences::PresentationCommand::UILanguage(
        madi_core::preferences::UILanguage::Ja,
    ))
    .await
    .unwrap();
    let relabeled = until(&w, |s| {
        s.status.activity.as_deref() == Some("翻訳中 · 1行待機")
    })
    .await;
    assert_eq!(relabeled.generation, initial.generation);
    assert_eq!(relabeled.lines[0].text, waiting.lines[0].text);
    let id = initial.lines[0].line.id;
    w.edit(
        initial.generation,
        Edit::Line {
            id: id.to_string(),
            text: "새로운 회의 내용입니다.".into(),
        },
    )
    .await
    .unwrap();
    release(root.path(), 1, 1);
    marker(&root.path().join("dna-turn-1-2")).await;
    let state = until(&w, |s| {
        s.lines[0].text == "새로운 회의 내용입니다." && s.translation_queue_depth == 1
    })
    .await;
    assert!(!state.lines[0].line.translations.contains_key("English"));
    release(root.path(), 1, 2);
    let final_state = until(&w, |s| {
        s.translation_queue_depth == 0 && s.lines[0].line.translations.contains_key("English")
    })
    .await;
    assert!(final_state.lines[0].line.translations["English"].ends_with("Fresh reply."));
    assert_eq!(
        final_state.status.pipeline,
        madi_core::pipeline_status::Pipeline::Completed
    );
    assert!(final_state.status.activity.is_none());
    let saved = std::fs::read_to_string(final_state.archive.transcript.as_ref().unwrap()).unwrap();
    assert!(!saved.contains("Previous reply."));
    assert!(saved.contains("Fresh reply."));
    w.shutdown().await.unwrap();
    p.shutdown().await.unwrap();
}

#[tokio::test]
async fn reset_retires_translation_before_a_new_session_reuses_the_broker() {
    let (root, w, p, source) = setup(true).await;
    let initial = start(&w, source.clone()).await;
    marker(&root.path().join("dna-turn-1-1")).await;
    let reset = w.reset(initial.generation).await.unwrap();
    assert!(reset.lines.is_empty());
    assert_eq!(reset.translation_queue_depth, 0);
    assert_eq!(
        reset.status.pipeline,
        madi_core::pipeline_status::Pipeline::Idle
    );
    assert!(reset.status.activity.is_none());
    assert_ne!(reset.generation, initial.generation);
    let second = start(&w, source).await;
    marker(&root.path().join("dna-turn-2-1")).await;
    assert!(second.lines[0].line.translations.is_empty());
    release(root.path(), 2, 1);
    until(&w, |s| {
        s.translation_queue_depth == 0 && s.lines[0].line.translations.contains_key("English")
    })
    .await;
    w.shutdown().await.unwrap();
    p.shutdown().await.unwrap();
}

#[tokio::test]
async fn settings_disable_reaps_a_pending_translation_without_more_asr_events() {
    let (root, w, p, source) = setup(true).await;
    let initial = start(&w, source).await;
    marker(&root.path().join("dna-turn-1-1")).await;
    p.settings(SettingsCommand::TranslationTarget {
        language: Language::English,
        enabled: false,
    })
    .await
    .unwrap();
    let stopped = until(&w, |s| s.translation_queue_depth == 0).await;
    assert!(stopped.status.activity.is_none());
    assert!(stopped.lines[0].line.translations.is_empty());
    p.settings(SettingsCommand::TranslationTarget {
        language: Language::English,
        enabled: true,
    })
    .await
    .unwrap();
    w.edit(
        initial.generation,
        Edit::Line {
            id: initial.lines[0].line.id.to_string(),
            text: "새로운 회의 내용입니다.".into(),
        },
    )
    .await
    .unwrap();
    marker(&root.path().join("dna-turn-2-1")).await;
    release(root.path(), 2, 1);
    until(&w, |s| {
        s.translation_queue_depth == 0 && s.lines[0].line.translations.contains_key("English")
    })
    .await;
    w.shutdown().await.unwrap();
    p.shutdown().await.unwrap();
}

#[tokio::test]
async fn shutdown_joins_final_translation_and_checkpoint() {
    let (root, w, p, source) = setup(true).await;
    let initial = start(&w, source).await;
    marker(&root.path().join("dna-turn-1-1")).await;
    let owner = w.clone();
    let ending = tokio::spawn(async move { owner.shutdown().await });
    assert!(!ending.is_finished());
    release(root.path(), 1, 1);
    timeout(Duration::from_secs(10), ending)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let saved = std::fs::read_to_string(initial.archive.transcript.as_ref().unwrap()).unwrap();
    assert!(saved.contains("Previous reply."));
    p.shutdown().await.unwrap();
}

#[tokio::test]
async fn unchanged_tail_translates_while_the_file_engine_is_still_processing() {
    let engine = WORDS.replace(
        "print('<<FLUSH_END>>',flush=True)",
        "while not (root/'finish').exists(): time.sleep(.005)\nprint('<<FLUSH_END>>',flush=True)",
    );
    let (root, w, p, source) = setup_with_engine(false, &engine).await;
    p.settings(SettingsCommand::TranslateTailSeconds(0.5))
        .await
        .unwrap();
    w.start(
        source,
        FileSettings {
            language_token: Some(50264),
            ..Default::default()
        },
        None,
    )
    .await
    .unwrap();
    let translated = until(&w, |s| {
        s.phase == ViewPhase::Processing
            && s.lines
                .first()
                .is_some_and(|l| l.line.translations.contains_key("English"))
    })
    .await;
    assert_eq!(
        translated.lines[0].line.translations["English"],
        "Previous reply."
    );
    std::fs::write(root.path().join("finish"), b"go").unwrap();
    until(&w, |s| {
        s.phase == ViewPhase::Done && s.translation_queue_depth == 0
    })
    .await;
    w.shutdown().await.unwrap();
    p.shutdown().await.unwrap();
}

#[tokio::test]
async fn source_language_only_does_not_start_a_dna_process() {
    let (root, w, p, source) = setup(false).await;
    p.settings(SettingsCommand::TranslationTarget {
        language: Language::English,
        enabled: false,
    })
    .await
    .unwrap();
    p.settings(SettingsCommand::TranslationTarget {
        language: Language::Korean,
        enabled: true,
    })
    .await
    .unwrap();
    let done = start(&w, source).await;
    assert!(done.lines[0].line.translations.is_empty());
    assert_eq!(done.translation_queue_depth, 0);
    w.shutdown().await.unwrap();
    p.shutdown().await.unwrap();
    assert!(!root.path().join("dna-launches").exists());
}

#[tokio::test]
async fn terminal_engine_failure_closes_shed_backfill_without_claiming_translations() {
    let engine = r#"
print('=== WORD TIMESTAMPS ===',flush=True)
for i in range(45):
 print(f'[{i*5:.1f}s-{i*5+1:.1f}s] 안녕하세요 반가운 아침{i}입니다. «conf 0.99»',flush=True)
print('<<SEG_END>>',flush=True)
while not (root/'finish').exists():time.sleep(.005)
print('<<FLUSH_END>>',flush=True)
"#;
    let (root, w, p, source) = setup_with_engine(true, engine).await;
    w.start(
        source,
        FileSettings {
            language_token: Some(50264),
            ..Default::default()
        },
        None,
    )
    .await
    .unwrap();
    marker(&root.path().join("dna-turn-1-1")).await;
    until(&w, |s| {
        s.lines.len() >= 44 && s.translation_backlog > 0 && s.translation_queue_depth > 0
    })
    .await;
    std::fs::write(root.path().join("crash"), b"crash").unwrap();
    release(root.path(), 1, 1);
    until(&w, |s| s.translation_queue_depth == 0).await;
    std::fs::write(root.path().join("finish"), b"go").unwrap();
    let done = until(&w, |s| s.phase == ViewPhase::Done).await;
    assert_eq!(done.translation_queue_depth, 0);
    assert_eq!(
        done.translation_backfill_remaining, 0,
        "dead client must not leave a backfill barrier pending"
    );
    assert_eq!(done.translation_backlog, 0);
    assert_eq!(done.lines.len(), 45);
    assert!(done.lines.iter().all(|l| l.line.translations.is_empty()));
    // Translation overlays share the owner's existing 33 ms render batch.
    let settled = until(&w, |s| {
        s.lines.len() == 45
            && s.lines
                .iter()
                .all(|l| l.line.suppressed_translations.contains("English"))
    })
    .await;
    assert!(settled.lines.iter().all(|l| l.line.translations.is_empty()));
    assert_eq!(
        std::fs::read_to_string(root.path().join("dna-launches"))
            .unwrap()
            .lines()
            .count(),
        1,
        "terminal failure must not trigger an unlimited restart loop"
    );
    w.shutdown().await.unwrap();
    p.shutdown().await.unwrap();
}

#[tokio::test]
async fn starter_faq_reaches_transcript_and_archive_without_a_model_turn() {
    let engine = WORDS.replace("안녕하세요 반가운 아침입니다.", "오늘 샤워해도 되나요?");
    let (root, w, p, source) = setup_with_engine(false, &engine).await;
    p.settings(SettingsCommand::TranslationTarget {
        language: Language::English,
        enabled: false,
    })
    .await
    .unwrap();
    p.settings(SettingsCommand::TranslationTarget {
        language: Language::Japanese,
        enabled: true,
    })
    .await
    .unwrap();
    start(&w, source).await;
    let done = until(&w, |s| {
        s.phase == ViewPhase::Done && s.lines[0].line.translations.contains_key("Japanese")
    })
    .await;
    assert_eq!(
        done.lines[0].line.translations["Japanese"],
        "今日、シャワーを浴びてもいいですか?"
    );
    assert_eq!(done.translation_queue_depth, 0);
    assert!(
        std::fs::read_to_string(done.archive.transcript.unwrap())
            .unwrap()
            .contains("今日、シャワーを浴びてもいいですか?")
    );
    marker(&root.path().join("dna-launches")).await;
    w.shutdown().await.unwrap();
    p.shutdown().await.unwrap();
    assert!(!root.path().join("dna-turn-1-1").exists());
}

#[tokio::test]
async fn a_partial_faq_hit_queues_only_the_missing_language_and_preserves_user_bank() {
    let entry = BTreeMap::from([
        ("Korean".into(), "안녕하세요 반가운 아침입니다.".into()),
        ("English".into(), "Cached English.".into()),
    ]);
    let (root, w, p, source) = setup_with_bank(false, WORDS, Some(vec![entry])).await;
    let bank = root.path().join("faq_translations.json");
    let before = std::fs::read(&bank).unwrap();
    p.settings(SettingsCommand::TranslationTarget {
        language: Language::Japanese,
        enabled: true,
    })
    .await
    .unwrap();
    start(&w, source).await;
    let done = until(&w, |s| {
        s.translation_queue_depth == 0 && s.lines[0].line.translations.len() == 2
    })
    .await;
    assert_eq!(
        done.lines[0].line.translations["English"],
        "Cached English."
    );
    assert_eq!(
        done.lines[0].line.translations["Japanese"],
        "日本語の回答です。"
    );
    assert!(
        std::fs::read_to_string(root.path().join("dna-turn-1-1"))
            .unwrap()
            .starts_with("%%TRN 2 ")
    );
    assert!(!root.path().join("dna-turn-1-2").exists());
    w.shutdown().await.unwrap();
    p.shutdown().await.unwrap();
    assert_eq!(std::fs::read(bank).unwrap(), before);
    let saved = std::fs::read_to_string(done.archive.transcript.unwrap()).unwrap();
    assert!(saved.contains("Cached English.") && saved.contains("日本語の回答です。"));
}
