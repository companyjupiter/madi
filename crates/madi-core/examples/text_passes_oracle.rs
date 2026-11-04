use madi_core::{
    glossary::Glossary,
    text_passes::TextPasses,
    transcript::{Line, TranscriptStore, Uuid, Word},
};
use madi_protocol::transcribe::Event;
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{self, Read};

#[derive(Deserialize)]
struct Case {
    steps: Vec<Value>,
}
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let mut results = Vec::new();
    for case in cases {
        let mut store = TranscriptStore::default();
        let mut passes = TextPasses::default();
        let mut glossary = Glossary::default();
        let mut enabled = false;
        let mut partial = String::new();
        let mut states = Vec::new();
        for step in case.steps {
            let index = step["index"].as_u64().unwrap_or(0) as usize;
            let id = store
                .lines()
                .get(index)
                .map(|line| line.id)
                .unwrap_or(Uuid::from_u128(u128::MAX));
            match step["op"].as_str().unwrap() {
                "rows" => {
                    let rows: Vec<Vec<Word>> =
                        serde_json::from_value(step["rows"].clone()).unwrap();
                    store.load(
                        rows.into_iter()
                            .map(|words| Line {
                                id: words[0].id,
                                speaker: 1,
                                start: words[0].t0,
                                end: words.last().unwrap().t1,
                                words,
                                overlap_speakers: Default::default(),
                                speaker_margin: 1.0,
                                translations: Default::default(),
                                stale_translations: Default::default(),
                                edited_translations: Default::default(),
                                suppressed_translations: Default::default(),
                                edited_text: None,
                            })
                            .collect(),
                    );
                }
                "word" => {
                    store.ingest_word(serde_json::from_value(step["word"].clone()).unwrap());
                    passes.stable(&mut store, Some(&glossary), enabled, &partial, false);
                }
                "break" => {
                    partial.clear();
                    store.ingest(&Event::WordSectionBegin);
                    passes.stable(&mut store, Some(&glossary), enabled, &partial, false);
                }
                "targets" => enabled = step["flag"].as_bool().unwrap(),
                "partial" => partial = step["text"].as_str().unwrap().into(),
                "enabled" => glossary.enabled = step["flag"].as_bool().unwrap(),
                "learn" => {
                    glossary
                        .learn(
                            step["text"].as_str().unwrap(),
                            step["right"].as_str().unwrap(),
                        )
                        .unwrap();
                }
                "stable" => passes.stable(
                    &mut store,
                    Some(&glossary),
                    enabled,
                    &partial,
                    step["flag"].as_bool().unwrap_or(false),
                ),
                "all" => passes.finalize(&mut store, Some(&glossary)),
                "finish" => {
                    store.finalize();
                    passes.finalize(&mut store, Some(&glossary));
                }
                "edit" => {
                    passes.mark_user_edited(id);
                    store.edit_line(id, step["text"].as_str().unwrap(), None);
                }
                "editWord" => {
                    store.edit_word(id, 0, step["text"].as_str().unwrap());
                }
                "reset" => {
                    store.reset();
                    passes.reset();
                }
                _ => panic!("unknown text-pass operation"),
            }
            states.push(store.lines().iter().map(|line| json!({"id":line.id,"text":line.text(),"edited":line.edited_text,"words":line.words})).collect::<Vec<_>>());
        }
        results.push(states);
    }
    println!("{}", serde_json::to_string(&results).unwrap());
}
