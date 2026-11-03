//! Explicit local file-mode probe for the native supervisor. This does not
//! connect the desktop UI, copy/delete the input WAV or run the session executor.
use madi_core::session::Session;
use madi_platform::engine_process::{EngineProcess, Event, Launch};
use madi_protocol::{stream::Output, structured, transcribe};
use serde_json::json;
use std::{collections::BTreeMap, io, path::PathBuf, time::Duration};

#[tokio::main(flavor = "current_thread")]
async fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 6 && !(args.len() == 7 && args[6] == "--decode") {
        return Err(io::Error::other(
            "usage: engine_file_smoke <binary> <model> <assets-directory> <wav> <scratch-parent> [--decode]",
        ));
    }
    let prepared: Option<madi_platform::prepared_audio::PreparedAudio> = if args.len() == 7 {
        #[cfg(target_os = "macos")]
        {
            use madi_platform::prepared_audio::{DecodeTask, development_helper};
            let mut decode = DecodeTask::start(
                development_helper(),
                &PathBuf::from(&args[4]),
                &PathBuf::from(&args[5]),
            )
            .map_err(io::Error::other)?;
            match tokio::time::timeout(Duration::from_secs(120), decode.wait()).await {
                Ok(result) => Some(result.map_err(io::Error::other)?),
                Err(_) => {
                    decode.cancel();
                    let _ = decode.wait().await;
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "native decode timed out",
                    ));
                }
            }
        }
        #[cfg(not(target_os = "macos"))]
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "native file decoder is currently macOS-only",
        ));
    } else {
        None
    };
    let prepared_path = prepared.as_ref().map(|audio| audio.path().to_path_buf());
    let assets = PathBuf::from(&args[3]);
    let mut session = Session::default();
    session.begin_live(); // Allocates only an identity for this transport probe.
    let token = session.engine_token().unwrap();
    let launch = Launch {
        executable: PathBuf::from(&args[1]),
        arguments: vec![
            args[2].clone(),
            prepared_path
                .as_ref()
                .map(|path| path.as_os_str().to_owned())
                .unwrap_or_else(|| args[4].clone()),
            assets.join("WHISPER_BPE.bin").into(),
        ],
        working_directory: assets,
        environment: BTreeMap::from([
            ("APP_FILE".into(), Some("1".into())),
            ("DIAR".into(), Some("1".into())),
            ("OSD".into(), Some("1".into())),
            ("CONF".into(), Some("1".into())),
            ("DIAR_MAXK".into(), Some("8".into())),
            ("STREAM".into(), None),
        ]),
    };
    let mut engine = EngineProcess::spawn(launch, token, &PathBuf::from(&args[5]))?;
    engine.close_input();
    let mut words = 0;
    let mut structured_count = 0;
    let mut segments = Vec::new();
    let mut flushed = false;
    let mut exit_code = None;
    let mut faults = Vec::new();
    let execution = async {
        while let Some(message) = engine.next().await {
            assert_eq!(message.token, token);
            match message.event {
                Event::Protocol(Output::Stdout(transcribe::Event::Word { .. })) => words += 1,
                Event::Protocol(Output::Stdout(transcribe::Event::FlushEnd)) => flushed = true,
                Event::Protocol(Output::Structured(event)) => {
                    structured_count += 1;
                    if let structured::Event::Segment(segment) = event {
                        segments.push(segment.text);
                    }
                }
                Event::Protocol(Output::Terminated(code)) => exit_code = Some(code),
                Event::IoFailure { operation, message } => {
                    faults.push(format!("{operation}: {message}"))
                }
                _ => {}
            }
        }
        engine.wait().await
    };
    match tokio::time::timeout(Duration::from_secs(120), execution).await {
        Ok(result) => result?,
        Err(_) => {
            engine.terminate();
            engine.wait().await?;
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "engine file smoke timed out",
            ));
        }
    }
    let cleaned = !engine.events_path().parent().unwrap().exists();
    if let Some(prepared) = prepared {
        prepared.dispose()?;
    }
    let prepared_removed = prepared_path.as_ref().map(|path| !path.exists());
    let passed =
        exit_code == Some(0) && flushed && !segments.is_empty() && faults.is_empty() && cleaned;
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "schemaVersion": 1, "status": if passed { "passed" } else { "failed" },
            "scope": "Rust native ASR supervisor with real model and optional native decoding; desktop and session executor not connected",
            "wordEvents": words, "structuredEvents": structured_count, "segments": segments,
            "flushBeforeExit": flushed, "exitCode": exit_code, "faults": faults, "ownedScratchRemoved": cleaned,
            "decodedInput": prepared_path.is_some(), "preparedWavRemoved": prepared_removed,
        }))?
    );
    if !passed {
        return Err(io::Error::other("engine file smoke failed"));
    }
    Ok(())
}
