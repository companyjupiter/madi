use madi_core::transcript::{Line, archive};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Read,
};

#[derive(Deserialize)]
struct Case {
    lines: Vec<Line>,
    names: BTreeMap<i64, String>,
    summary: Option<String>,
    archive: Option<String>,
}
fn hex(text: &str) -> String {
    text.as_bytes().iter().map(|b| format!("{b:02x}")).collect()
}
fn pairs(values: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    values
        .iter()
        .map(|(key, value)| (hex(key), hex(value)))
        .collect()
}
fn parsed(text: &str) -> Value {
    let Some(parsed) = archive::parse(text) else {
        return Value::Null;
    };
    let mut ids = BTreeSet::new();
    let unique = parsed.lines.iter().all(|line| {
        if line.words.is_empty() {
            ids.insert(line.id)
        } else {
            line.words.iter().all(|word| ids.insert(word.id))
        }
    });
    let lines: Vec<_> = parsed.lines.iter().map(|line|json!({
        "speaker":line.speaker, "start":format!("{:016x}",line.start.to_bits()), "end":format!("{:016x}",line.end.to_bits()),
        "text":hex(&line.text()), "overlap":line.overlap_speakers, "margin":format!("{:016x}",line.speaker_margin.to_bits()),
        "translations":pairs(&line.translations), "stale":pairs(&line.stale_translations),
        "edited":line.edited_translations.iter().map(|key|hex(key)).collect::<BTreeSet<_>>(),
        "suppressed":line.suppressed_translations.iter().map(|key|hex(key)).collect::<BTreeSet<_>>(),
        "editedText":line.edited_text.as_deref().map(hex),
        "firstWordIdentity":line.words.first().is_none_or(|word|word.id==line.id),
        "words":line.words.iter().map(|word|format!("{:016x}:{:016x}:{:016x}:{}",word.t0.to_bits(),word.t1.to_bits(),word.conf.to_bits(),hex(&word.text))).collect::<Vec<_>>()
    })).collect();
    json!({"lines":lines,"names":parsed.names.iter().map(|(id,name)|(id.to_string(),hex(name))).collect::<BTreeMap<_,_>>(),"uniqueIdentities":unique})
}
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let results:Vec<_>=cases.iter().map(|case| {
        let markdown=archive::markdown(&case.lines,&case.names,case.summary.as_deref());
        json!({"markdown":hex(&markdown),"plain":hex(&archive::plain_text(&case.lines,&case.names)),
            "reopened":parsed(&markdown),"archive":case.archive.as_deref().map(parsed)})
    }).collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
