use madi_core::{
    assets::TranslationVariant,
    model_setup::{ModelReadiness, ModelSetupChoice},
};
use serde::Deserialize;
use serde_json::json;
use std::io::Read;

#[derive(Deserialize)]
struct Case {
    #[serde(flatten)]
    readiness: ModelReadiness,
    choice: Option<ModelSetupChoice>,
    variant: TranslationVariant,
}

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let results: Vec<_> = cases
        .iter()
        .map(|case| {
            json!({
                "canEnterApp":case.readiness.can_enter_app(case.choice),
                "downloadBytes":case.choice.map(|choice|case.readiness.download_bytes(choice,case.variant)),
            })
        })
        .collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
