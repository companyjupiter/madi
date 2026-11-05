use madi_core::{
    glossary::Glossary,
    personal_vocabulary as vocabulary,
    transcript::{Line, Word},
};
use serde::Deserialize;
use serde_json::json;
use std::io::{self, Read};
#[derive(Deserialize)]
struct Pair {
    before: String,
    after: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    glossary: Glossary,
    queries: Vec<String>,
    pairs: Vec<Pair>,
    words: Vec<Word>,
    edited_text: Option<String>,
}
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let output: Vec<_> = cases.into_iter().map(|case| {
        let rules = case.glossary.active_entries();
        let line = Line { id: uuid::Uuid::from_u128(1), speaker: 7, start: 0.0, end: 100.0, words: case.words.clone(),
            overlap_speakers: Vec::new(), speaker_margin: 1.0, translations: Default::default(), stale_translations: Default::default(),
            edited_translations: Default::default(), suppressed_translations: Default::default(), edited_text: case.edited_text };
        json!({
            "normalize": case.queries.iter().map(|raw| vocabulary::normalize(raw)).collect::<Vec<_>>(),
            "surface": case.queries.iter().map(|raw| vocabulary::surface_form(raw)).collect::<Vec<_>>(),
            "keys": case.queries.iter().map(|raw| vocabulary::normalize_keys(raw)).collect::<Vec<_>>(),
            "script": case.queries.iter().map(|raw| vocabulary::is_bias_script(raw)).collect::<Vec<_>>(),
            "match": case.queries.iter().map(|raw| vocabulary::match_token(raw, &rules, &case.glossary)).collect::<Vec<_>>(),
            "diff": case.pairs.iter().map(|pair| vocabulary::diff(&pair.before, &pair.after)).collect::<Vec<_>>(),
            "scores": case.pairs.iter().map(|pair| format!("{:016x}", vocabulary::jaro_winkler(&pair.before, &pair.after).to_bits())).collect::<Vec<_>>(),
            "bias": vocabulary::bias_terms(&case.glossary),
            "incoming": case.words.iter().map(|word| vocabulary::correct_incoming_text(&word.text, word.conf, &case.glossary)).collect::<Vec<_>>(),
            "line": vocabulary::corrected_line_text(&line, &case.glossary),
        })
    }).collect();
    println!("{}", serde_json::to_string(&output).unwrap());
}
