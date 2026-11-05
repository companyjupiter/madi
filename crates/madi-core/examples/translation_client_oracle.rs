use madi_core::{
    transcript::Uuid,
    translation::{
        Kind,
        client::{Client, Configuration, Effect, Request},
    },
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{self, Read},
    time::Duration,
};
fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap()
}
fn drain(c: &mut Client, tickets: &mut BTreeSet<u64>, pressure: &mut usize) -> Vec<Value> {
    c.take_effects().into_iter().filter_map(|e|Some(match e {
        Effect::Submit{ticket,request,priority}=>{tickets.insert(ticket);match request {
            Request::Prefix{slot,text}=>json!({"event":"submit","ticket":ticket,"kind":"prefix","slot":slot,"text":text,"priority":priority as i32}),
            Request::Turn{prompt}=>json!({"event":"submit","ticket":ticket,"kind":"turn","text":prompt,"priority":priority as i32}),
        }},
        Effect::Partial(t)=>json!({"event":"partial","id":t.id,"language":t.language,"source":t.source,"text":t.text}),
        Effect::Result(t)=>json!({"event":"result","id":t.id,"language":t.language,"source":t.source,"text":t.text}),
        Effect::Drop{id,language,source}=>json!({"event":"drop","id":id,"language":language,"source":source}),
        Effect::Discard{id,language,source}=>json!({"event":"discard","id":id,"language":language,"source":source}),
        Effect::Depth{turns,lines}=>{*pressure=turns;json!({"event":"depth","turns":turns,"lines":lines})},
        Effect::Pressure(n)=>{*pressure=n;return None;},
    })).collect()
}
fn main() {
    let mut raw = String::new();
    io::stdin().read_to_string(&mut raw).unwrap();
    let cases: Vec<Value> = serde_json::from_str(&raw).unwrap();
    let mut results = Vec::new();
    for case in cases {
        let cfg = &case["config"];
        let mut c = Client::new(
            Configuration {
                priority_language: cfg["priority"].as_str().map(str::to_owned),
                max_pending: cfg["maxPending"].as_u64().unwrap() as usize,
                shed_secondary_targets_at: cfg["shedAt"].as_u64().unwrap() as usize,
                interim_guarantee_seconds: cfg["guarantee"].as_f64().unwrap(),
            },
            Duration::ZERO,
        );
        let mut tickets = BTreeSet::new();
        let mut pressure = 0;
        let mut rows = Vec::new();
        for op in case["ops"].as_array().unwrap() {
            let mut accepted = Value::Null;
            match s(op, "op") {
                "ready" => c.ready(1, op["fp"].as_bool().unwrap()),
                "translate" => {
                    let targets: Vec<String> =
                        serde_json::from_value(op["targets"].clone()).unwrap();
                    let forced: BTreeMap<String, String> =
                        serde_json::from_value(op["forced"].clone()).unwrap();
                    accepted = json!(c.translate(
                        s(op, "text"),
                        &targets,
                        Uuid::parse_str(s(op, "id")).unwrap(),
                        if s(op, "kind") == "interim" {
                            Kind::Interim
                        } else {
                            Kind::Committed
                        },
                        &forced,
                        op["time"].as_f64().unwrap()
                    ));
                }
                "complete" => {
                    let ticket = if op["last"].as_bool().unwrap() {
                        tickets.pop_last()
                    } else {
                        tickets.pop_first()
                    };
                    if let Some(ticket) = ticket {
                        c.complete(ticket, op["text"].as_str());
                    }
                }
                "partial" => {
                    if let Some(&ticket) = tickets.first() {
                        c.partial(
                            ticket,
                            1,
                            s(op, "text"),
                            Duration::from_nanos(op["ns"].as_u64().unwrap()),
                        );
                    }
                }
                "stop" => {
                    c.stop();
                    tickets.clear();
                }
                _ => unreachable!(),
            }
            let events = drain(&mut c, &mut tickets, &mut pressure);
            rows.push(json!({"accepted":accepted,"events":events,"pressure":pressure,"runaways":c.runaway_truncations()}));
        }
        results.push(rows);
    }
    println!("{}", serde_json::to_string(&results).unwrap());
}
