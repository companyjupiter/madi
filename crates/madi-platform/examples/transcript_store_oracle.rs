use madi_core::transcript::{Features, Line, TranscriptStore, Word, text_revision};
use madi_protocol::transcribe::{Event, SpeakerLabel};
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::Read;

#[derive(Deserialize)]
struct Case {
    features: InputFeatures,
    steps: Vec<Value>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputFeatures {
    join: bool,
    ledger: bool,
    turn_head: bool,
    island: bool,
    weak: f64,
    min_seconds: f64,
}
fn bits(value: f64) -> String {
    format!("{:016x}", value.to_bits())
}
fn hex(text: &str) -> String {
    text.as_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
fn words(words: &[Word]) -> Vec<String> {
    words
        .iter()
        .map(|word| {
            format!(
                "{}:{}:{}:{}:{}",
                word.id,
                bits(word.t0),
                bits(word.t1),
                bits(word.conf),
                hex(&word.text)
            )
        })
        .collect()
}
fn lines(lines: &[Line]) -> Vec<Value> {
    lines.iter().map(|l| json!({
        "id":l.id,"speaker":l.speaker,"start":bits(l.start),"end":bits(l.end),"margin":bits(l.speaker_margin),
        "words":words(&l.words),"text":hex(&l.text()),"joined":hex(&l.joined_text()),"editedText":l.edited_text.as_deref().map(hex),"edited":l.is_edited(),
        "overlaps":l.overlap_speakers,"translations":l.translations.iter().map(|(k,v)|(k,hex(v))).collect::<std::collections::BTreeMap<_,_>>(),
        "stale":l.stale_translations.iter().map(|(k,v)|(k,hex(v))).collect::<std::collections::BTreeMap<_,_>>(),
        "editedTranslations":l.edited_translations,"suppressed":l.suppressed_translations,"revision":text_revision(&l.text()).to_string(),
        "statuses":[l.status(&["en".into(),"ja".into()],true,true),l.status(&["en".into(),"ja".into()],false,true),l.status(&[],false,true),l.status(&["en".into()],false,false)]
    })).collect()
}
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let mut results = Vec::new();
    for c in cases {
        let mut store = TranscriptStore::new(Features {
            join_same_speaker_neighbors: c.features.join,
            settled_ledger: c.features.ledger,
            turn_head_adoption: c.features.turn_head,
            speaker_island_absorption: c.features.island,
            weak_label_continuation: c.features.weak,
            min_seconds_to_number: c.features.min_seconds,
        });
        let invalid = serde_json::from_value::<Word>(
            json!({"id":"ffffffff-ffff-ffff-ffff-ffffffffffff","t0":0,"t1":0,"conf":1,"text":""}),
        )
        .unwrap()
        .id;
        let mut saved_id = invalid;
        let mut saved_revision = 0;
        let mut archive = Vec::new();
        let mut states = Vec::new();
        for step in c.steps {
            let index = step["index"].as_u64().unwrap_or(0) as usize;
            let id = if step["saved"].as_bool() == Some(true) {
                saved_id
            } else {
                store.lines().get(index).map(|l| l.id).unwrap_or(invalid)
            };
            let revision = match step["revision"].as_str() {
                Some("current") => store.source_revision(id),
                Some("saved") => Some(saved_revision),
                Some("bad") => Some(0),
                _ => None,
            };
            let mut result = Value::Null;
            let op = step["op"].as_str().unwrap();
            match op {
                "word" => store.ingest_word(serde_json::from_value(step["word"].clone()).unwrap()),
                "break" => store.ingest(&Event::WordSectionBegin),
                "speaker" | "fix" | "overlap" => {
                    let l = &step["label"];
                    let label = SpeakerLabel {
                        time: l["time"].as_f64().unwrap(),
                        id: l["id"].as_i64().unwrap(),
                        duration: l["duration"].as_f64().unwrap(),
                        margin: l["margin"].as_f64().unwrap(),
                    };
                    store.ingest(&match op {
                        "speaker" => Event::Speaker(label),
                        "fix" => Event::SpeakerFix(label),
                        _ => Event::SpeakerOverlap(label),
                    });
                }
                "overlapReset" => store.ingest(&Event::SpeakerOverlapReset),
                "flushFix" => store.flush_pending_speaker_fix_rebuild(),
                "render" => {
                    if store.render_pending {
                        store.flush_render();
                    }
                }
                "finish" => store.finalize(),
                "reset" => store.reset(),
                "broken" => store.mark_diar_namespace_broken(),
                "remember" => {
                    saved_id = id;
                    saved_revision = store.source_revision(id).unwrap_or(0);
                }
                "archive" => archive = store.lines().to_vec(),
                "load" => store.load(archive.clone()),
                "translate" => {
                    result = json!(store.set_translation(
                        id,
                        step["lang"].as_str().unwrap().into(),
                        step["text"].as_str().unwrap(),
                        revision,
                        step["userEdited"].as_bool().unwrap_or(false)
                    ))
                }
                "suppress" => {
                    result = json!(store.suppress_translation(
                        id,
                        step["lang"].as_str().unwrap().into(),
                        revision
                    ))
                }
                "prune" => {
                    result = json!(store.prune_translations(
                        id,
                        &serde_json::from_value(step["targets"].clone()).unwrap(),
                        revision.unwrap_or(0)
                    ))
                }
                "edit" => {
                    result = json!(store.edit_line(id, step["text"].as_str().unwrap(), revision))
                }
                "editWord" => {
                    result = json!(store.edit_word(
                        id,
                        step["wordIndex"].as_i64().unwrap() as usize,
                        step["text"].as_str().unwrap()
                    ))
                }
                "merge" => store.merge_speaker(
                    step["from"].as_i64().unwrap(),
                    step["into"].as_i64().unwrap(),
                ),
                "relabel" => store.relabel_speaker(id, step["into"].as_i64().unwrap()),
                "revert" => store.revert_speaker_corrections(),
                "join" => store.join_same_speaker_neighbors(),
                "snapshot" => (),
                _ => panic!("unknown transcript store operation"),
            }
            if step["inspect"].as_bool().unwrap_or(true) {
                states.push(json!({"lines":lines(store.lines()),"display":lines(store.display_lines()),"lastDisplayID":store.display_lines().last().map(|l|l.id),
                "displayRevision":store.display_revision.to_string(),"renderPending":store.render_pending,"fixPending":store.speaker_fix_pending,"numbers":store.speaker_numbers.numbers,
                "held":words(store.held_word().map(std::slice::from_ref).unwrap_or(&[])),"end":bits(store.committed_end()),
                "committedSince":words(store.committed_words(0.7)),"displayedSince":words(&store.displayed_words(0.7)),"corrections":store.has_speaker_corrections(),
                "joins":store.same_speaker_joins,"fixRebuilds":store.speaker_fix_rebuilds,"islands":store.island_absorptions,"weak":store.weak_label_continuations,"result":result}));
            }
        }
        results.push(states);
    }
    println!("{}", serde_json::to_string(&results).unwrap());
}
