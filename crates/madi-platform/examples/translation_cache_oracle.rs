use madi_core::translation::cache::{Entry, Faq, Interim, faq_normalize};
use serde_json::{Value, json};
use std::io::{self, Read};
fn main() {
    let native = std::env::args().any(|a| a == "--native-foundation");
    let mut raw = String::new();
    io::stdin().read_to_string(&mut raw).unwrap();
    let cases: Vec<Value> = serde_json::from_str(&raw).unwrap();
    let mut results = Vec::new();
    for c in cases {
        let text = c["text"].as_str().unwrap();
        let entries = if c["entries"].is_null() {
            Faq::starter_entries()
        } else {
            serde_json::from_value(c["entries"].clone()).unwrap()
        };
        let faq = if native {
            madi_platform::translation_cache::faq(entries)
        } else {
            Faq::new(entries)
        };
        let queries: Vec<_> = c["queries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|q| faq.lookup(q.as_str().unwrap()))
            .collect();
        let mut cache = Interim::new(c["capacity"].as_i64().unwrap());
        let mut states = Vec::new();
        for op in c["ops"].as_array().unwrap() {
            let source = op["source"].as_str().unwrap_or("");
            let mut hit: Option<Entry> = None;
            match op["op"].as_str().unwrap() {
                "put" => cache.put(
                    source,
                    serde_json::from_value(op["translations"].clone()).unwrap(),
                ),
                "get" => hit = cache.get(source),
                "peek" => hit = cache.peek(source).cloned(),
                "clear" => cache.clear(),
                _ => unreachable!(),
            }
            states.push(json!({"hit":hit,"count":cache.len(),"empty":cache.is_empty()}));
        }
        results.push(json!({"starterEntries":c["includeSeed"].as_bool().unwrap_or(false).then(Faq::starter_entries),"faqNormalized":if native { madi_platform::translation_cache::normalize_faq(text) } else { faq_normalize(text) },"interimNormalized":Interim::normalize(text),"queries":queries,"states":states}));
    }
    println!("{}", serde_json::to_string(&results).unwrap());
}
