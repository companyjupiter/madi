use madi_core::transcript::{Word, word_merger::WordMerger};
use serde::Deserialize;
use serde_json::json;
use std::io::Read;

#[derive(Deserialize)]
struct Step {
    op: String,
    word: Option<Word>,
    #[serde(default = "yes")]
    inspect: bool,
}
fn yes() -> bool {
    true
}
#[derive(Deserialize)]
struct Case {
    steps: Vec<Step>,
}
fn words(words: &[Word]) -> Vec<String> {
    words
        .iter()
        .map(|word| {
            format!(
                "{}:{:016x}:{:016x}:{:016x}:{}",
                word.id,
                word.t0.to_bits(),
                word.t1.to_bits(),
                word.conf.to_bits(),
                word.text
                    .as_bytes()
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<String>()
            )
        })
        .collect()
}
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let results: Vec<_> = cases.into_iter().map(|case| {
        let mut merger = WordMerger::default();
        let mut states = Vec::new();
        for step in case.steps {
            match step.op.as_str() {
                "word" => merger.add(step.word.unwrap()),
                "break" => merger.segment_break(),
                "finish" => merger.finish(),
                "snapshot" => (),
                _ => panic!("unknown word merger operation"),
            }
            if step.inspect {
                states.push(json!({
                    "committed":words(merger.committed()), "display":words(&merger.display_words(0)),
                    "tail":words(&merger.display_words(1)), "beyond":words(&merger.display_words(usize::MAX)),
                    "since":words(merger.committed_since(0.7)), "displayedSince":words(&merger.displayed_since(0.7)),
                    "held":merger.held_word_id().map(|id|id.to_string()), "heldText":merger.held_word().map(|word| &word.text),
                    "end":format!("{:016x}",merger.committed_end().to_bits()),
                    "seamDropped":merger.seam_duplicates_dropped, "instantDropped":merger.same_instant_duplicates_dropped,
                }));
            }
        }
        states
    }).collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
