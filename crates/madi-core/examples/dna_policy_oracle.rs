use madi_core::dna::{self, Candidate};
use serde_json::{Value, json};
use std::io::{self, Read};

fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Value> = serde_json::from_str(&input).unwrap();
    let results: Vec<Value> = cases
        .iter()
        .map(|case| match case["kind"].as_str().unwrap() {
            "budget" => json!(format!(
                "{:016x}",
                dna::turn_budget_seconds(
                    case["bytes"].as_i64().unwrap(),
                    case["steps"].as_i64().unwrap(),
                    case["engine"].as_str().unwrap()
                )
                .to_bits()
            )),
            "select" => {
                let items: Vec<_> = case["items"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|item| Candidate {
                        priority: item[0].as_i64().unwrap() as i32,
                        sequence: item[1].as_u64().unwrap(),
                        waited_seconds: item[2].as_f64().unwrap(),
                    })
                    .collect();
                json!(dna::eligible_index(
                    &items,
                    case["pressure"].as_i64().unwrap(),
                    case["aging"].as_f64().unwrap()
                ))
            }
            "line" => json!(dna::one_line(case["text"].as_str().unwrap())),
            "override" => json!(
                dna::timeout_override(case["text"].as_str().unwrap())
                    .map(|s| format!("{:016x}", s.to_bits()))
            ),
            other => panic!("unexpected case {other}"),
        })
        .collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
