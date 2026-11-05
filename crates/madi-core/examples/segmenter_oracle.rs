use madi_core::segmenter::{Configuration, Segment, Segmenter};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::io::{self, Read};
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
    phase: Option<usize>,
    configuration: Option<Configuration>,
}
fn pcm(offset: f64, samples: &[i16]) -> Value {
    let bytes: Vec<_> = samples
        .iter()
        .flat_map(|value| value.to_le_bytes())
        .collect();
    json!({"offsetBits":format!("{:016x}",offset.to_bits()),"sampleCount":samples.len(),"pcmSHA256":format!("{:x}",Sha256::digest(bytes))})
}
fn snapshot(stream: &Segmenter, segments: Vec<Segment>) -> Value {
    let (offset, samples) = stream.preview_window();
    let segments: Vec<_> = segments
        .into_iter()
        .map(|segment| {
            let mut result = pcm(segment.offset, &segment.samples);
            result["bodyCount"] = segment.body_count.into();
            result["hadSpeech"] = segment.had_speech.into();
            result
        })
        .collect();
    json!({"segments":segments,"pendingCount":stream.pending_count(),"preview":pcm(offset,&samples)})
}
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let results: Vec<_> = cases
        .into_iter()
        .map(|case| {
            let mut stream = Segmenter::new(case.configuration).unwrap();
            let mut states = vec![snapshot(&stream, vec![])];
            for operation in case.operations {
                let segments = match operation.kind.as_str() {
                    "push" => {
                        let pattern = operation.pattern.unwrap();
                        let phase = operation.phase.unwrap_or(0);
                        let frames: Vec<_> = (0..operation.count.unwrap())
                            .map(|index| pattern[(index + phase) % pattern.len()])
                            .collect();
                        stream.push(&frames)
                    }
                    "flush" => stream.flush().into_iter().collect(),
                    "configure" => {
                        stream.configure(operation.configuration.unwrap()).unwrap();
                        vec![]
                    }
                    _ => panic!("unknown operation"),
                };
                states.push(snapshot(&stream, segments));
            }
            json!({"name":case.name,"states":states})
        })
        .collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
