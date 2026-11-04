//! Public-fixture probe: native converter -> owned capture WAV -> the resident
//! Metal engine's PREVIEW/%%FP/committed lanes. No microphone or private data.
#[cfg(all(target_os = "macos", debug_assertions))]
mod probe {
    use madi_core::{
        capture_stream::Configuration, preview, session::Session, transcript::TranscriptStore,
    };
    use madi_platform::{
        asr_config::{FileSettings, LiveSettings, Resources},
        audio_capture::{Capture, Event as CaptureEvent, pump_verification_run_loop},
        capture_pipeline::{CapturePipeline, Event as WavEvent},
        engine_process::{EngineProcess, Event},
    };
    use madi_protocol::{stream::Output, transcribe};
    use serde_json::json;
    use sha2::{Digest, Sha256};
    use std::{io, path::PathBuf, time::Duration};
    async fn collect(
        engine: &mut EngineProcess,
        mut end: impl FnMut(&transcribe::Event) -> bool,
    ) -> io::Result<Vec<transcribe::Event>> {
        tokio::time::timeout(Duration::from_secs(60), async {
            let mut events = Vec::new();
            while let Some(message) = engine.next().await {
                match message.event {
                    Event::Capabilities(caps) => {
                        // Probe-only transport metadata, never transcript data.
                        let event = transcribe::Event::Other(format!("[caps] {}", caps.join(" ")));
                        let done = end(&event);
                        events.push(event);
                        if done {
                            return Ok(events);
                        }
                    }
                    Event::Protocol(Output::Stdout(event)) => {
                        let done = end(&event);
                        events.push(event);
                        if done {
                            return Ok(events);
                        }
                    }
                    Event::Protocol(Output::Terminated(code)) => {
                        return Err(io::Error::other(format!("early engine exit {code}")));
                    }
                    Event::IoFailure { operation, message } => {
                        return Err(io::Error::other(format!("{operation}: {message}")));
                    }
                    _ => (),
                }
            }
            Err(io::Error::other("engine stream ended early"))
        })
        .await
        .map_err(io::Error::other)?
    }
    pub async fn run() -> io::Result<()> {
        let args: Vec<_> = std::env::args_os().collect();
        if args.len() != 6 {
            return Err(io::Error::other(
                "usage: live_preview_smoke <engine> <model> <assets> <public-fixture> <scratch-parent>",
            ));
        }
        let main = objc2::MainThreadMarker::new()
            .ok_or_else(|| io::Error::other("main thread required"))?;
        let source = PathBuf::from(&args[4]).canonicalize()?;
        let source_sha = format!("{:x}", Sha256::digest(std::fs::read(&source)?));
        let model = PathBuf::from(&args[2]).canonicalize()?;
        let before = std::fs::metadata(&model)?;
        let scratch = tempfile::Builder::new()
            .prefix("madi-preview-probe-")
            .tempdir_in(&args[5])?;
        let mut capture = Capture::replay(&source, 4096)?;
        let mut samples = Vec::new();
        let mut tick = tokio::time::interval(Duration::from_millis(2));
        tokio::time::timeout(Duration::from_secs(30),async {
            loop {tokio::select! {
                event=capture.next()=>match event {
                    Some(CaptureEvent::Samples{pcm,..})=>samples.extend(pcm),
                    Some(CaptureEvent::Stopped)=>return Ok::<_,io::Error>(()),
                    Some(CaptureEvent::Fault(message))=>return Err(io::Error::other(message)),
                    None=>return Err(io::Error::other("native replay ended without Stopped")),_=>(),
                },
                _=tick.tick()=>pump_verification_run_loop(main),
            }}
        }).await.map_err(io::Error::other)??;
        let mut pipeline = CapturePipeline::new(
            Configuration {
                preview_enabled: true,
                first_segment_seconds: 100.,
                segment_seconds: 100.,
                ..Default::default()
            },
            scratch.path(),
        )?;
        pipeline.start();
        let wav = pipeline
            .ingest(&samples[..samples.len().min(6 * 16000)], true)
            .into_iter()
            .find_map(|e| {
                if let WavEvent::Preview { wav, .. } = e {
                    Some(wav)
                } else {
                    None
                }
            })
            .ok_or_else(|| io::Error::other("missing native preview WAV"))?;
        let assets = PathBuf::from(&args[3]).canonicalize()?;
        let resources = Resources {
            executable: PathBuf::from(&args[1]).canonicalize()?,
            model: model.clone(),
            bpe: assets.join("WHISPER_BPE.bin"),
            assets,
        };
        let launch = resources.live_launch(
            pipeline.directory(),
            &LiveSettings {
                common: FileSettings {
                    language_token: Some(50259),
                    ..Default::default()
                },
                language_candidates: Vec::new(),
            },
        )?;
        let mut core = Session::default();
        core.begin_live();
        let mut engine =
            EngineProcess::spawn(launch, core.engine_token().unwrap(), scratch.path())?;
        let result=async {
            let mut ready=false;let mut declared=false;
            collect(&mut engine,|e|{
                ready |= matches!(e,transcribe::Event::Ready);
                declared |= matches!(e,transcribe::Event::Other(s) if s.starts_with("[caps] ") && s.split_whitespace().any(|c|c=="preview-fp"));
                ready && declared
            }).await?;
            let mut store=TranscriptStore::default();
            let mut previews=Vec::new();let mut forced=String::new();
            for index in 0..2 {
                let suffix=if forced.is_empty(){String::new()}else{format!(" %%FP {forced}")};
                engine.send_line(&format!("PREVIEW {}{suffix}",wav.path().display()))?;
                let events=collect(&mut engine,|e|matches!(e,transcribe::Event::PreviewEnd)).await?;
                let words:Vec<_>=events.iter().filter_map(|e|if let transcribe::Event::PreviewWord{text,..}=e{Some(text.clone())}else{None}).collect();
                let isolated=events.iter().all(|e|!matches!(e,transcribe::Event::Word{..}|transcribe::Event::SegmentEnd|transcribe::Event::FlushEnd|transcribe::Event::LanguageDetected(_)));
                for event in &events {store.ingest(event);}
                store.flush_render();
                let tail=preview::visible_tail(&words,&forced);
                if !isolated || !store.lines().is_empty() || words.len()<3 || tail.is_empty(){return Err(io::Error::other("preview isolation or text failed"));}
                previews.push(json!({"forced":forced,"words":words.len(),"tail":tail,"committedLines":store.lines().len(),"isolated":isolated}));
                if index==0 {forced=words[..2].join(" ");}
            }
            let committed=pipeline.stop().into_iter().find_map(|e|if let WavEvent::Segment{wav,offset,..}=e{Some((wav,offset))}else{None}).ok_or_else(||io::Error::other("missing final committed WAV"))?;
            engine.send_line(&format!("{:.3} {}",committed.1,committed.0.path().display()))?;
            for event in collect(&mut engine,|e|matches!(e,transcribe::Event::SegmentEnd)).await? {store.ingest(&event);}
            engine.send_line("FLUSH")?;engine.close_input();
            for event in collect(&mut engine,|e|matches!(e,transcribe::Event::FlushEnd)).await? {store.ingest(&event);}
            store.finalize();
            let mut exit=None;
            while let Some(message)=engine.next().await {if let Event::Protocol(Output::Terminated(code))=message.event {exit=Some(code);}}
            engine.wait().await?;
            if exit!=Some(0) || store.lines().is_empty(){return Err(io::Error::other("committed decode or exit failed"));}
            Ok::<_,io::Error>(json!({"previews":previews,"committedLines":store.lines().len(),"committedText":store.lines().iter().map(|l|l.text()).collect::<Vec<_>>(),"exitCode":exit}))
        }.await;
        engine.terminate();
        engine.wait().await?;
        drop(engine);
        drop(wav);
        drop(pipeline);
        drop(capture);
        let mut report = result?;
        let source_unchanged =
            source_sha == format!("{:x}", Sha256::digest(std::fs::read(&source)?));
        let after = std::fs::metadata(&model)?;
        let model_unchanged =
            before.len() == after.len() && before.modified()? == after.modified()?;
        let clean = std::fs::read_dir(scratch.path())?.next().is_none();
        report["status"] = json!(if clean && source_unchanged && model_unchanged {
            "passed"
        } else {
            "failed"
        });
        report["scope"] = json!(
            "Real native converter and Metal PREVIEW/forced-prefix/committed decode; no devices or WebView acceptance"
        );
        report["fixtureSHA256"] = json!(source_sha);
        report["sourceUnchanged"] = json!(source_unchanged);
        report["modelSizeMtimeUnchanged"] = json!(model_unchanged);
        report["ownedScratchEmpty"] = json!(clean);
        println!("{}", serde_json::to_string_pretty(&report)?);
        if report["status"] != "passed" {
            return Err(io::Error::other("preview probe failed"));
        }
        Ok(())
    }
}
#[cfg(all(target_os = "macos", debug_assertions))]
#[tokio::main(flavor = "current_thread")]
async fn main() -> std::io::Result<()> {
    probe::run().await
}
#[cfg(not(all(target_os = "macos", debug_assertions)))]
fn main() {
    eprintln!("Native live preview probe requires a macOS debug build");
    std::process::exit(1);
}
