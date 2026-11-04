use madi_core::setup::{Language, SetupState};
use madi_platform::asr_config::{FileSettings, Resources};
use serde::Deserialize;
use std::{io::Read, path::Path};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    speaker_count: u8,
    diarize: bool,
    osd: bool,
    input_language: Option<Language>,
    physical_memory: u64,
    bias_terms: Vec<String>,
    defaults: bool,
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let resources = Resources {
        executable: "/madi/engine".into(),
        model: "/madi/model".into(),
        bpe: "/madi/bpe".into(),
        assets: "/madi/assets".into(),
    };
    let records: Vec<_> = cases.into_iter().map(|case| {
        let settings = if case.defaults { FileSettings::default() } else {
            FileSettings::from_setup(&SetupState { speaker_count: case.speaker_count, diarize: case.diarize, osd: case.osd, input_language: case.input_language, ..SetupState::default() }, case.physical_memory, case.bias_terms).unwrap()
        };
        let launch = resources.file_launch(Path::new("/madi/owned/input.wav"), &settings).unwrap();
        let environment: std::collections::BTreeMap<_, _> = launch.environment.into_iter().filter_map(|(key, value)| value.map(|value| (key.to_string_lossy().into_owned(), value.to_string_lossy().into_owned()))).collect();
        serde_json::json!({"executable":launch.executable,"cwd":launch.working_directory,"arguments":launch.arguments.iter().map(|arg|arg.to_string_lossy()).collect::<Vec<_>>(),"environment":environment})
    }).collect();
    println!("{}", serde_json::to_string(&records).unwrap());
}
