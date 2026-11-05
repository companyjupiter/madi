//! Explicit local acceptance probe. Uses only the pinned public JFK fixture,
//! a caller-selected installed engine/model and the real (unaccelerated) clock.
use super::*;
use madi_core::pipeline_status::Pipeline;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{io::Read, os::unix::fs::PermissionsExt, path::Path};

fn digest(path: &Path) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0_u8; 65536];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
fn required(name: &str) -> PathBuf {
    PathBuf::from(std::env::var_os(name).unwrap_or_else(|| panic!("explicit {name} is required")))
}
async fn observed(
    workflow: &FileWorkflow,
    predicate: impl Fn(&Snapshot) -> bool,
) -> std::io::Result<Snapshot> {
    let mut updates = workflow.owner.snapshot.clone();
    loop {
        let value = updates.borrow_and_update().clone();
        if let ViewPhase::Error { message } = &value.phase {
            return Err(io::Error::other(message.clone()));
        }
        if predicate(&value) {
            return Ok(value);
        }
        updates.changed().await.map_err(io::Error::other)?;
    }
}
fn engine_record(root: &Path, n: usize) -> std::io::Result<Value> {
    serde_json::from_slice(&std::fs::read(root.join(format!("engine-{n}.json")))?)
        .map_err(io::Error::other)
}
fn wave_hashes(root: &Path) -> std::io::Result<std::collections::BTreeMap<String, String>> {
    let mut result = std::collections::BTreeMap::new();
    for entry in std::fs::read_dir(root)? {
        let path = entry?.path();
        if path.extension().is_some_and(|v| v == "wav") {
            result.insert(
                path.file_name().unwrap().to_string_lossy().into_owned(),
                digest(&path)?,
            );
        }
    }
    Ok(result)
}
async fn scenario(
    engine: &Path,
    model: &Path,
    assets: &Path,
    pcm: &[i16],
    out: &Path,
    inject: bool,
) -> std::io::Result<Value> {
    let owned = tempfile::tempdir()?;
    let root = owned.path();
    let scratch = root.join("scratch");
    std::fs::create_dir(&scratch)?;
    let scratch = scratch.canonicalize()?;
    let python = std::process::Command::new(
        std::env::var_os("MADI_TEST_PYTHON").unwrap_or_else(|| "python3".into()),
    )
    .args(["-c", "import sys;print(sys.executable)"])
    .output()?;
    if !python.status.success() {
        return Err(io::Error::other("Python discovery failed"));
    }
    let python = String::from_utf8(python.stdout).map_err(io::Error::other)?;
    // exec keeps the PID: the native supervisor owns the actual ASR process,
    // including SIGTERM -> SIGKILL escalation when this probe suspends it.
    let wrapper = root.join("record-and-exec.py");
    let script=r#"import json,os,pathlib,sys
root=pathlib.Path(__file__).parent
counter=root/'generation'
n=int(counter.read_text(encoding='utf-8'))+1 if counter.exists() else 1
counter.write_text(str(n),encoding='utf-8')
(root/('engine-'+str(n)+'.json')).write_text(json.dumps({'pid':os.getpid(),'parent':os.getppid(),'wavRoot':os.environ['STREAM_WAV_ROOTS']}),encoding='utf-8')
engine=__ENGINE__
os.execv(engine,[engine,*sys.argv[1:]])
"#.replace("__ENGINE__",&serde_json::to_string(engine).map_err(io::Error::other)?);
    std::fs::write(&wrapper, format!("#!{}\n{script}", python.trim()))?;
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o700))?;
    let workflow = FileWorkflow::with_archive(
        Configuration {
            decoder: engine.parent().unwrap().join("madi-audio-decode"),
            resources: crate::asr_config::Resources {
                executable: wrapper,
                model: model.to_owned(),
                bpe: assets.join("WHISPER_BPE.bin"),
                assets: assets.to_owned(),
            },
            scratch_parent: scratch.clone(),
        },
        Some(ArchiveSettings {
            enabled: true,
            folder: root.join("archive"),
        }),
        |_| {},
    )?;
    let (capture, events, mut controls) = input();
    let native_events = events.clone();
    let mut native = tokio::spawn(async move {
        while let Some(command) = controls.recv().await {
            let event = match command {
                Control::Pause => Event::Paused,
                Control::Resume => Event::Resumed,
                Control::Stop => Event::Stopped,
                Control::InputDevice(_) => continue,
            };
            if native_events.send(event).is_err() || command == Control::Stop {
                break;
            }
        }
    });
    let mut request = request(capture);
    request.settings.common.language_token = Some(50259);
    request.capture.segment_seconds = 5.;
    request.capture.first_segment_seconds = 5.;
    request.capture.overlap_seconds = 0.;
    request.capture.preview_enabled = false;
    let case = async {
        workflow.start_live(request, None).await?;
        events.send(Event::Started).map_err(io::Error::other)?;
        let recording = observed(&workflow, |s| s.phase == ViewPhase::Recording).await?;
        let first = engine_record(root, 1)?;
        let pid = first["pid"]
            .as_i64()
            .ok_or_else(|| io::Error::other("missing child PID"))? as libc::pid_t;
        if first["parent"].as_u64() != Some(u64::from(std::process::id())) {
            return Err(io::Error::other("engine is not this probe's child"));
        }
        let proc = std::process::Command::new("/bin/ps")
            .args(["-p", &pid.to_string(), "-o", "ppid=", "-o", "comm="])
            .output()?;
        let proc = String::from_utf8(proc.stdout).map_err(io::Error::other)?;
        if !proc.contains(engine.to_str().unwrap()) {
            return Err(io::Error::other(format!(
                "unexpected owned process image: {proc}"
            )));
        }
        let began = std::time::Instant::now();
        if inject {
            // Only this already-verified child is signalled. Production code has
            // no fault-injection or accelerated-wall-clock setting.
            if unsafe { libc::kill(pid, libc::SIGSTOP) } != 0 {
                return Err(io::Error::last_os_error());
            }
            let state = std::process::Command::new("/bin/ps")
                .args(["-p", &pid.to_string(), "-o", "state="])
                .output()?;
            if !String::from_utf8_lossy(&state.stdout).contains('T') {
                return Err(io::Error::other("owned engine did not suspend"));
            }
            eprintln!(
                "[metal recovery] actual engine suspended; waiting for the normal >45-second watchdog"
            );
        }
        events
            .send(Event::Samples {
                microphone: true,
                pcm: pcm.to_vec(),
            })
            .map_err(io::Error::other)?;
        observed(&workflow, |s| s.status.pipeline == Pipeline::Transcribing).await?;
        let wav_root = PathBuf::from(first["wavRoot"].as_str().unwrap());
        if !wav_root.starts_with(&scratch) {
            return Err(io::Error::other("unexpected WAV owner"));
        }
        let before = wave_hashes(&wav_root)?;
        if before.is_empty() {
            return Err(io::Error::other("no committed WAVs"));
        }
        let recovery_seconds = if inject {
            file_ready_long(&root.join("engine-2.json")).await?;
            let elapsed = began.elapsed().as_secs_f64();
            if !(45. ..=90.).contains(&elapsed) {
                return Err(io::Error::other(format!(
                    "unexpected real recovery elapsed {elapsed}"
                )));
            }
            eprintln!("[metal recovery] replacement launched after {elapsed:.3} seconds");
            Some(elapsed)
        } else {
            None
        };
        // This fixture sends PCM once, so the normal silence watch becomes
        // active during the real 45-second stall. Its Idle presentation must
        // not be mistaken for pending ASR. Wait for actual replacement words,
        // then let Stop/FLUSH drain all queued audio before comparing results.
        observed(&workflow, |s| !s.lines.is_empty()).await?;
        eprintln!("[metal recovery] words received; draining Stop/FLUSH (injected={inject})");
        workflow
            .live_control(recording.generation, LiveControl::Stop)
            .await?;
        let done = observed(&workflow, |s| {
            s.phase == ViewPhase::Done && s.archive.transcript.is_some()
        })
        .await?;
        let expected_warning = if inject { Some("복구 1회") } else { None };
        if done.status.warning.as_deref() != expected_warning {
            return Err(io::Error::other(format!(
                "unexpected warning {:?}",
                done.status.warning
            )));
        }
        let after = wave_hashes(&wav_root)?;
        if !before.iter().all(|(p, h)| after.get(p) == Some(h)) {
            return Err(io::Error::other("retained WAV changed"));
        }
        let launches = std::fs::read_to_string(root.join("generation"))?
            .trim()
            .parse::<usize>()
            .map_err(io::Error::other)?;
        if launches != if inject { 2 } else { 1 } {
            return Err(io::Error::other("unexpected engine launch count"));
        }
        let lines: Vec<_> = done.lines.iter().map(|l| l.line.clone()).collect();
        let archive_path = done.archive.transcript.clone().unwrap();
        let saved = std::fs::read_to_string(&archive_path)?;
        if saved != madi_core::transcript::archive::markdown(&lines, &done.speaker_names, None) {
            return Err(io::Error::other("archive differs from final transcript"));
        }
        let transcript:Vec<_>=done.lines.iter().map(|l|json!({"text":l.text,"start":l.line.start,"end":l.line.end,"speaker":l.line.speaker,"words":l.line.words.iter().map(|w|json!({"t0":w.t0,"t1":w.t1,"text":w.text,"conf":w.conf})).collect::<Vec<_>>()})).collect();
        let title = if inject { "recovered" } else { "baseline" };
        std::fs::write(out.join(format!("{title}.md")), &saved)?;
        let reset = workflow.reset(recording.generation).await?;
        if reset.status.warning.is_some() {
            return Err(io::Error::other("recovery warning survived reset"));
        }
        let reopened = workflow
            .open_archive(reset.generation, archive_path)
            .await?;
        if reopened
            .lines
            .iter()
            .map(|l| l.text.as_str())
            .collect::<Vec<_>>()
            != done
                .lines
                .iter()
                .map(|l| l.text.as_str())
                .collect::<Vec<_>>()
        {
            return Err(io::Error::other("reopened archive text differs"));
        }
        if wav_root.exists() {
            return Err(io::Error::other("audio owner survived reset"));
        }
        Ok(
            json!({"status":"passed","injectedSIGSTOP":inject,"engineLaunches":launches,"recoverySeconds":recovery_seconds,"warning":done.status.warning,"transcript":transcript,"wavSHA256":after,"retainedWavsUnchanged":true,"archiveMatchesFinalTranscript":true,"archiveSHA256":format!("{:x}",Sha256::digest(saved.as_bytes())),"reopenedTextMatches":true,"resetClearsRecoveryWarning":true,"ownedAudioRemovedAfterReset":true}),
        )
    };
    let result = timeout(Duration::from_secs(180), case)
        .await
        .map_err(|error| {
            let snapshot = workflow.snapshot();
            io::Error::other(format!(
                "{error}: phase={:?}, lines={}, status={:?}",
                snapshot.phase,
                snapshot.lines.len(),
                snapshot.status
            ))
        })
        .and_then(|v| v);
    let shutdown = timeout(Duration::from_secs(60), workflow.shutdown())
        .await
        .map_err(io::Error::other)
        .and_then(|v| v);
    let native_result = timeout(Duration::from_secs(5), &mut native).await;
    if native_result.is_err() {
        native.abort();
        let _ = native.await;
    }
    shutdown?;
    native_result
        .map_err(io::Error::other)?
        .map_err(io::Error::other)?;
    if std::fs::read_dir(&scratch)?.next().is_some() {
        return Err(io::Error::other("owned scratch leaked"));
    }
    // No model process may survive even if this scenario returned an error.
    for n in 1..=2 {
        if root.join(format!("engine-{n}.json")).exists() {
            let record = engine_record(root, n)?;
            let pid = record["pid"].as_i64().unwrap() as libc::pid_t;
            if unsafe { libc::kill(pid, 0) } == 0 {
                return Err(io::Error::other("owned engine survived shutdown"));
            }
        }
    }
    result
}
async fn file_ready_long(path: &Path) -> std::io::Result<()> {
    timeout(Duration::from_secs(90), async {
        while !path.exists() {
            sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .map_err(io::Error::other)
}

#[tokio::test]
#[ignore = "explicit installed Metal ASR/model, pinned public JFK fixture and real 45-second fault injection"]
async fn actual_metal_hang_recovery_matches_baseline_and_preserves_archive() {
    let engine = required("MADI_PROBE_ENGINE").canonicalize().unwrap();
    let model = required("MADI_PROBE_MODEL").canonicalize().unwrap();
    let assets = required("MADI_PROBE_ASSETS").canonicalize().unwrap();
    let source = required("MADI_PROBE_SOURCE").canonicalize().unwrap();
    let out = required("MADI_PROBE_OUTPUT");
    std::fs::create_dir_all(&out).unwrap();
    let source_sha = digest(&source).unwrap();
    assert_eq!(
        source_sha, "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e",
        "only the pinned public JFK fixture is admitted"
    );
    let model_sha = digest(&model).unwrap();
    let engine_sha = digest(&engine).unwrap();
    let decoded=std::process::Command::new(std::env::var_os("MADI_TEST_PYTHON").unwrap_or_else(||"python3".into())).args(["-c","import sys,wave\nwith wave.open(sys.argv[1],'rb') as f:\n assert (f.getframerate(),f.getnchannels(),f.getsampwidth(),f.getcomptype())==(16000,1,2,'NONE')\n sys.stdout.buffer.write(f.readframes(f.getnframes()))"]).arg(&source).output().unwrap();
    assert!(decoded.status.success());
    assert_eq!(decoded.stdout.len() % 2, 0);
    let pcm: Vec<_> = decoded
        .stdout
        .as_chunks::<2>()
        .0
        .iter()
        .map(|b| i16::from_le_bytes(*b))
        .collect();
    eprintln!("[metal recovery] running normal public-audio baseline");
    let baseline = scenario(&engine, &model, &assets, &pcm, &out, false).await;
    eprintln!(
        "[metal recovery] baseline result: {}",
        if baseline.is_ok() { "PASS" } else { "FAIL" }
    );
    let recovered = if baseline.is_ok() {
        scenario(&engine, &model, &assets, &pcm, &out, true).await
    } else {
        Err(io::Error::other("baseline failed"))
    };
    eprintln!("[metal recovery] scenarios finished; verifying source/model/engine hashes");
    let unchanged = digest(&source).unwrap() == source_sha
        && digest(&model).unwrap() == model_sha
        && digest(&engine).unwrap() == engine_sha;
    let equal = matches!((&baseline,&recovered),(Ok(a),Ok(b)) if a["transcript"]==b["transcript"] && a["wavSHA256"]==b["wavSHA256"] && a["archiveSHA256"]==b["archiveSHA256"]);
    let report = json!({"schemaVersion":1,"status":if unchanged&&equal{"passed"}else{"failed"},"scope":"Actual installed macOS ASR/model with native workflow, scripted public PCM, real wall-time SIGSTOP/SIGKILL replacement, transcript/owned-WAV/archive baseline comparison and cleanup; no microphone, WebView, naturally occurring GPU hang or numerical/quality acceptance.","fixtureSHA256":source_sha,"modelSHA256":model_sha,"engineSHA256":engine_sha,"sourceModelEngineUnchanged":unchanged,"baselineEqualsRecovered":equal,"baseline":baseline.as_ref().map_err(|e|e.to_string()),"recovered":recovered.as_ref().map_err(|e|e.to_string()),"devicesOpened":false});
    std::fs::write(
        out.join("report.json"),
        serde_json::to_vec_pretty(&report).unwrap(),
    )
    .unwrap();
    assert!(
        unchanged && equal,
        "{}",
        serde_json::to_string_pretty(&report).unwrap()
    );
}
