//! EVENTS_FILE contract. Unknown event names remain observable to consumers.
//! Numeric compatibility is verified for the engine's finite, bounded fields;
//! Foundation's arbitrary-precision NSNumber coercions are not reproduced.
use crate::translate::foundation_whitespace_and_newline;
use serde::de::{Deserializer, MapAccess, Visitor};
use serde_json::{Map, Value};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DuplicateKeys {
    #[default]
    KeepFirst,
    KeepLast,
}

// The canonical Foundation runtime accepts trailing commas and keeps the first duplicate key.
// Do not rewrite anything inside strings or allow other JSON5 extensions.
fn without_trailing_commas(line: &str) -> String {
    let bytes = line.as_bytes();
    let mut result = Vec::with_capacity(bytes.len());
    let (mut quoted, mut escaped) = (false, false);
    for (index, &byte) in bytes.iter().enumerate() {
        if quoted {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                quoted = false;
            }
        } else if byte == b'"' {
            quoted = true;
        } else if byte == b','
            && bytes[..index]
                .iter()
                .rev()
                .find(|&&b| !matches!(b, b' ' | b'\t' | b'\r' | b'\n'))
                .is_some_and(|b| !matches!(b, b'{' | b'[' | b','))
            && bytes[index + 1..]
                .iter()
                .find(|&&b| !matches!(b, b' ' | b'\t' | b'\r' | b'\n'))
                .is_some_and(|b| matches!(b, b'}' | b']'))
        {
            continue;
        }
        result.push(byte);
    }
    // Only ASCII delimiters are removed from an already valid UTF-8 string.
    String::from_utf8(result).expect("removing ASCII preserves UTF-8")
}

impl Fields {
    fn deserialize_object<'de, D: Deserializer<'de>>(
        deserializer: D,
        duplicates: DuplicateKeys,
    ) -> Result<Self, D::Error> {
        struct ObjectVisitor(DuplicateKeys);
        impl<'de> Visitor<'de> for ObjectVisitor {
            type Value = Fields;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("an event object")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Fields, A::Error> {
                let mut values = Map::new();
                while let Some((key, raw)) =
                    map.next_entry::<String, Box<serde_json::value::RawValue>>()?
                {
                    let value: Value =
                        serde_json::from_str(raw.get()).map_err(serde::de::Error::custom)?;
                    if !finite_numbers(&value) {
                        return Err(serde::de::Error::custom("non-finite JSON number"));
                    }
                    if self.0 == DuplicateKeys::KeepFirst {
                        values.entry(key).or_insert(value);
                    } else {
                        values.insert(key, value);
                    }
                }
                Ok(Fields(values))
            }
        }
        deserializer.deserialize_map(ObjectVisitor(duplicates))
    }
}

