use madi_core::korean_numbers;
use serde::Deserialize;
use serde_json::json;
use std::io::{self, Read};

#[derive(Deserialize)]
struct Case {
    name: String,
    text: String,
}
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let values: Vec<_> = cases.into_iter().map(|case| {
        let formatted = korean_numbers::format(&case.text);
        let (value, consumed) = korean_numbers::parse_native(&case.text);
        json!({"name": case.name, "formatted": formatted, "twice": korean_numbers::format(&formatted), "sino": korean_numbers::parse_sino(&case.text), "native": {"value": value, "consumed": consumed}})
    }).collect();
    println!("{}", serde_json::to_string(&values).unwrap());
}
