use madi_core::coverage::Coverage;
use serde_json::{Value, json};
use std::io::{self, Read};
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    // Value retains arbitrary-precision JSON numbers until this input boundary.
    let cases: Vec<Vec<Value>> = serde_json::from_str(&input).unwrap();
    let output: Vec<_> = cases
        .into_iter()
        .map(|actions| {
            let mut coverage = Coverage::<String>::default();
            actions
                .into_iter()
                .map(|action| {
                    let mut retry = None;
                    match action["type"].as_str().unwrap() {
                        "feed" => coverage.feed(
                            action["offset"].as_f64().unwrap(),
                            action["audio"].as_str().unwrap().into(),
                            action["hadSpeech"].as_bool().unwrap(),
                            0.,
                        ),
                        "word" => coverage.word(),
                        "previewWord" => (),
                        "segmentEnd" => retry = coverage.segment_end(0.),
                        "retire" => coverage.retire_pending(),
                        "reset" => coverage = Coverage::default(),
                        other => panic!("unknown action: {other}"),
                    }
                    json!({"state":coverage,"pending":coverage.pending(),"retry":retry})
                })
                .collect::<Vec<_>>()
        })
        .collect();
    println!("{}", serde_json::to_string(&output).unwrap());
}