fn finite_numbers(value: &Value) -> bool {
    match value {
        Value::Number(n) => n.as_f64().is_some_and(f64::is_finite),
        Value::Array(values) => values.iter().all(finite_numbers),
        Value::Object(values) => values.values().all(finite_numbers),
        _ => true,
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Segment {
    pub index: i64,
    pub t0: f64,
    pub t1: f64,
    pub avg_logprob: f64,
    pub fallback: String,
    pub tokens_per_second: f64,
    pub encoder_ms: f64,
    pub decoder_ms: f64,
    pub passes: i64,
    pub dropped: bool,
    pub text: String,
    pub bias_hits: Vec<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Meta {
        model: String,
        language: i64,
        sample_rate: i64,
        version: i64,
    },
    Ready,
    Partial {
        t0: f64,
        text: String,
    },
    Word {
        t0: f64,
        t1: f64,
        confidence: f64,
        speaker: i64,
        text: String,
    },
    Segment(Segment),
    SpeakerSegment {
        t0: f64,
        speaker: i64,
        text: String,
    },
    Diarization {
        speakers: i64,
        silhouette: f64,
        separation: f64,
        tau: f64,
        segments: i64,
    },
    SegmentEnd,
    FlushEnd,
    Unknown(String),
}

struct Fields(Map<String, Value>);
impl Fields {
    fn number(&self, key: &str) -> Option<f64> {
        match self.0.get(key)? {
            Value::Bool(value) => Some(u8::from(*value) as f64),
            Value::Number(value) => {
                let raw = value.to_string();
                // Foundation stores JSON integer -0 as integer 0.
                raw.parse::<i64>()
                    .map(|n| n as f64)
                    .ok()
                    .or_else(|| value.as_f64())
            }
            _ => None,
        }
    }
    fn double(&self, key: &str, default: f64) -> f64 {
        self.number(key).unwrap_or(default)
    }
    fn integer(&self, key: &str, default: i64) -> i64 {
        if let Some(Value::Number(value)) = self.0.get(key) {
            if let Some(n) = value.as_i64() {
                return n;
            }
            if let Some(n) = value.as_u64() {
                return n as i64;
            }
        }
        self.number(key).map(|n| n as i64).unwrap_or(default)
    }
    fn string(&self, key: &str, default: &str) -> String {
        self.0
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or(default)
            .into()
    }
    fn boolean(&self, key: &str) -> bool {
        // NSNumber bridges 0/1 to Bool; other numeric values fail the cast.
        self.number(key) == Some(1.0)
    }
    fn strings(&self, key: &str) -> Vec<String> {
        self.0
            .get(key)
            .and_then(Value::as_array)
            .and_then(|values| {
                values
                    .iter()
                    .map(|v| v.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
    }
}

pub fn decode(raw: &str) -> Option<Event> {
    decode_with_duplicate_policy(raw, DuplicateKeys::KeepFirst)
}
pub fn decode_with_duplicate_policy(raw: &str, duplicates: DuplicateKeys) -> Option<Event> {
    let line = raw.trim_matches(foundation_whitespace_and_newline);
    let normalized = without_trailing_commas(line);
    let mut deserializer = serde_json::Deserializer::from_str(&normalized);
    let fields = Fields::deserialize_object(&mut deserializer, duplicates).ok()?;
    deserializer.end().ok()?;
    let kind = fields.0.get("t")?.as_str()?;
    let d = |key| fields.double(key, 0.0);
    let i = |key| fields.integer(key, 0);
    let text = || fields.string("text", "");
    Some(match kind {
        "meta" => Event::Meta {
            model: fields.string("model", ""),
            language: i("lang"),
            sample_rate: i("sr"),
            version: fields.integer("v", 1),
        },
        "ready" => Event::Ready,
        "partial" => Event::Partial {
            t0: d("t0"),
            text: text(),
        },
        "word" => Event::Word {
            t0: d("t0"),
            t1: d("t1"),
            confidence: fields.double("conf", 1.0),
            speaker: fields.integer("spk", -1),
            text: text(),
        },
        "spk_seg" => Event::SpeakerSegment {
            t0: d("t0"),
            speaker: fields.integer("spk", -1),
            text: text(),
        },
        "seg" => Event::Segment(Segment {
            index: i("idx"),
            t0: d("t0"),
            t1: d("t1"),
            avg_logprob: d("avg_logprob"),
            fallback: fields.string("fallback", "none"),
            tokens_per_second: d("tok_s"),
            encoder_ms: d("enc_ms"),
            decoder_ms: d("dec_ms"),
            passes: i("passes"),
            dropped: fields.boolean("dropped"),
            text: text(),
            bias_hits: fields.strings("bias_hits"),
        }),
        "diar" => Event::Diarization {
            speakers: i("speakers"),
            silhouette: d("silhouette"),
            separation: d("sep"),
            tau: d("tau"),
            segments: i("segments"),
        },
        "seg_end" => Event::SegmentEnd,
        "flush_end" => Event::FlushEnd,
        unknown => Event::Unknown(unknown.into()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn correction_evidence_and_all_or_nothing_bias_hits() {
        let raw = r#"{"t":"seg","idx":7,"t0":10,"t1":14,"avg_logprob":-1.31,"fallback":"logprob","tok_s":42,"enc_ms":80,"dec_ms":300,"passes":2,"dropped":1,"text":"김 부장","bias_hits":["김",null]}"#;
        let Some(Event::Segment(segment)) = decode(raw) else {
            panic!("missing segment")
        };
        assert_eq!(segment.index, 7);
        assert_eq!(segment.avg_logprob, -1.31);
        assert_eq!(segment.fallback, "logprob");
        assert_eq!(segment.passes, 2);
        assert!(segment.dropped);
        assert_eq!(segment.text, "김 부장");
        assert!(segment.bias_hits.is_empty());
    }
    #[test]
    fn malformed_lines_and_future_events_do_not_stop_the_stream() {
        for raw in ["", "not json", "[]", "null", r#"{"t":1}"#] {
            assert_eq!(decode(raw), None);
        }
        assert_eq!(
            decode(r#"{"t":"future","extra":42}"#),
            Some(Event::Unknown("future".into()))
        );
        assert_eq!(
            decode(r#"{"t":"word"}"#),
            Some(Event::Word {
                t0: 0.0,
                t1: 0.0,
                confidence: 1.0,
                speaker: -1,
                text: String::new()
            })
        );
    }
}
