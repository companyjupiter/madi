use madi_core::translation::committed::{self, Input};
use serde_json::{Value, json};
use std::io::{self, Read};
fn main() {
    let mut raw = String::new();
    io::stdin().read_to_string(&mut raw).unwrap();
    let cases: Vec<Value> = serde_json::from_str(&raw).unwrap();
    let result: Vec<_> = cases.iter().map(|case| {
        let text = case["text"].as_str().unwrap();
        let lines: Vec<Input> = serde_json::from_value(case["lines"].clone()).unwrap();
        json!({
            "fragment": committed::is_fragment(text, case["maxWords"].as_u64().unwrap() as usize, case["softMaxWords"].as_u64().unwrap() as usize),
            "endsSentence": committed::ends_sentence(text),
            "language": committed::script_language(text),
            "runs": committed::runs(&lines, case["maxGap"].as_f64().unwrap(), case["deferTrailing"].as_bool().unwrap()),
        })
    }).collect();
    println!("{}", serde_json::to_string(&result).unwrap());
}
