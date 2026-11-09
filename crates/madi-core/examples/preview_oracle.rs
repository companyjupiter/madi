use madi_core::preview::{self, Scheduler, SourceGate};
use madi_protocol::transcribe::Event;
use serde_json::{Value, json};
use std::io::{self, Read};
fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect()
}
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Value> = serde_json::from_str(&input).unwrap();
    let results:Vec<Value>=cases.iter().map(|c|match c["kind"].as_str().unwrap() {
        "trim"=>json!({"forced":preview::forced_prefix(&strings(&c["committed"]),c["gate"].as_str().unwrap()),"tail":preview::visible_tail(&strings(&c["words"]),c["forced"].as_str().unwrap()),"counted":preview::trim_by_count(c["text"].as_str().unwrap(),c["count"].as_u64().unwrap() as usize),"bounded":preview::bounded_partial(c["text"].as_str().unwrap())}),
        "gate"=>{
            let mut gate=SourceGate::default();gate.max_stall=c["maxStall"].as_u64().unwrap() as usize;gate.fast_first=c["fastFirst"].as_bool().unwrap();
            Value::Array(c["sequence"].as_array().unwrap().iter().map(|v| {
                let shown=if let Some(text)=v.as_str(){gate.commit(text)}else{gate.reset();String::new()};
                json!({"shown":shown,"committed":gate.committed_text()})
            }).collect())
        },
        "scheduler"=>{
            let mut lane=Scheduler::<String>::default();let mut submitted=Vec::<Value>::new();let mut shown=Vec::<String>::new();
            Value::Array(c["operations"].as_array().unwrap().iter().map(|op| {
                let mut consumed=Value::Null;
                match op["op"].as_str().unwrap() {
                    "start"=>lane.start(),"stop"=>lane.stop(),"admit"=>lane.set_admitted(op["value"].as_bool().unwrap()),
                    "feed"=>lane.feed(op["id"].as_str().unwrap().into(),op["offset"].as_f64().unwrap()),
                    "event"=>{
                        let event=match op["event"].as_str().unwrap(){
                            "begin"=>Event::PreviewBegin,"end"=>Event::PreviewEnd,"partial"=>Event::PreviewPartial("ignored".into()),
                            "word"=>Event::PreviewWord{t0:0.,t1:0.1,text:op["text"].as_str().unwrap().into()},
                            "segment"=>Event::SegmentEnd,_=>Event::FlushEnd};
                        let result=lane.consume(&event);consumed=json!(result.is_some());
                        if let Some(Some(text))=result {shown.push(text);}
                    },_=>panic!("unknown operation")
                }
                if let Some((id,offset))=lane.take_ready(){let forced=format!("forced {}",submitted.len());lane.submitted(forced.clone());submitted.push(json!({"id":id,"offset":offset,"forced":forced}));}
                json!({"submitted":submitted,"shown":shown,"consumed":consumed})
            }).collect())
        },
        _=>Value::Null,
    }).collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
