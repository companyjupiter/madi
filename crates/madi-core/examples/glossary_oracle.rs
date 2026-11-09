use madi_core::glossary::Glossary;
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{self, Read};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Operation {
    kind: String,
    wrong: Option<String>,
    right: Option<String>,
    min_hits: Option<i64>,
    enabled: Option<bool>,
}
#[derive(Deserialize)]
struct Case {
    raw: Option<String>,
    operations: Vec<Operation>,
    queries: Vec<String>,
}
fn snapshot(glossary: &Glossary, queries: &[String]) -> Value {
    json!({ "stored": glossary, "active": glossary.active_entries(),
        "display": glossary.display_entries(),
        "exact": queries.iter().map(|q| glossary.exact(q)).collect::<Vec<_>>() })
}
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let results: Vec<_> = cases
        .into_iter()
        .map(|case| {
            let decoded = case
                .raw
                .as_ref()
                .and_then(|raw| serde_json::from_str::<Glossary>(raw).ok());
            let accepted = case.raw.is_none() || decoded.is_some();
            let mut glossary = decoded.unwrap_or_default();
            let mut states = vec![snapshot(&glossary, &case.queries)];
            for op in case.operations {
                match op.kind.as_str() {
                    "learn" => glossary
                        .learn(op.wrong.as_deref().unwrap(), op.right.as_deref().unwrap())
                        .unwrap(),
                    "clear" => glossary.clear(),
                    "forget" => glossary.forget(op.wrong.as_deref().unwrap()),
                    "enabled" => glossary.enabled = op.enabled.unwrap(),
                    "minHits" => glossary.min_hits = op.min_hits.unwrap(),
                    _ => panic!("unknown operation"),
                }
                states.push(snapshot(&glossary, &case.queries));
            }
            json!({ "decoded": accepted, "states": states })
        })
        .collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
