#[cfg(all(target_os = "macos", debug_assertions))]
fn main() {
    use madi_core::segmenter::{Configuration, Segmenter};
    use madi_platform::audio_capture::{Capture, Event, pump_verification_run_loop};
    use madi_platform::capture_pipeline::{CapturePipeline, Event as PipelineEvent};
    use serde_json::{Value, json};
    use sha2::{Digest, Sha256};
    use std::{
        io::Read,
        path::Path,
        time::{Duration, Instant},
    };
    let main = objc2::MainThreadMarker::new().expect("verification runs on main");
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Value> = serde_json::from_str(&input).unwrap();
    let mut output = Vec::new();
    for case in cases {
        let path = Path::new(case["path"].as_str().unwrap());
        let chunk = case["chunk"].as_u64().unwrap() as u32;
        let mut capture = Capture::replay(path, chunk).unwrap();
        // A second endpoint is cancelled before it starts. Its cleanup must not
        // stop, consume or close the first one's callbacks or converter.
        let mut cancelled = Capture::replay(path, chunk).unwrap();
        cancelled.stop();
        cancelled.stop();
        let mut abandoned = Capture::replay(path, chunk).unwrap();
        abandoned.stop();
        drop(abandoned);
        let mut segmenter = Segmenter::new(Configuration {
            first_segment_seconds: 1.5,
            ..Configuration::default()
        })
        .unwrap();
        let scratch = tempfile::tempdir().unwrap();
        let mut pipeline = CapturePipeline::new(
            madi_core::capture_stream::Configuration::default(),
            scratch.path(),
        )
        .unwrap();
        let segment_directory = pipeline.directory().to_owned();
        pipeline.start();
        let mut written_segments = Vec::new();
        let describe_wav = |event| match event {
            PipelineEvent::Segment {
                offset,
                wav,
                had_speech,
            } => {
                let data = std::fs::read(wav.path()).unwrap();
                assert_eq!(&data[..4], b"RIFF");
                assert_eq!(
                    data.len(),
                    u32::from_le_bytes(data[40..44].try_into().unwrap()) as usize + 44
                );
                Some(
                    json!({"offsetBits":format!("{:016x}",offset.to_bits()),"sampleCount":(data.len()-44)/2,
                    "hadSpeech":had_speech,"pcmSHA256":format!("{:x}",Sha256::digest(&data[44..]))}),
                )
            }
            PipelineEvent::Level(_) => None,
            event => panic!("unexpected native pipeline output: {event:?}"),
        };
        let mut digest = Sha256::new();
        let mut sample_count = 0;
        let mut chunks = Vec::new();
        let mut segments = Vec::new();
        let mut events = Vec::new();
        let mut cancel_events = Vec::new();
        let mut done = false;
        let mut cancel_done = false;
        let deadline = Instant::now() + Duration::from_secs(30);
        let describe = |seg: madi_core::segmenter::Segment| {
            let data: Vec<_> = seg.samples.iter().flat_map(|n| n.to_le_bytes()).collect();
            json!({"offsetBits":format!("{:016x}",seg.offset.to_bits()),"bodyCount":seg.body_count,
                "sampleCount":seg.samples.len(),"hadSpeech":seg.had_speech,"pcmSHA256":format!("{:x}",Sha256::digest(data))})
        };
        while !done || !cancel_done {
            assert!(
                Instant::now() < deadline,
                "native capture did not terminate"
            );
            pump_verification_run_loop(main);
            while let Ok(event) = capture.try_next() {
                assert!(!done, "callback after terminal acknowledgement");
                match event {
                    Event::Started => events.push("started".to_owned()),
                    Event::Samples { microphone, pcm } => {
                        assert!(microphone);
                        assert_eq!(events.first().map(String::as_str), Some("started"));
                        sample_count += pcm.len();
                        chunks.push(pcm.len());
                        for n in &pcm {
                            digest.update(n.to_le_bytes());
                        }
                        segments.extend(segmenter.push(&pcm).into_iter().map(&describe));
                        written_segments.extend(
                            pipeline
                                .ingest(&pcm, microphone)
                                .into_iter()
                                .filter_map(&describe_wav),
                        );
                    }
                    Event::Fault(message) => events.push(format!("fault:{message}")),
                    Event::Stopped => {
                        segments.extend(segmenter.flush().into_iter().map(&describe));
                        written_segments
                            .extend(pipeline.stop().into_iter().filter_map(&describe_wav));
                        events.push("stopped".into());
                        done = true;
                    }
                }
            }
            while let Ok(event) = cancelled.try_next() {
                assert!(!cancel_done);
                assert_eq!(
                    event,
                    Event::Stopped,
                    "cancel-before-start emitted audio/readiness"
                );
                cancel_events.push("stopped");
                cancel_done = true;
            }
        }
        let mut expected_written = segments.clone();
        for segment in &mut expected_written {
            segment.as_object_mut().unwrap().remove("bodyCount");
        }
        assert_eq!(
            written_segments, expected_written,
            "native ingress to owned WAV differs"
        );
        drop(pipeline);
        assert!(
            !segment_directory.exists(),
            "owned segment directory leaked"
        );
        output.push(json!({"name":case["name"],"sampleCount":sample_count,"pcmSHA256":format!("{:x}",digest.finalize()),
            "chunks":chunks,"segments":segments,"events":events,"cancelEvents":cancel_events}));
    }
    println!("{}", serde_json::to_string(&output).unwrap());
}

#[cfg(not(all(target_os = "macos", debug_assertions)))]
fn main() {
    eprintln!("native capture verification requires a debug macOS build");
    std::process::exit(2);
}
