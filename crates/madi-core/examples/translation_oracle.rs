use madi_core::translation::{self as t, Example, Queue, Turn, output as p};
use serde_json::{Value, json};
use std::io::{self, Read};
fn string<'a>(c: &'a Value, key: &str) -> &'a str {
    c[key].as_str().unwrap()
}
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Value> = serde_json::from_str(&input).unwrap();
    let mut results = Vec::new();
    for c in cases {
        results.push(match string(&c,"kind") {
            "policy"=>{
                let source=string(&c,"source");let text=string(&c,"text");let target=string(&c,"target");
                let example=c["example"].as_str();let example_source=c["exampleSource"].as_str();
                json!({"clean":p::clean(text),"markers":p::strip_prompt_marker_echo(text),"arrows":p::strip_inline_arrows(text),
                    "stripped":p::strip_example_echo(text,example,source),"mayEcho":p::may_be_example_echo(text,example),
                    "replay":p::is_example_replay(text,example,source,example_source),"retry":p::should_retry(text,source,target),
                    "cap":p::token_cap(source),"limit":p::runaway_limit(source,Some(target)),"factor":p::expansion_factor(source,Some(target)),
                    "cut":p::truncate_runaway(text,c["limit"].as_u64().unwrap() as usize),"language":p::source_language(source),
                    "keys":p::echo_keys(text),"similarityBits":format!("{:016x}",p::similarity(text,source).to_bits())})
            }
            "prompt"=>{
                let example:Option<Example>=serde_json::from_value(c["example"].clone()).unwrap();
                let usable=t::usable_example(example.as_ref(),string(&c,"text"),c["maxChars"].as_u64().unwrap() as usize);
                json!({"usable":usable,"body":t::body(string(&c,"text"),usable.as_ref(),string(&c,"anchor"))})
            }
            "shed"=>{
                let requested:Vec<String>=serde_json::from_value(c["requested"].clone()).unwrap();
                let (send,shed)=t::committed_targets(&requested,c["priority"].as_str(),c["backlog"].as_u64().unwrap() as usize,c["threshold"].as_u64().unwrap() as usize);
                json!({"send":send,"shed":shed,"guarantee":t::adaptive_guarantee(c["base"].as_f64().unwrap(),c["backlog"].as_u64().unwrap() as usize)})
            }
            "guarantee"=>{
                let base=f64::from_bits(u64::from_str_radix(string(&c,"baseBits"),16).unwrap());
                json!({"bits":t::adaptive_guarantee(base,c["backlog"].as_u64().unwrap() as usize).map(|n|format!("{:016x}",n.to_bits()))})
            }
            "queue"=>{
                let mut queue=Queue::default();let mut rows=Vec::new();
                for op in c["operations"].as_array().unwrap() {
                    let mut result=json!(null);
                    match string(op,"op") {
                        "enqueue"=>{let turn:Turn=serde_json::from_value(op["turn"].clone()).unwrap();result=json!(queue.enqueue(turn,op["block"].as_bool().unwrap(),op["replace"].as_bool().unwrap()));}
                        "pop"=>result=json!(queue.pop_next()),
                        "shed"=>result=json!(queue.shed_oldest(op["cap"].as_u64().unwrap() as usize)),
                        "reset"=>queue.turns.clear(),_=>unreachable!(),
                    }
                    rows.push(json!({"result":result,"turns":queue.turns,"next":queue.next(),"hasCommitted":queue.has_committed()}));
                }
                json!(rows)
            }
            _=>unreachable!(),
        });
    }
    println!("{}", serde_json::to_string(&results).unwrap());
}
