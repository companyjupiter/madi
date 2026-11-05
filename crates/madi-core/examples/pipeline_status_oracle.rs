use madi_core::{
    pipeline_status::{self, Signals},
    preferences::UILanguage,
};
use serde::Deserialize;
use std::io::{self, Read};
#[derive(Deserialize)]
struct Case {
    signals: Signals,
    language: UILanguage,
}
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let values: Vec<_> = cases
        .iter()
        .map(|c| pipeline_status::presentation(&c.signals, c.language))
        .collect();
    println!("{}", serde_json::to_string(&values).unwrap());
}
