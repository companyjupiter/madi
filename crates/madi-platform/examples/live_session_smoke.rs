//! Debug-only real AVAudioFile/Resampler -> Rust capture/WAV -> resident Metal ASR.
//! No microphone, SCStream, device permission or WebView is opened.
#[cfg(all(target_os = "macos", debug_assertions))]
mod probe {
    use madi_core::{capture_stream, session::Phase, transcript::TranscriptStore};
    use madi_platform::{
        asr_config::{FileSettings, LiveSettings, Resources},
        audio_capture::pump_verification_run_loop,
        live_session::{Configuration, Input, LiveSession, Request, UpdateKind},
    };
    use madi_protocol::{stream::Output, structured, transcribe};
    use serde_json::json;
    use sha2::{Digest, Sha256};
    use std::{future::Future, io, path::PathBuf, time::Duration};

    async fn drive<T>(main: objc2::MainThreadMarker, future: impl Future<Output = T>) -> T {
        tokio::pin!(future);
        let mut tick = tokio::time::interval(Duration::from_millis(2));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                result=&mut future=>return result,
                _=tick.tick()=>pump_verification_run_loop(main),
            }
        }
    }
    pub async fn run() -> io::Result<()> {
        let args: Vec<_> = std::env::args_os().collect();
        if args.len() != 6 {
            return Err(io::Error::other(
                "usage: live_session_smoke <engine> <model> <assets> <source-media> <scratch-parent>",
            ));
        }
        let main = objc2::MainThreadMarker::new()
            .ok_or_else(|| io::Error::other("native replay requires main thread"))?;
        let scratch = tempfile::Builder::new()
            .prefix("madi-live-session-probe-")
            .tempdir_in(&args[5])?;
        let assets = PathBuf::from(&args[3]).canonicalize()?;
        let input = PathBuf::from(&args[4]).canonicalize()?;
        let input_sha = format!("{:x}", Sha256::digest(std::fs::read(&input)?));
        let model = PathBuf::from(&args[2]).canonicalize()?;
        let model_before = std::fs::metadata(&model)?;
        let mut session = LiveSession::new(Configuration {
            resources: Resources {
                executable: PathBuf::from(&args[1]).canonicalize()?,
                model: model.clone(),
                bpe: assets.join("WHISPER_BPE.bin"),
                assets,
            },
            scratch_parent: scratch.path().to_owned(),
        })?;
        let run = session
            .start(Request {
                settings: LiveSettings {
                    common: FileSettings::default(),
                    language_candidates: Vec::new(),
                },
                capture: capture_stream::Configuration::default(),
                input: Input::Replay {
                    path: input.clone(),
                    chunk_frames: 4096,
                },
            })
            .await?
            .ok_or_else(|| io::Error::other("new live session was busy"))?;
        let mut phases = Vec::new();
        let mut words = 0;
        let mut finished = 0;
        let mut failed = 0;
        let mut faults = Vec::new();
        let mut segments = Vec::new();
        let mut wavs = Vec::new();
        let mut transcript = TranscriptStore::default();
        let mut level_events = 0;
        let mut retained_paths = Vec::new();
        let execution = async {
            while let Some(update) = session.next().await {
                assert_eq!(update.run, run);
                match update.kind {
                    UpdateKind::Phase(phase) => phases.push(phase),
                    UpdateKind::Level(_) => level_events += 1,
                    UpdateKind::Output(Output::Stdout(event)) => {
                        if matches!(event, transcribe::Event::Word { .. }) {
                            words += 1;
                        }
                        transcript.ingest(&event);
                    }
                    UpdateKind::Output(Output::Structured(structured::Event::Segment(segment))) => {
                        segments.push(segment.text)
                    }
                    UpdateKind::Segment {
                        offset,
                        wav,
                        had_speech,
                    } => {
                        let bytes = std::fs::read(wav.path())?;
                        wavs.push(json!({"offset":offset,"hadSpeech":had_speech,"bytes":bytes.len(),"sha256":format!("{:x}",Sha256::digest(&bytes))}));
                        retained_paths.push(wav.path().to_owned());
                    }
                    UpdateKind::Finished => {
                        transcript.flush_pending_speaker_fix_rebuild();
                        transcript.finalize();
                        finished += 1;
                        break;
                    }
                    UpdateKind::Failed => {
                        failed += 1;
                        break;
                    }
                    UpdateKind::Fault(message)
                    | UpdateKind::CaptureInterrupted(message)
                    | UpdateKind::WriteFailed { message, .. } => {
                        faults.push(message);
                        break;
                    }
                    UpdateKind::FlushTimedOut => {
                        faults.push("flush deadline elapsed".into());
                        break;
                    }
                    _ => {}
                }
            }
            Ok::<(), io::Error>(())
        };
        let timed_out = match drive(
            main,
            tokio::time::timeout(Duration::from_secs(120), execution),
        )
        .await
        {
            Ok(Ok(())) => false,
            Ok(Err(e)) => {
                faults.push(e.to_string());
                false
            }
            Err(_) => true,
        };
        let retained_at_done =
            !retained_paths.is_empty() && retained_paths.iter().all(|p| p.is_file());
        if let Err(e) = drive(main, session.shutdown()).await {
            faults.push(e.to_string());
        }
        let clean = std::fs::read_dir(scratch.path())?.next().is_none();
        let input_unchanged = input_sha == format!("{:x}", Sha256::digest(std::fs::read(input)?));
        let model_after = std::fs::metadata(model)?;
        let model_unchanged = model_before.len() == model_after.len()
            && model_before.modified()? == model_after.modified()?;
        let passed = !timed_out
            && finished == 1
            && failed == 0
            && faults.is_empty()
            && words > 0
            && !segments.is_empty()
            && !transcript.lines().is_empty()
            && transcript.lines() == transcript.display_lines()
            && level_events > 0
            && phases
                == [
                    Phase::EngineStarting,
                    Phase::Ready,
                    Phase::Recording,
                    Phase::Flushing,
                    Phase::Done,
                ]
            && retained_at_done
            && clean
            && input_unchanged
            && model_unchanged;
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "schemaVersion":1,"status":if passed {"passed"} else {"failed"},
                "scope":"Native replay/conversion, Rust live-session executor, owned WAV feed and real resident Metal ASR; no hardware, permissions, previews, translation, watchdog, archive or Tauri UI acceptance",
                "phases":phases.iter().map(|p|format!("{p:?}")).collect::<Vec<_>>(),"segments":segments,"wordEvents":words,
                "wavSegments":wavs,"levelEvents":level_events,"transcript":transcript.lines(),"transcriptText":transcript.lines().iter().map(|l|l.text()).collect::<Vec<_>>(),
                "finishedCallbacks":finished,"failedCallbacks":failed,"faults":faults,"timedOut":timed_out,
                "segmentFilesRetainedAtDone":retained_at_done,"ownedScratchEmptyAfterShutdown":clean,
                "fixtureSHA256":input_sha,"originalUnchanged":input_unchanged,"modelSizeMtimeUnchanged":model_unchanged,"devicesOpened":false
            }))?
        );
        scratch.close()?;
        if passed {
            Ok(())
        } else {
            Err(io::Error::other("live session smoke failed"))
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
