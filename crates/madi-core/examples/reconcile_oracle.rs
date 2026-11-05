use madi_core::reconcile::{self, Replies};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{self, Read},
};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    lines: Vec<(i64, String)>,
    names: BTreeMap<i64, String>,
    uncertain: BTreeSet<usize>,
    risk: BTreeSet<usize>,
    numbered: String,
    budget: i64,
    reply: String,
    speakers: BTreeSet<i64>,
    line_count: i64,
    max_corrections: i64,
    allowed: Option<BTreeSet<usize>>,
    language: String,
    session_token: Option<i64>,
    replies: Vec<Option<String>>,
    wav: Vec<u8>,
    crop_start: f64,
    crop_end: f64,
    crop_pad: f64,
    output: String,
}
fn main() {
    let mut bytes = String::new();
    io::stdin().read_to_string(&mut bytes).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&bytes).unwrap();
    let results:Vec<Value>=cases.into_iter().map(|c|{
  let prompt=reconcile::prompt_input(c.lines.iter().map(|(s,t)|(*s,t.as_str())),|s|c.names.get(&s).cloned().unwrap_or_else(||format!("화자 {s}")),&c.uncertain,&c.risk);
  let plan=reconcile::parse(&c.reply,&c.speakers,c.line_count,c.max_corrections,c.allowed.as_ref());
  let mut replies=Replies::new(c.replies.len());
  let completed:Vec<_>=c.replies.iter().map(|r|replies.complete(r.as_deref())).collect();
  json!({"prompt":prompt,"batches":reconcile::prompt_batches(&c.numbered,c.budget),"instruction":reconcile::INSTRUCTION,
   "plan":plan,"empty":plan.is_empty(),"languageToken":reconcile::language_token(&c.language),"languageAllowed":reconcile::language_flag_allowed(&c.language,c.session_token),"completions":completed,"transcription":reconcile::audio::parse_transcription(&c.output),"crop":match reconcile::audio::crop(&c.wav,c.crop_start,c.crop_end,c.crop_pad){Ok(bytes)=>json!({"bytes":bytes}),Err(e)=>json!({"error":match e{reconcile::audio::CropError::Unsupported=>1,reconcile::audio::CropError::Empty=>2,reconcile::audio::CropError::InvalidRange=>3}})}})
 }).collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
