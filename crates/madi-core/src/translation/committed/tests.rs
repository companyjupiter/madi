use super::*;
use crate::translation::client::Translation;

fn line(id: u128, text: &str, start: f64) -> Line {
    Line {
        id: Uuid::from_u128(id),
        speaker: 0,
        start,
        end: start + 1.0,
        words: vec![],
        overlap_speakers: vec![],
        speaker_margin: 1.0,
        translations: BTreeMap::new(),
        stale_translations: BTreeMap::new(),
        edited_translations: BTreeSet::new(),
        suppressed_translations: BTreeSet::new(),
        edited_text: Some(text.into()),
    }
}
fn result(job: &Request, language: &str, text: &str) -> Effect {
    Effect::Result(Translation {
        id: job.id,
        source: job.text.clone(),
        language: language.into(),
        text: text.into(),
    })
}
#[test]
fn fragment_translation_is_bound_to_anchor_revision_and_stale_results_cannot_suppress_edits() {
    let mut store = TranscriptStore::default();
    store.load(vec![
        line(1, "And", 0.0),
        line(2, "we discuss this today.", 1.0),
    ]);
    let mut s = Session::default();
    let targets = vec!["Korean".into(), "English".into()];
    let requests = s.stable(&mut store, &targets, Some(50259), "", true, true);
    assert_eq!(requests.len(), 1);
    let job = &requests[0];
    assert_eq!(job.id, Uuid::from_u128(2));
    assert_eq!(job.text, "And we discuss this today.");
    assert_eq!(job.targets, ["Korean"]);
    assert!(store.lines()[0].suppressed_translations.contains("Korean"));
    s.handle(&mut store, &result(job, "Korean", "오늘 이야기합니다."));
    assert_eq!(
        store.lines()[1].translations["Korean"],
        "오늘 이야기합니다."
    );
    store.edit_line(job.id, "A different source sentence.", None);
    store.set_translation(job.id, "Korean".into(), "직접 편집한 번역", None, true);
    s.handle(&mut store, &result(job, "Korean", ""));
    s.handle(&mut store, &result(job, "Korean", "late stale reply"));
    assert_eq!(store.lines()[1].translations["Korean"], "직접 편집한 번역");
}
#[test]
fn stop_backfill_tracks_each_language_revision_and_discards_stale_work() {
    let mut store = TranscriptStore::default();
    store.load(vec![
        line(1, "안녕하세요 반가운 아침입니다.", 0.0),
        line(2, "수정될 예전 문장입니다.", 5.0),
    ]);
    let mut s = Session::default();
    let targets = vec!["English".into(), "Japanese".into(), "Korean".into()];
    let jobs = s.stable(&mut store, &targets, Some(50264), "", true, true);
    for job in &jobs {
        for lang in &job.targets {
            s.handle(
                &mut store,
                &Effect::Drop {
                    id: job.id,
                    language: lang.clone(),
                    source: job.text.clone(),
                },
            );
        }
    }
    assert_eq!(s.backlog_lines(), 2);
    store.edit_line(jobs[1].id, "새로운 내용으로 변경했습니다.", None);
    let retry = s.backfill(&mut store, &targets, Some(50264), true);
    assert_eq!(retry.len(), 1);
    assert_eq!(s.backlog_lines(), 0);
    assert_eq!(s.backfill_remaining(), 2);
    s.handle(&mut store, &result(&retry[0], "English", "Good morning."));
    assert_eq!(s.backfill_remaining(), 1);
    s.handle(&mut store, &result(&retry[0], "Japanese", ""));
    assert_eq!(s.backfill_remaining(), 0);
    assert!(
        store.lines()[0]
            .suppressed_translations
            .contains("Japanese")
    );
}
#[test]
fn missing_model_does_not_claim_the_revision_and_live_scan_defers_the_tail() {
    let mut store = TranscriptStore::default();
    store.load(vec![
        line(1, "A complete English sentence.", 0.0),
        line(2, "Another complete English sentence.", 6.0),
    ]);
    let targets = vec!["Japanese".into()];
    let mut s = Session::default();
    assert!(
        s.stable(&mut store, &targets, None, "", false, false)
            .is_empty()
    );
    let first = s.stable(&mut store, &targets, None, "", false, true);
    assert_eq!(first.len(), 1);
    assert_eq!(first[0].id, Uuid::from_u128(1));
    assert!(
        s.stable(&mut store, &targets, None, "", false, true)
            .is_empty()
    );
    let final_jobs = s.stable(&mut store, &targets, None, "", true, true);
    assert_eq!(final_jobs.len(), 1);
    assert_eq!(final_jobs[0].id, Uuid::from_u128(2));
}

#[test]
fn cache_closes_only_applied_backfill_keys_and_never_rewrites_a_joined_run() {
    let mut store = TranscriptStore::default();
    store.load(vec![line(1, "안녕하세요 반가운 아침입니다.", 0.0)]);
    let targets = vec!["English".into(), "Japanese".into()];
    let mut s = Session::default();
    let jobs = s.stable(&mut store, &targets, Some(50264), "", true, true);
    for lang in &jobs[0].targets {
        s.handle(
            &mut store,
            &Effect::Drop {
                id: jobs[0].id,
                language: lang.clone(),
                source: jobs[0].text.clone(),
            },
        );
    }
    let mut backfill = s.backfill(&mut store, &targets, Some(50264), true);
    let cached = BTreeMap::from([("English".into(), "Cached answer.".into())]);
    s.apply_cached(&mut store, &mut backfill[0], &cached);
    assert_eq!(s.backfill_remaining(), 1);
    assert_eq!(backfill[0].targets, ["Japanese"]);
    assert_eq!(store.lines()[0].translations["English"], "Cached answer.");
    s.handle(
        &mut store,
        &result(&backfill[0], "Japanese", "日本語です。"),
    );
    assert_eq!(s.backfill_remaining(), 0);
    store.load(vec![
        line(1, "And", 0.0),
        line(2, "we discuss this today.", 1.0),
    ]);
    s = Session::default();
    let mut joined = s.stable(&mut store, &["Korean".into()], Some(50259), "", true, true);
    assert!(!joined[0].cacheable);
    s.apply_cached(
        &mut store,
        &mut joined[0],
        &BTreeMap::from([("Korean".into(), "must not apply".into())]),
    );
    assert_eq!(joined[0].targets, ["Korean"]);
    assert!(store.lines()[1].translations.is_empty());
}
