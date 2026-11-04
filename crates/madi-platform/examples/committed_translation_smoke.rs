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
    if args.len() != 5 {
        return Err(io::Error::other(
            "usage: committed_translation_smoke <executables> <assets> <model-directory> <public-media> <report.json>",
        ));
    }
    let bin = &args[0];
    let assets = &args[1];
    let model = &args[2];
    let source = &args[3];
    let report = &args[4];
    let scratch = tempfile::tempdir()?;
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
    let w = FileWorkflow::with_translation(
        configuration,
        Some(ArchiveSettings {
            enabled: true,
            folder: scratch.path().join("archives"),
        }),
        Some(translation::Resources::new(
            Locations {
                bundle_resources: assets.clone(),
                bundle_executables: bin.clone(),
                support: model.clone(),
            },
            TranslationVariant::Quality4B,
        )),
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
    if !unchanged
        || !saved_all
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
        "scope":"Real public audio through FileWorkflow ASR, committed translation and archive; GUI/live microphone/interim/FAQ are not exercised",
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
