use madi_core::{coverage::Coverage, hang_watchdog::Watchdog, session::Phase};
use serde_json::{Value, json};
use std::io::{self, Read};
fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Vec<Value>> = serde_json::from_str(&input).unwrap();
    let output:Vec<_>=cases.into_iter().map(|actions| {
        let mut coverage=Coverage::<String>::default();let mut watchdog=Watchdog::new(0.);let mut broken=false;
        actions.into_iter().map(|a| {
            let now=a["now"].as_f64().unwrap();let mut feeds=vec![];
            match a["type"].as_str().unwrap() {
                "feed"=>coverage.feed(a["offset"].as_f64().unwrap(),a["audio"].as_str().unwrap().into(),a["speech"].as_bool().unwrap(),now),
                "activity"=>watchdog.activity(now),
                "word"=>{watchdog.activity(now);coverage.word();},
                "end"=>{watchdog.activity(now);if let Some(job)=coverage.segment_end(now){feeds.push(job);}},
                "retire"=>coverage.retire_pending(),
                "reset"=>{coverage=Coverage::default();watchdog.recoveries=0;broken=false;},
                "tick"=>{
                    let phase=match a["phase"].as_str().unwrap(){"recording"=>Phase::Recording,"paused"=>Phase::Paused,"flushing"=>Phase::Flushing,"done"=>Phase::Done,_=>Phase::Idle};
                    if watchdog.tick(&phase,coverage.oldest_fed_at(),now) {
                        broken=true;
                        if a["replace"].as_bool().unwrap() {feeds=coverage.refeed(now);}
                    }
                },
                other=>panic!("unknown {other}"),
            }
            // Snapshot fedAt without refreshing it. Public queue inspection is
            // unnecessary in product code; serialize a nonmutating iterator.
            json!({"state":coverage,"fedAt":coverage.pending_jobs().map(|j|j.fed_at).collect::<Vec<_>>(),"recoveries":watchdog.recoveries,"broken":broken,"feeds":feeds})
        }).collect::<Vec<_>>()
    }).collect();
    println!("{}", serde_json::to_string(&output).unwrap());
}
