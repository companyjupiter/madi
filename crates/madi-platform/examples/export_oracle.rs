use madi_core::transcript::{
    Line,
    export::{self, CaptionSpec, EditorSettings},
};
use serde::Deserialize;
use serde_json::json;
use std::{collections::BTreeMap, io::Read};
#[derive(Deserialize)]
struct Case {
    lines: Vec<Line>,
    names: BTreeMap<i64, String>,
    #[serde(default)]
    spec: CaptionSpec,
    #[serde(default)]
    settings: EditorSettings,
}
fn hex(text: &str) -> String {
    text.bytes().map(|byte| format!("{byte:02x}")).collect()
}
fn main() {
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&text).unwrap();
    let results:Vec<_>=cases.iter().map(|case|json!({
        "srt":hex(&export::srt(&case.lines,&case.names,&case.spec)),"vtt":hex(&export::vtt(&case.lines,&case.names,&case.spec)),
        "cues":export::caption_cues(&case.lines,&case.names,&case.spec).iter().map(|cue|json!({"start":format!("{:016x}",cue.start.to_bits()),"end":format!("{:016x}",cue.end.to_bits()),"lines":cue.lines.iter().map(|line|hex(line)).collect::<Vec<_>>()})).collect::<Vec<_>>(),
        "json":export::json(&case.lines,&case.names,&case.settings),
        "jsonUtf8":hex(&madi_platform::transcript_export::format_json(&export::json(&case.lines,&case.names,&case.settings)).unwrap()),"settings":case.settings
    })).collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
