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
 prefix='Previous ' if n==1 else 'Fresh '
 os.write(1,('[perf] prefill: 1 tok\n'+prefix).encode())
 if (root/'hold').exists():
  while not (root/f'release-{generation}-{n}').exists():time.sleep(.005)
 os.write(1,b'reply.\n[perf] generation: 3 tok\n> ')
"#;
async fn setup(hold: bool) -> (tempfile::TempDir, FileWorkflow, PreferencesService, PathBuf) {
    setup_with_engine(hold, WORDS).await
}
async fn setup_with_engine(
    hold: bool,
    engine: &str,
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
