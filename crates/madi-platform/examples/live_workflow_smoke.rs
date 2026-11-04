//! Same presentation/archive owner as the Tauri host, real native replay + ASR.
//! Debug-only, never opens a microphone, permission dialog or production settings.
#[cfg(all(target_os = "macos", debug_assertions))]
mod probe {
    use madi_platform::{
        asr_config::{FileSettings, LiveSettings, Resources},
        audio_capture::pump_verification_run_loop,
        file_session::Configuration,
        file_workflow::{ArchiveSettings, Edit, FileWorkflow, ViewPhase},
        live_session::{Input, Request},
        transcript_export::Format,
    };
    use serde_json::json;
    use sha2::{Digest, Sha256};
    use std::{future::Future, io, path::PathBuf, time::Duration};
    async fn drive<T>(main: objc2::MainThreadMarker, future: impl Future<Output = T>) -> T {
        tokio::pin!(future);
        let mut tick = tokio::time::interval(Duration::from_millis(2));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {result=&mut future=>return result, _=tick.tick()=>pump_verification_run_loop(main)}
        }
    }
    pub async fn run() -> io::Result<()> {
        let args: Vec<_> = std::env::args_os().collect();
        if args.len() != 6 {
            return Err(io::Error::other(
                "usage: live_workflow_smoke <engine> <model> <assets> <source-media> <scratch-parent>",
            ));
        }
        let main = objc2::MainThreadMarker::new()
            .ok_or_else(|| io::Error::other("main thread required"))?;
        let scratch = tempfile::Builder::new()
            .prefix("madi-live-workflow-")
            .tempdir_in(&args[5])?;
        let archives = tempfile::Builder::new()
            .prefix("madi-live-archives-")
            .tempdir_in(&args[5])?;
        let assets = PathBuf::from(&args[3]).canonicalize()?;
        let source = PathBuf::from(&args[4]).canonicalize()?;
        let original_sha = format!("{:x}", Sha256::digest(std::fs::read(&source)?));
        let model = PathBuf::from(&args[2]).canonicalize()?;
        let before = std::fs::metadata(&model)?;
        let executable = PathBuf::from(&args[1]).canonicalize()?;
        let (send, mut updates) = tokio::sync::mpsc::unbounded_channel();
        let workflow = FileWorkflow::with_archive(
            Configuration {
                resources: Resources {
                    executable: executable.clone(),
                    model: model.clone(),
                    bpe: assets.join("WHISPER_BPE.bin"),
                    assets,
                },
                decoder: executable,
                scratch_parent: scratch.path().to_owned(),
            },
            Some(ArchiveSettings {
                enabled: true,
                folder: archives.path().to_owned(),
            }),
            move |snapshot| {
                let _ = send.send(snapshot);
            },
        )?;
        workflow
            .start_live(
                Request {
                    settings: LiveSettings {
                        common: FileSettings::default(),
                        language_candidates: Vec::new(),
                    },
                    capture: Default::default(),
                    input: Input::Replay {
                        path: source.clone(),
                        chunk_frames: 4096,
                    },
                },
                None,
            )
            .await?;
        let mut phases = Vec::new();
        let mut had_level = false;
        let execution = async {
            while let Some(state) = updates.recv().await {
                if phases.last() != Some(&state.phase) {
                    phases.push(state.phase.clone());
                }
                had_level |= state.live.as_ref().is_some_and(|l| l.meter > 0.0);
                match state.phase {
                    ViewPhase::Done => return Ok(state),
                    ViewPhase::Error { message } => return Err(io::Error::other(message)),
                    _ => (),
                }
            }
            Err(io::Error::other("workflow closed early"))
        };
        let done = drive(
            main,
            tokio::time::timeout(Duration::from_secs(120), execution),
        )
        .await
        .map_err(io::Error::other)??;
        let archive = done
            .archive
            .transcript
            .clone()
            .ok_or_else(|| io::Error::other("missing automatic archive"))?;
        let archive_text = std::fs::read_to_string(&archive)?;
        let archive_name = archive.file_name().unwrap().to_string_lossy().into_owned();
        let timestamped_name = madi_core::personal_vocabulary::canonically_equal(
            archive_name.split(' ').next().unwrap(),
            "회의",
        );
        // Native Markdown marks low-confidence words with italics. Compare the
        // actual archive serialization, then independently reopen its text below.
        let saved_matches = !done.lines.is_empty()
            && archive_text
                == madi_core::transcript::archive::markdown(
                    &done
                        .lines
                        .iter()
                        .map(|line| line.line.clone())
                        .collect::<Vec<_>>(),
                    &done.speaker_names,
                    None,
                );
        let first = done
            .lines
            .first()
            .ok_or_else(|| io::Error::other("no lines"))?;
        let edit = format!("Reviewed: {}", first.text);
        workflow
            .edit(
                done.generation,
                Edit::Line {
                    id: first.line.id.to_string(),
                    text: edit.clone(),
                },
            )
            .await?;
        workflow
            .edit(
                done.generation,
                Edit::SpeakerName {
                    speaker: first.line.speaker,
                    name: "JFK test".into(),
                },
            )
            .await?;
        let mut exports = Vec::new();
        for format in [
            Format::Md,
            Format::Srt,
            Format::Vtt,
            Format::Txt,
            Format::Json,
        ] {
            let rendered = workflow
                .render_export(done.generation, format, Default::default())
                .await?
                .ok_or_else(|| io::Error::other("missing export"))?;
            // Captions wrap text and add timecodes. Every format must retain
            // the edit marker; an unwrapped full-line substring is not required.
            let contains_edit = rendered.contains("Reviewed:");
            exports.push(json!({"format":format,"bytes":rendered.len(),"containsEdit":contains_edit,"sha256":format!("{:x}",Sha256::digest(rendered.as_bytes()))}));
        }
        let reset = drive(main, workflow.reset(done.generation)).await?;
        let reopened = workflow.open_archive(reset.generation, archive).await?;
        let reopen_matches = reopened.live.is_none()
            && reopened
                .lines
                .iter()
                .map(|l| &l.text)
                .eq(done.lines.iter().map(|l| &l.text));
        drive(main, workflow.shutdown()).await?;
        let clean = std::fs::read_dir(scratch.path())?.next().is_none();
        let original_unchanged =
            original_sha == format!("{:x}", Sha256::digest(std::fs::read(&source)?));
        let after = std::fs::metadata(model)?;
        let model_unchanged =
            before.len() == after.len() && before.modified()? == after.modified()?;
        let expected = vec![
            ViewPhase::Idle,
            ViewPhase::CountingDown { remaining: 3 },
            ViewPhase::CountingDown { remaining: 2 },
            ViewPhase::CountingDown { remaining: 1 },
            ViewPhase::EngineStarting,
            ViewPhase::Ready,
            ViewPhase::Recording,
            ViewPhase::Flushing,
            ViewPhase::Done,
        ];
        let passed = timestamped_name
            && phases == expected
            && had_level
            && saved_matches
            && reopen_matches
            && clean
            && original_unchanged
            && model_unchanged
            && exports.iter().all(|e| e["containsEdit"] == true);
        println!(
            "{}",
            serde_json::to_string_pretty(
                &json!({"schemaVersion":1,"status":if passed {"passed"} else {"failed"},"scope":"Real native replay and resident Metal ASR through the shared timed transcript owner, automatic archive, editing, five exports and archive reopen; no microphone/TCC or WebView acceptance","phases":phases,"levelPublished":had_level,"lines":done.lines.len(),"transcript":done.lines.iter().map(|l|&l.text).collect::<Vec<_>>(),"timestampedArchiveName":timestamped_name,"archiveFileName":archive_name,"archiveMatchesFinalTranscript":saved_matches,"reopenedArchiveMatches":reopen_matches,"exports":exports,"scratchEmptyAfterShutdown":clean,"fixtureSHA256":original_sha,"originalUnchanged":original_unchanged,"modelSizeMtimeUnchanged":model_unchanged,"devicesOpened":false})
            )?
        );
        if passed {
            Ok(())
        } else {
            Err(io::Error::other("live workflow smoke failed"))
        }
    }
}
#[cfg(all(target_os = "macos", debug_assertions))]
#[tokio::main(flavor = "current_thread")]
async fn main() -> std::io::Result<()> {
    probe::run().await
}
#[cfg(not(all(target_os = "macos", debug_assertions)))]
fn main() -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "debug macOS native replay required",
    ))
}
