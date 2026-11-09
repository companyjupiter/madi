use madi_core::assets::{TRANSCRIPTION, TRANSLATION_2B, TRANSLATION_4B, TranslationVariant};
use madi_platform::model_assets;
use serde::Deserialize;
use serde_json::json;
use std::{io::Read, path::PathBuf};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Input {
    memories: Vec<u64>,
    overrides: Vec<Option<String>>,
    files: Vec<Integrity>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Integrity {
    path: PathBuf,
    size: u64,
    sha256: String,
    hash_input: bool,
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let input: Input = serde_json::from_str(&input).unwrap();
    let choices: Vec<_> = input.memories.iter().flat_map(|memory| input.overrides.iter().map(move |value| {
        let selected = TranslationVariant::selected(*memory, value.as_deref());
        json!({"memory":memory,"override":value,"recommended":TranslationVariant::recommended(*memory),"selected":selected,"engine":selected.engine_name(),"displayName":selected.display_name()})
    })).collect();
    let files: Vec<_> = input
        .files
        .iter()
        .map(|case| {
            json!({
                "valid":model_assets::file_is_valid(&case.path,case.size,&case.sha256),
                "hash":if case.hash_input { model_assets::sha256(&case.path).ok() } else { None },
            })
        })
        .collect();
    println!(
        "{}",
        json!({"assets":[TRANSCRIPTION,TRANSLATION_4B,TRANSLATION_2B],"choices":choices,"files":files})
    );
}
