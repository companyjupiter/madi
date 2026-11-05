//! Explicit installed-model acceptance using public PCM and isolated storage.
use super::*;
use crate::{
    asr_config::Resources,
    audio_capture::Event,
    live_session::{
        Control,
        tests::{input, request},
    },
};
use serde_json::{Value, json};
fn required(name: &str) -> PathBuf {
    PathBuf::from(std::env::var_os(name).unwrap_or_else(|| panic!("explicit {name} required")))
}
fn python() -> std::ffi::OsString {
    std::env::var_os("MADI_TEST_PYTHON").unwrap_or_else(|| "python3".into())
}
fn hashes(paths: &[PathBuf]) -> Value {
    let output=std::process::Command::new(python()).args(["-c","import hashlib,json,sys\nr={}\nfor p in sys.argv[1:]:\n with open(p,'rb') as f:r[p]=hashlib.file_digest(f,'sha256').hexdigest()\nprint(json.dumps(r))"]).args(paths).output().unwrap();
    assert!(output.status.success());
    serde_json::from_slice(&output.stdout).unwrap()
}
async fn observed(w: &FileWorkflow, ready: impl Fn(&Snapshot) -> bool) -> io::Result<Snapshot> {
    let mut updates = w.owner.snapshot.clone();
    loop {
        let s = updates.borrow_and_update().clone();
        if let ViewPhase::Error { message } = &s.phase {
            return Err(io::Error::other(message.clone()));
        }
        if ready(&s) {
            return Ok(s);
        }
        updates.changed().await.map_err(io::Error::other)?;
    }
}
#[tokio::test]
#[ignore = "requires explicitly selected installed ASR/DNA models and public JFK fixture"]
async fn actual_metal_asr_and_dna_reconciliation_preserve_public_audio_and_final_archive() {
    let bin = required("MADI_PROBE_BIN").canonicalize().unwrap();
    let assets = required("MADI_PROBE_ASSETS").canonicalize().unwrap();
    let models = required("MADI_PROBE_MODELS").canonicalize().unwrap();
    let source = required("MADI_PROBE_SOURCE").canonicalize().unwrap();
    let out = required("MADI_PROBE_OUTPUT");
    std::fs::create_dir_all(&out).unwrap();
    let resources = Locations {
        bundle_resources: assets.clone(),
        bundle_executables: bin.clone(),
        support: models.clone(),
    };
    let pinned = vec![
        source.clone(),
        resources.transcription_model(),
        resources.translation_model(TranslationVariant::Quality4B),
        bin.join("transcribe"),
        bin.join("translate-engine-4b"),
    ];
    let before = hashes(&pinned);
    assert_eq!(
        before[source.to_str().unwrap()],
        "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e"
    );
    let decoded=std::process::Command::new(python()).args(["-c","import sys,wave\nwith wave.open(sys.argv[1],'rb') as f:\n assert (f.getframerate(),f.getnchannels(),f.getsampwidth(),f.getcomptype())==(16000,1,2,'NONE')\n sys.stdout.buffer.write(f.readframes(f.getnframes()))"]).arg(&source).output().unwrap();
    assert!(decoded.status.success());
    let pcm: Vec<_> = decoded
        .stdout
        .as_chunks::<2>()
        .0
        .iter()
        .map(|b| i16::from_le_bytes(*b))
        .collect();
    let scratch = tempfile::tempdir().unwrap();
    let prefs = PreferencesService::new(
        preferences::Store::load(
            scratch.path().join("prefs.json"),
            preferences::Preferences::from_legacy(preferences::Legacy {
                language_token_id: 50259,
                settings: LegacySettings {
                    ai_reconcile_enabled: Some(true),
                    ..Default::default()
                },
                ..Default::default()
            }),
        )
        .unwrap(),
        |_| {},
    )
    .unwrap();
    let (send, mut changes) = mpsc::unbounded_channel();
    let w = FileWorkflow::with_translation(
        Configuration {
            resources: Resources {
                executable: bin.join("transcribe"),
                model: resources.transcription_model(),
                bpe: assets.join("WHISPER_BPE.bin"),
                assets: assets.clone(),
            },
            decoder: bin.join("madi-audio-decode"),
            scratch_parent: scratch.path().into(),
        },
        Some(ArchiveSettings {
            enabled: true,
            folder: scratch.path().join("archive"),
        }),
        Some(translation::Resources::new(
            resources,
            TranslationVariant::Quality4B,
        )),
        move |s| {
            let _ = send.send(s);
        },
    )
    .unwrap();
    let (capture, events, mut controls) = input();
    let native_events = events.clone();
    let native = tokio::spawn(async move {
        while let Some(c) = controls.recv().await {
            if c == Control::Stop {
                let _ = native_events.send(Event::Stopped);
                break;
            }
        }
    });
    let mut req = request(capture);
    req.settings.common.language_token = Some(50259);
    req.capture.segment_seconds = 5.;
    req.capture.first_segment_seconds = 5.;
    req.capture.overlap_seconds = 0.;
    req.capture.preview_enabled = false;
    let began = Instant::now();
    let result = timeout(Duration::from_secs(180), async {
        w.start_live(req, None).await?;
        observed(&w, |s| s.phase == ViewPhase::Ready).await?;
        w.set_preferences(prefs.clone()).await?;
        events.send(Event::Started).map_err(io::Error::other)?;
        observed(&w, |s| s.phase == ViewPhase::Recording).await?;
        events
            .send(Event::Samples {
                microphone: true,
                pcm,
            })
            .map_err(io::Error::other)?;
        observed(&w, |s| !s.lines.is_empty()).await?;
        w.live_control(w.snapshot().generation, LiveControl::Stop)
            .await?;
        let mut immediate = None;
        while let Some(s) = changes.recv().await {
            if let ViewPhase::Error { message } = &s.phase {
                return Err(io::Error::other(message.clone()));
            }
            if s.reconciling && s.phase == ViewPhase::Done && immediate.is_none() {
                let path = s
                    .archive
                    .transcript
                    .as_ref()
                    .ok_or_else(|| io::Error::other("AI began before durability save"))?;
                immediate = Some(std::fs::read_to_string(path)?);
                eprintln!(
                    "[reconciliation] final ASR saved; real DNA reviewing {} lines",
                    s.lines.len()
                );
            }
            if let Some(initial) = &immediate
                && s.phase == ViewPhase::Done
                && !s.reconciling
                && s.language_corrections_pending == 0
            {
                if !s
                    .reconcile_replies
                    .iter()
                    .any(|text| text.as_ref().is_some_and(|text| !text.trim().is_empty()))
                {
                    return Err(io::Error::other("DNA returned no successful model reply"));
                }
                let markdown = std::fs::read_to_string(s.archive.transcript.as_ref().unwrap())?;
                let wanted = archive::markdown(
                    &s.lines.iter().map(|l| l.line.clone()).collect::<Vec<_>>(),
                    &s.speaker_names,
                    None,
                );
                if markdown != wanted {
                    return Err(io::Error::other(
                        "final archive differs from corrected transcript",
                    ));
                }
                std::fs::write(out.join("initial.md"), initial)?;
                std::fs::write(out.join("final.md"), markdown)?;
                return Ok(s);
            }
        }
        Err(io::Error::other("workflow stopped before model reply"))
    })
    .await
    .map_err(io::Error::other)
    .and_then(|r| r);
    // Reset joins correction work and releases the retained segment directory.
    if !w.snapshot().phase.is_recording() {
        w.reset(w.snapshot().generation).await.unwrap();
    }
    w.shutdown().await.unwrap();
    native.await.unwrap();
    prefs.shutdown().await.unwrap();
    let after = hashes(&pinned);
    assert_eq!(before, after);
    let clean = crate::file_session::tests::scratch_count(scratch.path()) == 0;
    let status = if result.is_ok() && clean {
        "PASS"
    } else {
        "FAIL"
    };
    let report = json!({"status":status,"elapsedSeconds":began.elapsed().as_secs_f64(),"resourceHashes":before,"resourcesUnchanged":before==after,"ownedAudioCleaned":clean,"devicesOpened":false,"result":result.as_ref().ok(),"error":result.as_ref().err().map(ToString::to_string),"rawModelReplies":result.as_ref().ok().map(|s|&s.reconcile_replies),"scope":"Actual installed ASR and DNA through the shared workflow on pinned public PCM; immediate/final archive and cleanup. No microphone, UI, recognition quality or full concurrency acceptance."});
    std::fs::write(
        out.join("report.json"),
        serde_json::to_vec_pretty(&report).unwrap(),
    )
    .unwrap();
    assert!(result.is_ok(), "{}", result.unwrap_err());
    assert!(clean);
}
