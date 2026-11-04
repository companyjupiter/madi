//! Real ASR -> committed translation -> archive probe through the desktop owner.
//! Uses public test audio and isolated preferences/archive; no GUI or microphone.
use madi_core::{
    assets::TranslationVariant,
    preferences::{Legacy, Preferences},
};
use madi_platform::{
    asr_config::{FileSettings, Resources},
    file_session::Configuration,
    file_workflow::{ArchiveSettings, FileWorkflow, ViewPhase, translation},
    model_assets::Locations,
    preferences::Store,
    preferences_service::PreferencesService,
};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    io,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
fn hash(path: &Path) -> io::Result<String> {
    Ok(format!("{:x}", Sha256::digest(std::fs::read(path)?)))
}
#[tokio::main(flavor = "current_thread")]
async fn main() -> io::Result<()> {
    let args: Vec<PathBuf> = std::env::args_os().skip(1).map(PathBuf::from).collect();
    let faq_mode = args.len() == 6 && args[5] == Path::new("public-faq");
    if args.len() != 5 && !faq_mode {
        return Err(io::Error::other(
            "usage: committed_translation_smoke <executables> <assets> <model-directory> <public-media> <report.json> [public-faq]",
        ));
    }
    let bin = &args[0];
    let assets = &args[1];
    let model = &args[2];
    let source = &args[3];
    let report = &args[4];
    let scratch = tempfile::tempdir()?;
    let faq_path = scratch.path().join("faq.json");
    let cached_text = "공개 연설에 미리 지정한 테스트 번역입니다.";
    let faq_bytes = serde_json::to_vec(&json!([{
        "English": "And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.",
        "Korean": cached_text,
    }]))?;
    if faq_mode {
        std::fs::write(&faq_path, &faq_bytes)?;
    }
    let preferences = PreferencesService::new(
        Store::load(
            scratch.path().join("preferences.json"),
            Preferences::from_legacy(Legacy {
                language_token_id: 50259,
                translate_targets: vec!["Korean".into()],
                ..Default::default()
            }),
        )?,
        |_| {},
    )?;
    let configuration = Configuration {
        resources: Resources {
            executable: bin.join("transcribe"),
            model: model.join("model.q8.safetensors"),
            assets: assets.clone(),
            bpe: assets.join("WHISPER_BPE.bin"),
        },
        decoder: bin.join("madi-audio-decode"),
        scratch_parent: scratch.path().into(),
    };
    let (tx, mut changes) = tokio::sync::mpsc::unbounded_channel();
    let mut translation_resources = translation::Resources::new(
        Locations {
            bundle_resources: assets.clone(),
            bundle_executables: bin.clone(),
            support: model.clone(),
        },
        TranslationVariant::Quality4B,
    );
    if faq_mode {
        translation_resources = translation_resources.with_faq_path(faq_path.clone());
    }
    let w = FileWorkflow::with_translation(
        configuration,
        Some(ArchiveSettings {
            enabled: true,
            folder: scratch.path().join("archives"),
        }),
        Some(translation_resources),
        move |s| {
            let _ = tx.send(s);
        },
    )?;
    w.set_preferences(preferences.clone()).await?;
    let original = hash(source)?;
    let started = Instant::now();
    w.start(
        source.clone(),
        FileSettings {
            language_token: Some(50259),
            ..Default::default()
        },
        None,
    )
    .await?;
    let result = tokio::time::timeout(Duration::from_secs(180), async {
        while let Some(s) = changes.recv().await {
            if let ViewPhase::Error { message } = &s.phase {
                return Err(io::Error::other(message.clone()));
            }
            if s.phase == ViewPhase::Done
                && s.translation_queue_depth == 0
                && !s.lines.is_empty()
                && s.lines
                    .iter()
                    .any(|l| l.line.translations.contains_key("Korean"))
                && s.lines.iter().all(|l| {
                    l.line.translations.contains_key("Korean")
                        || l.line.suppressed_translations.contains("Korean")
                })
            {
                return Ok(s);
            }
        }
        Err(io::Error::other("workflow ended before translations"))
    })
    .await
    .map_err(io::Error::other)
    .and_then(|r| r);
    w.shutdown().await?;
    preferences.shutdown().await?;
    let snapshot = result?;
    let unchanged = original == hash(source)?;
    let archive = snapshot
        .archive
        .transcript
        .as_ref()
        .ok_or_else(|| io::Error::other("missing archive"))?;
    let markdown = std::fs::read_to_string(archive)?;
    let saved_all = snapshot
        .lines
        .iter()
        .flat_map(|l| l.line.translations.values())
        .all(|text| markdown.contains(text));
    let faq_unchanged = faq_mode
        .then(|| std::fs::read(&faq_path))
        .transpose()?
        .map(|bytes| bytes == faq_bytes);
    let exact_cache_hit = faq_mode.then(|| {
        snapshot.lines.iter().any(|l| {
            l.line
                .translations
                .get("Korean")
                .is_some_and(|s| s == cached_text)
        })
    });
    if !unchanged
        || !saved_all
        || faq_unchanged == Some(false)
        || exact_cache_hit == Some(false)
        || snapshot.translation_backlog != 0
        || snapshot.translation_backfill_remaining != 0
    {
        return Err(io::Error::other(
            "source preservation or final translation archive mismatch",
        ));
    }
    let archive_copy = report.with_extension("md");
    std::fs::write(&archive_copy, &markdown)?;
    let value = json!({
        "status":"PASS", "elapsedSeconds":started.elapsed().as_secs_f64(),
        "scope":if faq_mode { "Real public audio through FileWorkflow ASR, isolated FAQ and archive; preset test translation, not model inference or translation quality" } else { "Real public audio through FileWorkflow ASR, committed translation and archive; GUI/live microphone/interim/FAQ are not exercised" },
        "faqMode":faq_mode,"faqUnchanged":faq_unchanged,"exactCacheHit":exact_cache_hit,
        "source":source,"sourceSHA256":original,"sourceUnchanged":unchanged,
        "archive":archive_copy,"archiveSHA256":format!("{:x}",Sha256::digest(markdown.as_bytes())),"allTranslationsSaved":saved_all,
        "transcribeSHA256":hash(&bin.join("transcribe"))?,"translationEngineSHA256":hash(&bin.join("translate-engine-4b"))?,"decoderSHA256":hash(&bin.join("madi-audio-decode"))?,
        "queueDepth":snapshot.translation_queue_depth,"backlog":snapshot.translation_backlog,"backfillRemaining":snapshot.translation_backfill_remaining,
        "lines":snapshot.lines,"archiveError":snapshot.archive.error,
    });
    std::fs::write(report, serde_json::to_vec_pretty(&value)?)?;
    println!(
        "{}",
        serde_json::to_string(
            &json!({"status":"PASS","report":report,"seconds":value["elapsedSeconds"],"lines":value["lines"].as_array().unwrap().len()})
        )?
    );
    Ok(())
}
