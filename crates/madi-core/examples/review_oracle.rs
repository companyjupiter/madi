use madi_core::{
    review::{self, Controller, Span},
    transcript::{Line, Uuid, Word},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::io;

#[derive(Deserialize)]
struct Input {
    controllers: Vec<Case>,
}
#[derive(Deserialize)]
struct Case {
    versions: Vec<Version>,
    actions: Vec<Action>,
}
#[derive(Deserialize)]
struct Version {
    lines: Vec<InputLine>,
    threshold: f64,
}
#[derive(Deserialize)]
struct InputLine {
    id: Uuid,
    words: Vec<InputWord>,
}
#[derive(Deserialize)]
struct InputWord {
    text: String,
    conf: f64,
    t0: f64,
    t1: f64,
}
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum Action {
    Refresh {
        version: usize,
    },
    Toggle {
        #[serde(rename = "canPlay")]
        can_play: bool,
    },
    Advance,
    Stop,
    Jump {
        delta: i64,
    },
}
fn span(value: &Span) -> Value {
    json!({"lineId":value.line_id,"text":value.text,"t0":value.t0,"t1":value.t1})
}
fn lines(input: Vec<InputLine>) -> Vec<Line> {
    input
        .into_iter()
        .map(|line| Line {
            id: line.id,
            speaker: 0,
            start: 0.0,
            end: 0.0,
            words: line
                .words
                .into_iter()
                .enumerate()
                .map(|(i, w)| Word {
                    id: Uuid::from_u128(i as u128),
                    text: w.text,
                    conf: w.conf,
                    t0: w.t0,
                    t1: w.t1,
                })
                .collect(),
            overlap_speakers: vec![],
            speaker_margin: 1.0,
            translations: Default::default(),
            stale_translations: Default::default(),
            edited_translations: Default::default(),
            suppressed_translations: Default::default(),
            edited_text: None,
        })
        .collect()
}
fn main() {
    let input: Input = serde_json::from_reader(io::stdin()).unwrap();
    let result:Vec<_>=input.controllers.into_iter().map(|case| {
        let versions:Vec<_>=case.versions.into_iter().map(|v|(lines(v.lines),v.threshold)).collect();
        let mut controller=Controller::default();
        let trace:Vec<_>=case.actions.into_iter().map(|action| {
            let result=match action {
                Action::Refresh{version}=>{controller.refresh(review::queue(&versions[version].0,versions[version].1));None},
                Action::Toggle{can_play}=>controller.toggle_listening(can_play),
                Action::Advance=>controller.advance(),Action::Stop=>{controller.stop();None},
                Action::Jump{delta}=>{controller.manual_jump(delta);None},
            };
            json!({"listening":controller.is_listening,"index":controller.index,"current":controller.current().map(span),"queue":controller.queue.iter().map(span).collect::<Vec<_>>(),"result":result.as_ref().map(span)})
        }).collect();
        let spacing:Vec<_>=versions.iter().map(|(lines,_)|lines.iter().map(review::word_spacing).collect::<Vec<_>>()).collect();
        let refs:Vec<_>=versions.iter().map(|(lines,threshold)|review::queue(lines,*threshold).iter().map(|s|json!({"lineId":s.line_id,"wordIndex":s.word_index,"text":s.text})).collect::<Vec<_>>()).collect();
        json!({"trace":trace,"spacing":spacing,"refs":refs})
    }).collect();
    serde_json::to_writer(io::stdout(), &result).unwrap();
}
