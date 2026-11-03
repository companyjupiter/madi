//! Real native decode/ASR probe through the serialized file-session executor.
use madi_core::session::Phase;
use madi_platform::{
    asr_config::{FileSettings, Resources},
    file_session::{Configuration, FileSession, UpdateKind},
};
use madi_protocol::{stream::Output, structured, transcribe};
use serde_json::json;
use std::{io, path::PathBuf, time::Duration};

#[tokio::main(flavor = "current_thread")]
async fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 6 {
        return Err(io::Error::other(
            "usage: file_session_smoke <engine> <model> <assets> <source-media> <scratch-parent>",
        ));
    }
    #[cfg(target_os = "macos")]
    let decoder = madi_platform::prepared_audio::development_helper().to_owned();
    #[cfg(not(target_os = "macos"))]
    let decoder = PathBuf::from("unsupported-native-decoder");
    if !cfg!(target_os = "macos") {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "native decode is currently macOS-only",
        ));
    }
    let scratch = tempfile::Builder::new()
        .prefix("madi-file-session-probe-")
        .tempdir_in(&args[5])?;
    let assets = PathBuf::from(&args[3]);
    let mut session = FileSession::new(Configuration {
        resources: Resources {
            executable: PathBuf::from(&args[1]),
            model: PathBuf::from(&args[2]),
            bpe: assets.join("WHISPER_BPE.bin"),
            assets,
        },
        decoder,
        scratch_parent: scratch.path().to_owned(),
    })?;
    let run = session
        .start(PathBuf::from(&args[4]), FileSettings::default())
        .await?
        .ok_or_else(|| io::Error::other("new file session was busy"))?;
    let mut words = 0;
    let mut structured = 0;
    let mut segments = Vec::new();
    let mut phases = Vec::new();
    let mut finished = 0;
    let mut failed = 0;
    let mut faults = Vec::new();
    let execution = async {
        while let Some(update) = session.next().await {
            assert_eq!(update.run, run);
            match update.kind {
                UpdateKind::Phase(phase) => phases.push(phase),
                UpdateKind::Output(Output::Stdout(transcribe::Event::Word { .. })) => words += 1,
                UpdateKind::Output(Output::Structured(event)) => {
                    structured += 1;
                    if let structured::Event::Segment(segment) = event {
                        segments.push(segment.text);
                    }
                }
                UpdateKind::Finished => {
                    finished += 1;
                    break;
                }
                UpdateKind::Failed => {
                    failed += 1;
                    break;
                }
                UpdateKind::Fault(message) => {
                    faults.push(message);
                    break;
                }
                _ => {}
            }
        }
    };
    let timed_out = tokio::time::timeout(Duration::from_secs(120), execution)
        .await
        .is_err();
    let clean_at_completion = std::fs::read_dir(scratch.path())?.next().is_none();
    let shutdown = session.shutdown().await;
    let clean_at_shutdown = std::fs::read_dir(scratch.path())?.next().is_none();
    if let Err(error) = shutdown {
        faults.push(error.to_string());
    }
    let passed = !timed_out
        && phases == [Phase::Processing, Phase::Done]
        && finished == 1
        && failed == 0
        && faults.is_empty()
        && words > 0
        && !segments.is_empty()
        && clean_at_completion
        && clean_at_shutdown;
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "schemaVersion":1,"status":if passed { "passed" } else { "failed" },
            "scope":"Rust file-session effect executor with real native decode and Metal ASR; no desktop UI, archive or live capture integration",
            "phases":phases.iter().map(|phase|format!("{phase:?}")).collect::<Vec<_>>(),
            "wordEvents":words,"structuredEvents":structured,"segments":segments,
            "finishedCallbacks":finished,"failedCallbacks":failed,"faults":faults,"timedOut":timed_out,
            "ownedScratchEmptyWhenFinishedReceived":clean_at_completion,"ownedScratchEmptyAfterShutdown":clean_at_shutdown,
        }))?
    );
    scratch.close()?;
    if !passed {
        return Err(io::Error::other("file session smoke failed"));
    }
    Ok(())
}
