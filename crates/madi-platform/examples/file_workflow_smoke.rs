//! Headless probe of the same timed file owner used by the Tauri host.
//! Native dialogs, clipboard, web rendering and real user settings are not exercised.
//! Setup restoration uses only a temporary preference file and synthetic legacy data.
use madi_platform::{
    asr_config::{FileSettings, Resources},
    file_session::Configuration,
    file_workflow::{ArchiveSettings, Edit, FileWorkflow, ViewPhase},
};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    io,
    path::PathBuf,
    time::{Duration, Instant},
};

#[tokio::main(flavor = "current_thread")]
async fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 7 {
        return Err(io::Error::other(
            "usage: file_workflow_smoke <engine> <model> <assets> <source-media> <scratch-parent> <decoder>",
        ));
    }
    let source = PathBuf::from(&args[4]);
    let original_sha = format!("{:x}", Sha256::digest(std::fs::read(&source)?));
    let model_before = std::fs::metadata(&args[2])?;
    let scratch = tempfile::Builder::new()
        .prefix("madi-workflow-probe-")
        .tempdir_in(&args[5])?;
    let assets = PathBuf::from(&args[3]);
    let archive_directory = tempfile::Builder::new()
        .prefix("madi-archive-probe-")
        .tempdir_in(&args[5])?;
    let preferences_directory = tempfile::Builder::new()
        .prefix("madi-preferences-probe-")
        .tempdir_in(&args[5])?;
    let preferences_path = preferences_directory.path().join("preferences.json");
    use madi_core::preferences::{
        Legacy, Preferences as SetupPreferences, PresentationCommand, UILanguage,
    };
    use madi_platform::{
        preferences::Store as SetupStore, preferences_service::PreferencesService,
    };
    let imported = SetupPreferences::from_legacy(Legacy {
        language_token_id: 50259,
        translate_targets: vec![
            "Korean".into(),
            "English".into(),
            "Chinese".into(),
            "Japanese".into(),
        ],
        meeting_mode: "lecture".into(),
        diarize_enabled: Some(true),
        transcript_view_mode: Some(false),
        transcript_font_size: Some(18.0),
        ..Legacy::default()
    });
    let initial = PreferencesService::new(
        SetupStore::load(preferences_path.clone(), imported)?,
        |_| {},
    )?;
    initial.stage(source.clone()).await?;
    initial
        .presentation(PresentationCommand::UILanguage(UILanguage::Ja))
        .await?;
    initial.shutdown().await?;
    let restored = PreferencesService::new(
        SetupStore::load(
            preferences_path,
            SetupPreferences::from_legacy(Legacy::default()),
        )?,
        |_| {},
    )?;
    let restored_snapshot = restored.snapshot();
    if restored_snapshot.setup.staged_file.is_some()
        || restored_snapshot.setup.input_device_id.is_some()
        || restored_snapshot.setup.translate_targets.len() != 4
        || !restored_snapshot.setup.diarize
        || restored_snapshot.presentation.content_mode
        || restored_snapshot.presentation.font_size != 18.0
        || restored_snapshot.presentation.ui_language != UILanguage::Ja
    {
        return Err(io::Error::other("isolated preference restoration failed"));
    }
    restored.stage(source.clone()).await?;
    let (selected_source, restored_setup) = restored
        .take_file()
        .await?
        .ok_or_else(|| io::Error::other("restored file admission missing"))?;
    let restored_settings =
        FileSettings::from_setup(&restored_setup, true, 0, Vec::new()).map_err(io::Error::other)?;
    if selected_source != source || restored_settings.language_token != Some(50259) {
        return Err(io::Error::other("restored settings not admitted"));
    }
    restored.shutdown().await?;
    let (events, mut updates) = tokio::sync::mpsc::unbounded_channel();
    let began = Instant::now();
    let workflow = FileWorkflow::with_archive(
        Configuration {
            resources: Resources {
                executable: PathBuf::from(&args[1]),
                model: PathBuf::from(&args[2]),
                bpe: assets.join("WHISPER_BPE.bin"),
                assets,
            },
            decoder: PathBuf::from(&args[6]),
            scratch_parent: scratch.path().to_owned(),
        },
        Some(ArchiveSettings {
            enabled: true,
            folder: archive_directory.path().to_owned(),
        }),
        move |snapshot| {
            let _ = events.send((began.elapsed().as_secs_f64(), snapshot));
        },
    )?;
    let execution = async {
        let started = workflow
            .start(selected_source, restored_settings, None)
            .await?;
        let mut observations = Vec::new();
        let done = loop {
            let (elapsed, state) = updates
                .recv()
                .await
                .ok_or_else(|| io::Error::other("workflow ended without terminal state"))?;
            observations.push(json!({"elapsed":elapsed,"revision":state.revision,"phase":state.phase,"lines":state.lines.len(),"words":state.lines.iter().map(|line|line.line.words.len()).sum::<usize>()}));
            match &state.phase {
                ViewPhase::Done => break state,
                ViewPhase::Error { message } => return Err(io::Error::other(message.clone())),
                _ => (),
            }
        };
        if done.lines.is_empty() || std::fs::read_dir(scratch.path())?.next().is_some() {
            return Err(io::Error::other(
                "empty transcript or scratch retained at completion",
            ));
        }
        let line_id = done.lines[0].line.id;
        let saved = done
            .archive
            .transcript
            .clone()
            .ok_or_else(|| io::Error::other("completion archive missing"))?;
        let archive_bytes = std::fs::read(&saved)?;
        let archive_sha = format!("{:x}", Sha256::digest(&archive_bytes));
        let changed_text = format!("{} [probe edit]", done.lines[0].text);
        workflow
            .edit(
                started.generation,
                Edit::Line {
                    id: line_id.to_string(),
                    text: changed_text.clone(),
                },
            )
            .await?;
        let edited = loop {
            let (_, snapshot) = updates
                .recv()
                .await
                .ok_or_else(|| io::Error::other("edit publication missing"))?;
            if snapshot
                .lines
                .first()
                .is_some_and(|line| line.text == changed_text)
            {
                break snapshot;
            }
        };
        if std::fs::read(&saved)? != archive_bytes {
            return Err(io::Error::other(
                "inline edit unexpectedly changed the saved file",
            ));
        }
        // Traverse only the owned temporary archive, using the production
        // workspace scanner/owner and its generation-bound row authorization.
        use madi_platform::{
            transcript_export::Format,
            workspace_preferences::{Preferences, Store},
            workspace_service::{Change, Workspace},
        };
        let prefs_path = archive_directory.path().join("workspace.json");
        let fallback =
            Preferences::from_legacy(Default::default(), archive_directory.path().to_owned());
        let workspace = Workspace::new(Store::load(prefs_path.clone(), fallback.clone())?, |_| {});
        while workspace.snapshot().loading {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let list = workspace.snapshot();
        if list.entries.len() != 1 {
            return Err(io::Error::other("saved meeting missing from workspace"));
        }
        let path = workspace
            .resolve(list.generation, &list.entries[0].id)
            .ok_or_else(|| io::Error::other("workspace row could not resolve"))?;
        if path.canonicalize()? != saved.canonicalize()?
            || workspace
                .resolve(list.generation + 1, &list.entries[0].id)
                .is_some()
        {
            return Err(io::Error::other("workspace path authority failed"));
        }
        workspace.show_stats(true)?;
        while workspace.snapshot().stats.meeting_count != 1 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let stats = workspace.snapshot();
        let mut exports = Vec::new();
        let export_folder = tempfile::Builder::new()
            .prefix("madi-export-probe-")
            .tempdir_in(&args[5])?;
        for format in [
            Format::Md,
            Format::Srt,
            Format::Vtt,
            Format::Txt,
            Format::Json,
        ] {
            let path = export_folder
                .path()
                .join(format!("transcript.{}", format.extension()));
            workflow
                .export_to(done.generation, path.clone(), format, Default::default())
                .await?;
            let bytes = std::fs::read(&path)?;
            if bytes.is_empty() {
                return Err(io::Error::other("manual export was empty"));
            }
            if matches!(format, Format::Json) {
                let value: serde_json::Value = serde_json::from_slice(&bytes)?;
                if value["segments"][0]["text"] != changed_text {
                    return Err(io::Error::other("manual export missed edit"));
                }
            }
            exports.push(json!({"format":format,"bytes":bytes.len(),"sha256":format!("{:x}",Sha256::digest(&bytes))}));
        }
        workspace
            .change(
                None,
                Change {
                    auto_save: Some(false),
                    ..Default::default()
                },
            )
            .await?;
        workspace.shutdown().await?;
        if Store::load(prefs_path, fallback)?.value().auto_save {
            return Err(io::Error::other(
                "isolated workspace preference did not persist",
            ));
        }
        let reopened = workflow
            .open_archive(done.generation, saved.clone())
            .await?;
        if reopened.phase != ViewPhase::Done
            || reopened.generation == done.generation
            || reopened.archive.transcript.is_some()
            || reopened.lines.len() != done.lines.len()
            || reopened
                .lines
                .iter()
                .zip(&done.lines)
                .any(|(a, b)| a.text != b.text)
            || std::fs::read(&saved)? != archive_bytes
        {
            return Err(io::Error::other("archive reopen or preservation failed"));
        }
        let reset = workflow.reset(reopened.generation).await?;
        let stale = workflow
            .edit(
                started.generation,
                Edit::Line {
                    id: line_id.to_string(),
                    text: "stale probe".into(),
                },
            )
            .await?;
        if edited.lines[0].line.id != line_id
            || reset.phase != ViewPhase::Idle
            || !reset.lines.is_empty()
            || stale.generation != reset.generation
            || !stale.lines.is_empty()
        {
            return Err(io::Error::other("edit/reset/generation invariant failed"));
        }
        Ok(
            json!({"observations":observations,"completed":done,"edited":edited,"reset":reset,"staleEditIgnored":true,"cleanAtCompletion":true,
                "workspace":{"entries":list.entries.len(),"stats":stats.stats,"staleRowRejected":true,"isolatedPreferencePersisted":true,"exports":exports},
                "archive":{"bytes":archive_bytes.len(),"sha256":archive_sha,"reopened":reopened,"sourcePreserved":true,"inlineEditDidNotAutosave":true,"reopenDidNotClaimWritableTarget":true}}),
        )
    };
    let result = tokio::time::timeout(Duration::from_secs(120), execution).await;
    let shutdown = workflow.shutdown().await;
    let result = result.map_err(io::Error::other)??;
    shutdown?;
    let preserved = original_sha == format!("{:x}", Sha256::digest(std::fs::read(&source)?));
    let model_after = std::fs::metadata(&args[2])?;
    let model_unchanged = model_before.len() == model_after.len()
        && model_before.modified()? == model_after.modified()?;
    let clean = std::fs::read_dir(scratch.path())?.next().is_none();
    println!(
        "{}",
        serde_json::to_string_pretty(
            &json!({"schema":3,"preferences":{"restored":restored_snapshot,"nativeFileAdmission":true,"isolatedRelaunch":true},"passed":preserved && model_unchanged && clean,"sourceSha256":original_sha,"sourcePreserved":preserved,"modelSizeMtimeUnchanged":model_unchanged,"cleanAtShutdown":clean,"workflow":result})
        )?
    );
    if !preserved || !model_unchanged || !clean {
        return Err(io::Error::other("resource preservation failed"));
    }
    Ok(())
}
