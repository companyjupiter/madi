use madi_core::capture_stream::Configuration;
use madi_platform::capture_pipeline::{CapturePipeline, Event, OwnedWav};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Read},
    path::Path,
};

#[derive(Deserialize)]
struct Case {
    name: String,
    configuration: Configuration,
    operations: Vec<Operation>,
}
#[derive(Deserialize)]
struct Operation {
    #[serde(rename = "type")]
    kind: String,
    count: Option<usize>,
    pattern: Option<Vec<i16>>,
    microphone: Option<bool>,
    configuration: Option<Configuration>,
}
fn file(path: &Path) -> Value {
    let bytes = fs::read(path).unwrap();
    json!({"name":path.file_name().unwrap().to_str().unwrap(),"bytes":bytes.len(),"sha256":format!("{:x}",Sha256::digest(bytes))})
}
fn wav(kind: &str, offset: f64, owned: OwnedWav) -> Value {
    let mut value = file(owned.path());
    value["type"] = kind.into();
    value["offsetBits"] = format!("{:016x}", offset.to_bits()).into();
    value
}
fn describe(event: Event) -> Value {
    match event {
        Event::Level(level) => json!({"type":"level","bits":format!("{:08x}",level.to_bits())}),
        Event::Segment {
            offset,
            wav: owned,
            had_speech,
        } => {
            let mut value = wav("segment", offset, owned);
            value["hadSpeech"] = had_speech.into();
            value
        }
        Event::Preview { offset, wav: owned } => wav("preview", offset, owned),
        Event::WriteFailed { name, error, .. } => panic!("{name}: {error}"),
    }
}
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let scratch = tempfile::tempdir().unwrap();
    let mut results = Vec::new();
    for case in cases {
        let mut capture = CapturePipeline::new(case.configuration, scratch.path()).unwrap();
        let directory = capture.directory().to_owned();
        let mut states = Vec::new();
        for operation in case.operations {
            let events = match operation.kind.as_str() {
                "start" => {
                    capture.start();
                    vec![]
                }
                "pause" => {
                    capture.pause();
                    vec![]
                }
                "resume" => {
                    capture.resume();
                    vec![]
                }
                "configure" => {
                    capture.configure(operation.configuration.unwrap()).unwrap();
                    vec![]
                }
                "stop" => capture.stop(),
                "abort" => capture.abort(),
                "ingest" => {
                    let pattern = operation.pattern.unwrap();
                    let pcm: Vec<_> = (0..operation.count.unwrap())
                        .map(|i| pattern[i % pattern.len()])
                        .collect();
                    capture.ingest(&pcm, operation.microphone.unwrap())
                }
                _ => panic!("unknown capture operation"),
            };
            states.push(events.into_iter().map(describe).collect::<Vec<_>>());
        }
        let mut paths: Vec<_> = fs::read_dir(&directory)
            .unwrap()
            .map(|p| p.unwrap().path())
            .collect();
        paths.sort();
        let files: Vec<_> = paths.iter().map(|p| file(p)).collect();
        drop(capture);
        results.push(json!({"name":case.name,"states":states,"files":files,"directoryCleaned":!directory.exists()}));
    }
    assert_eq!(fs::read_dir(scratch.path()).unwrap().count(), 0);
    println!("{}", serde_json::to_string(&results).unwrap());
}
