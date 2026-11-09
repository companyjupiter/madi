//! Caption and editor-export semantics from the shipping Exporters/EditorCuts.
use super::{Line, Word, lowercase, whitespace, whitespace_and_newline};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct CaptionSpec {
    pub max_chars_per_line: i64,
    pub max_lines: i64,
    #[serde(rename = "maxCPS")]
    pub max_cps: f64,
    pub min_dur: f64,
    pub max_dur: f64,
    pub gap_break: f64,
    pub speaker_labels: Option<bool>,
}
impl Default for CaptionSpec {
    fn default() -> Self {
        Self {
            max_chars_per_line: 42,
            max_lines: 2,
            max_cps: 17.0,
            min_dur: 1.0,
            max_dur: 7.0,
            gap_break: 1.0,
            speaker_labels: None,
        }
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct Cue {
    pub start: f64,
    pub end: f64,
    pub lines: Vec<String>,
}
fn label(id: i64, names: &BTreeMap<i64, String>) -> String {
    if id == 255 {
        "미확인".into()
    } else {
        names
            .get(&id)
            .cloned()
            .unwrap_or_else(|| format!("Speaker {id}"))
    }
}
fn count(text: &str) -> usize {
    text.graphemes(true).count()
}
fn prefix(text: &str, n: usize) -> String {
    text.graphemes(true).take(n).collect()
}
fn space_tokens(text: &str) -> Vec<String> {
    let mut tokens = vec![String::new()];
    for grapheme in text.graphemes(true) {
        if grapheme == " " {
            if !tokens.last().unwrap().is_empty() {
                tokens.push(String::new());
            }
        } else {
            tokens.last_mut().unwrap().push_str(grapheme);
        }
    }
    tokens.retain(|token| !token.is_empty());
    tokens
}
fn words(line: &Line) -> Vec<Word> {
    if !line.is_edited() {
        return line
            .words
            .iter()
            .filter(|word| !word.text.trim_matches(whitespace).is_empty())
            .cloned()
            .collect();
    }
    let text = line.text();
    let mut tokens = vec![String::new()];
    for grapheme in text.graphemes(true) {
        if grapheme.chars().next().is_some_and(char::is_whitespace) {
            if !tokens.last().unwrap().is_empty() {
                tokens.push(String::new());
            }
        } else {
            tokens.last_mut().unwrap().push_str(grapheme);
        }
    }
    tokens.retain(|token| !token.is_empty());
    let start = line.start.max(0.0);
    let duration = (0.04 * tokens.len() as f64).max(line.end - start);
    let length = tokens.len() as f64;
    tokens
        .into_iter()
        .enumerate()
        .map(|(index, text)| {
            Word::new(
                start + duration * index as f64 / length,
                start + duration * (index + 1) as f64 / length,
                text,
                1.0,
            )
        })
        .collect()
}
fn join_words(words: &[Word]) -> String {
    let mut text = String::new();
    for word in words {
        if !text.is_empty()
            && !matches!(
                word.text.graphemes(true).next(),
                Some("," | "." | "!" | "?" | "…")
            )
        {
            text.push(' ');
        }
        text.push_str(word.text.trim_matches(whitespace));
    }
    text
}
fn wrap(text: &str, max: i64) -> Vec<String> {
    let mut lines = Vec::new();
    let mut current = String::new();
    for token in space_tokens(text) {
        if current.is_empty() {
            current = token;
        } else if (count(&current) + 1 + count(&token)) as i64 <= max {
            current.push(' ');
            current.push_str(&token);
        } else {
            lines.push(std::mem::replace(&mut current, token));
        }
    }
    if !current.is_empty() {
        lines.push(current);
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}
pub fn caption_cues(lines: &[Line], names: &BTreeMap<i64, String>, spec: &CaptionSpec) -> Vec<Cue> {
    let labelled = spec.speaker_labels.unwrap_or_else(|| {
        lines
            .iter()
            .map(|line| line.speaker)
            .collect::<BTreeSet<_>>()
            .len()
            > 1
    });
    let mut cues: Vec<Cue> = Vec::new();
    let mut previous = None;
    for line in lines {
        let words = words(line);
        if words.is_empty() {
            continue;
        }
        let heading = if labelled && Some(line.speaker) != previous {
            format!("{}: ", label(line.speaker, names))
        } else {
            String::new()
        };
        let mut pending: Vec<Word> = Vec::new();
        let mut first = true;
        let wrapped = |words: &[Word], first: bool| {
            wrap(
                &format!("{}{}", if first { &heading } else { "" }, join_words(words)),
                spec.max_chars_per_line,
            )
        };
        let flush = |pending: &mut Vec<Word>, first: &mut bool, cues: &mut Vec<Cue>| {
            if pending.is_empty() {
                return;
            }
            let lines = wrapped(pending, *first);
            let mut start = pending.first().unwrap().t0;
            let mut end = pending.last().unwrap().t1;
            if end < start {
                end = start;
            }
            let needed = lines.iter().map(|line| count(line)).sum::<usize>() as f64 / spec.max_cps;
            if end - start < spec.min_dur.max(needed) {
                end = start + spec.min_dur.max(needed).min(spec.max_dur);
            }
            if end - start > spec.max_dur {
                end = start + spec.max_dur;
            }
            if start < 0.0 {
                start = 0.0;
            }
            cues.push(Cue { start, end, lines });
            pending.clear();
            *first = false;
        };
        for word in words {
            if pending
                .last()
                .is_some_and(|last| word.t0 - last.t1 > spec.gap_break)
            {
                flush(&mut pending, &mut first, &mut cues);
            }
            let mut candidate = pending.clone();
            candidate.push(word.clone());
            if wrapped(&candidate, first).len() as i64 > spec.max_lines {
                flush(&mut pending, &mut first, &mut cues);
                pending = vec![word];
            } else {
                pending.push(word);
            }
        }
        flush(&mut pending, &mut first, &mut cues);
        previous = Some(line.speaker);
    }
    for index in 0..cues.len().saturating_sub(1) {
        if cues[index].end > cues[index + 1].start {
            cues[index].end = (cues[index].start + 0.04).max(cues[index + 1].start);
        }
    }
    cues
}
fn caption_time(time: f64, separator: char) -> String {
    let value = time as i64;
    format!(
        "{:02}:{:02}:{:02}{separator}{:03}",
        (value / 3600) as i32,
        ((value % 3600) / 60) as i32,
        (value % 60) as i32,
        ((time - time.floor()) * 1000.0) as i32
    )
}
pub fn srt(lines: &[Line], names: &BTreeMap<i64, String>, spec: &CaptionSpec) -> String {
    captions(lines, names, spec, false)
}
pub fn vtt(lines: &[Line], names: &BTreeMap<i64, String>, spec: &CaptionSpec) -> String {
    captions(lines, names, spec, true)
}
fn captions(
    lines: &[Line],
    names: &BTreeMap<i64, String>,
    spec: &CaptionSpec,
    vtt: bool,
) -> String {
    let mut output = if vtt {
        "WEBVTT\n\n".to_owned()
    } else {
        String::new()
    };
    let separator = if vtt { '.' } else { ',' };
    for (index, cue) in caption_cues(lines, names, spec).iter().enumerate() {
        output.push_str(&format!(
            "{}\n{} --> {}\n{}\n\n",
            index + 1,
            caption_time(cue.start, separator),
            caption_time(cue.end, separator),
            cue.lines.join("\n")
        ));
    }
    output
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "InputSettings")]
pub struct EditorSettings {
    pub enabled: bool,
    pub fillers: bool,
    pub silences: bool,
    pub chapters: bool,
    pub retakes: bool,
    pub highlights: bool,
    pub silence_min_gap: f64,
    pub silence_pad: f64,
    pub chapter_gap: f64,
    pub chapter_min_len: f64,
    pub retake_sim: f64,
    pub retake_min_tokens: i64,
    pub hl_min_words: i64,
    pub hl_min_pause: f64,
    pub hl_min_conf: f64,
}
#[derive(Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct InputSettings {
    enabled: Option<bool>,
    fillers: Option<bool>,
    silences: Option<bool>,
    chapters: Option<bool>,
    retakes: Option<bool>,
    highlights: Option<bool>,
    silence_min_gap: Option<f64>,
    silence_pad: Option<f64>,
    chapter_gap: Option<f64>,
    chapter_min_len: Option<f64>,
    retake_sim: Option<f64>,
    retake_min_tokens: Option<i64>,
    hl_min_words: Option<i64>,
    hl_min_pause: Option<f64>,
    hl_min_conf: Option<f64>,
}
impl From<InputSettings> for EditorSettings {
    fn from(s: InputSettings) -> Self {
        Self {
            enabled: s.enabled.unwrap_or(false),
            fillers: s.fillers.unwrap_or(true),
            silences: s.silences.unwrap_or(true),
            chapters: s.chapters.unwrap_or(true),
            retakes: s.retakes.unwrap_or(true),
            highlights: s.highlights.unwrap_or(true),
            silence_min_gap: s.silence_min_gap.unwrap_or(0.6),
            silence_pad: s.silence_pad.unwrap_or(0.1),
            chapter_gap: s.chapter_gap.unwrap_or(2.5),
            chapter_min_len: s.chapter_min_len.unwrap_or(20.0),
            retake_sim: s.retake_sim.unwrap_or(0.7),
            retake_min_tokens: s.retake_min_tokens.unwrap_or(3),
            hl_min_words: s.hl_min_words.unwrap_or(5),
            hl_min_pause: s.hl_min_pause.unwrap_or(1.0),
            hl_min_conf: s.hl_min_conf.unwrap_or(0.8),
        }
    }
}
impl Default for EditorSettings {
    fn default() -> Self {
        InputSettings::default().into()
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct Cut {
    pub start: f64,
    pub end: f64,
    pub kind: String,
    pub label: String,
}
impl Cut {
    fn duration(&self) -> f64 {
        (self.end - self.start).max(0.0)
    }
}
fn normalize(text: &str) -> String {
    lowercase(
        text.trim_matches(whitespace_and_newline)
            .trim_matches(|c| ",.!?…\"'`’”“()-—· ".contains(c)),
    )
    .nfc()
    .collect()
}
pub fn fillers(lines: &[Line]) -> Vec<Cut> {
    const WORDS: &[&str] = &[
        "um", "umm", "ummm", "uhm", "uh", "uhh", "uhhh", "er", "err", "erm", "hmm", "hm", "hmmm",
        "mm", "mmm", "mhm", "uh-huh", "huh", "음", "으음", "음음", "어", "어어", "엄", "에", "흠",
    ];
    lines
        .iter()
        .flat_map(|line| &line.words)
        .filter(|word| WORDS.contains(&normalize(&word.text).as_str()))
        .map(|word| Cut {
            start: word.t0,
            end: word.t1,
            kind: "filler".into(),
            label: word.text.trim_matches(whitespace).into(),
        })
        .collect()
}
pub fn silences(lines: &[Line], gap: f64, pad: f64) -> Vec<Cut> {
    let mut words: Vec<_> = lines.iter().flat_map(|line| &line.words).collect();
    words.sort_by(|a, b| a.t0.partial_cmp(&b.t0).unwrap_or(std::cmp::Ordering::Equal));
    words
        .windows(2)
        .filter_map(|pair| {
            let (previous, next) = (pair[0], pair[1]);
            let start = previous.t1 + pad;
            let end = next.t0 - pad;
            (next.t0 - previous.t1 > gap && end > start).then(|| Cut {
                start,
                end,
                kind: "silence".into(),
                label: String::new(),
            })
        })
        .collect()
}
pub fn tighten(lines: &[Line], settings: &EditorSettings) -> Vec<Cut> {
    let mut all = if settings.fillers {
        fillers(lines)
    } else {
        Vec::new()
    };
    if settings.silences {
        all.extend(silences(
            lines,
            settings.silence_min_gap,
            settings.silence_pad,
        ));
    }
    all.sort_by(|a, b| {
        a.start
            .partial_cmp(&b.start)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut merged: Vec<Cut> = Vec::new();
    for range in all {
        if let Some(last) = merged.last_mut()
            && range.start <= last.end
        {
            last.end = last.end.max(range.end);
            if last.kind != range.kind {
                last.kind = "mixed".into();
                last.label.clear();
            }
        } else {
            merged.push(range);
        }
    }
    merged
}
#[derive(Serialize)]
pub struct Chapter {
    pub start: f64,
    pub title: String,
}
pub fn chapters(lines: &[Line], gap: f64, min_len: f64) -> Vec<Chapter> {
    fn title(line: &Line) -> String {
        let text = prefix(
            &space_tokens(&line.text())
                .into_iter()
                .take(7)
                .collect::<Vec<_>>()
                .join(" "),
            40,
        );
        let trimmed = text.trim_matches(whitespace);
        if trimmed.is_empty() {
            "챕터".into()
        } else {
            trimmed.into()
        }
    }
    let Some(first) = lines.first() else {
        return Vec::new();
    };
    let mut result = vec![Chapter {
        start: 0.0,
        title: title(first),
    }];
    let mut last_end = first.end;
    for line in &lines[1..] {
        if line.start - last_end > gap && line.start - result.last().unwrap().start > min_len {
            result.push(Chapter {
                start: line.start,
                title: title(line),
            });
        }
        last_end = last_end.max(line.end);
    }
    result
}
fn average(line: &Line) -> f64 {
    if line.words.is_empty() {
        0.0
    } else {
        line.words
            .iter()
            .map(|word| word.conf)
            .fold(0.0, |sum, value| sum + value)
            / line.words.len() as f64
    }
}
fn jaccard(a: &Line, b: &Line) -> f64 {
    let tokens = |line: &Line| {
        line.words
            .iter()
            .map(|word| normalize(&word.text))
            .filter(|text| !text.is_empty())
            .collect::<BTreeSet<_>>()
    };
    let a = tokens(a);
    let b = tokens(b);
    if a.is_empty() || b.is_empty() {
        0.0
    } else {
        a.intersection(&b).count() as f64 / a.union(&b).count() as f64
    }
}
#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub struct Retake {
    pub keep_start: f64,
    pub keep_text: String,
    pub drops: Vec<Cut>,
}
pub fn retakes(lines: &[Line], threshold: f64, min_tokens: i64) -> Vec<Retake> {
    let mut result = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let mut j = i;
        while j + 1 < lines.len()
            && lines[j].words.len() as i64 >= min_tokens
            && lines[j + 1].words.len() as i64 >= min_tokens
            && jaccard(&lines[j], &lines[j + 1]) >= threshold
        {
            j += 1;
        }
        if j > i {
            let run = &lines[i..=j];
            let mut keep = &run[0];
            for line in &run[1..] {
                if average(keep) < average(line) {
                    keep = line;
                }
            }
            let drops = run
                .iter()
                .filter(|line| line.id != keep.id)
                .map(|line| Cut {
                    start: line.start,
                    end: line.end,
                    kind: "retake".into(),
                    label: prefix(&line.text(), 40),
                })
                .collect();
            result.push(Retake {
                keep_start: keep.start,
                keep_text: prefix(&keep.text(), 40),
                drops,
            });
            i = j + 1;
        } else {
            i += 1;
        }
    }
    result
}
#[derive(Serialize)]
pub struct Highlight {
    pub start: f64,
    pub end: f64,
    pub text: String,
    pub score: f64,
}
pub fn highlights(lines: &[Line], min_words: i64, min_pause: f64, min_conf: f64) -> Vec<Highlight> {
    let mut result = Vec::new();
    let mut previous: Option<f64> = None;
    for line in lines {
        let pause = previous.map_or(0.0, |end| line.start - end);
        previous = Some(previous.unwrap_or(line.end).max(line.end));
        let conf = average(line);
        if line.words.len() as i64 >= min_words && conf >= min_conf && pause >= min_pause {
            result.push(Highlight {
                start: line.start,
                end: line.end,
                text: prefix(&line.text(), 60),
                score: pause * conf,
            });
        }
    }
    result.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    result
}
pub fn json(lines: &[Line], names: &BTreeMap<i64, String>, settings: &EditorSettings) -> Value {
    let segments:Vec<_>=lines.iter().map(|line|json!({"speaker":line.speaker,"name":label(line.speaker,names),"start":line.start,"end":line.end,"text":line.text(),"translations":line.translations,"overlap_speakers":line.overlap_speakers,"words":line.words.iter().map(|word|json!({"text":word.text,"t0":word.t0,"t1":word.t1,"conf":word.conf})).collect::<Vec<_>>()})).collect();
    let mut times = BTreeMap::new();
    for line in lines {
        *times.entry(line.speaker).or_insert(0.0) += (line.end - line.start).max(0.0);
    }
    let mut speakers: Vec<_> = times.into_iter().collect();
    speakers.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    let speakers: Vec<_> = speakers
        .into_iter()
        .map(|(id, time)| json!({"speaker":id,"name":label(id,names),"talk_seconds":time}))
        .collect();
    let mut root = json!({"segments":segments,"speakers":speakers});
    if settings.fillers {
        let cuts = fillers(lines);
        root["filler_seconds"] = json!(
            cuts.iter()
                .map(Cut::duration)
                .fold(0.0, |sum, value| sum + value)
        );
        root["fillers"] = json!(
            cuts.iter()
                .map(|cut| json!({"start":cut.start,"end":cut.end,"text":cut.label}))
                .collect::<Vec<_>>()
        );
    }
    if settings.silences {
        let cuts = silences(lines, settings.silence_min_gap, settings.silence_pad);
        root["silence_seconds"] = json!(
            cuts.iter()
                .map(Cut::duration)
                .fold(0.0, |sum, value| sum + value)
        );
        root["silences"] = json!(
            cuts.iter()
                .map(|cut| json!({"start":cut.start,"end":cut.end}))
                .collect::<Vec<_>>()
        );
    }
    let cuts = tighten(lines, settings);
    root["tighten"] = json!({"cuts":cuts.len(),"total_seconds":cuts.iter().map(Cut::duration).fold(0.0,|sum,value|sum+value)});
    if settings.chapters {
        root["chapters"] = json!(chapters(
            lines,
            settings.chapter_gap,
            settings.chapter_min_len
        ));
    }
    if settings.retakes {
        root["retakes"]=json!(retakes(lines,settings.retake_sim,settings.retake_min_tokens).iter().map(|group|json!({"keep_start":group.keep_start,"keep_text":group.keep_text,"drops":group.drops.iter().map(|cut|json!({"start":cut.start,"end":cut.end})).collect::<Vec<_>>()})).collect::<Vec<_>>());
    }
    if settings.highlights {
        root["highlights"] = json!(highlights(
            lines,
            settings.hl_min_words,
            settings.hl_min_pause,
            settings.hl_min_conf
        ));
    }
    root
}
