//! Personal glossary storage and mutations from GlossaryStore.swift.
//! Matching, edit learning and persistence are separate integration boundaries.
use serde::{Deserialize, Deserializer, Serialize};
use std::{cmp::Ordering, collections::BTreeMap};
use unicode_normalization::UnicodeNormalization;

// Swift dictionaries compare String keys with canonical Unicode equivalence,
// retaining the originally inserted spelling of the key.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(transparent)]
struct Key(String);
impl PartialEq for Key {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for Key {}
impl PartialOrd for Key {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Key {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.nfc().cmp(other.0.nfc())
    }
}

fn optional_integer<'de, D: Deserializer<'de>>(decoder: D) -> Result<Option<i64>, D::Error> {
    let value = Option::<serde_json::Number>::deserialize(decoder)?;
    value
        .map(|number| {
            if let Some(value) = number.as_i64() {
                return Ok(value);
            }
            // Preserve an overflowing integer literal instead of rounding it into
            // the Int64 range through f64 (notably Int64.min - 1).
            if !number.to_string().contains(['.', 'e', 'E']) {
                return Err(serde::de::Error::custom("invalid integer"));
            }
            let value = number
                .as_f64()
                .ok_or_else(|| serde::de::Error::custom("invalid integer"))?;
            // Swift JSONDecoder excludes both Int64 endpoints when the JSON number
            // takes its floating-point conversion path (an integer literal differs).
            if value.fract() == 0.0 && value > i64::MIN as f64 && value < -(i64::MIN as f64) {
                Ok(value as i64)
            } else {
                Err(serde::de::Error::custom("invalid integer"))
            }
        })
        .transpose()
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Entry {
    pub wrong: String,
    pub right: String,
    pub hits: i64,
}
impl<'de> Deserialize<'de> for Entry {
    fn deserialize<D: Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Saved {
            wrong: Option<String>,
            right: Option<String>,
            #[serde(default, deserialize_with = "optional_integer")]
            hits: Option<i64>,
        }
        let saved = Saved::deserialize(decoder)?;
        Ok(Self {
            wrong: saved.wrong.unwrap_or_default(),
            right: saved.right.unwrap_or_default(),
            hits: saved.hits.unwrap_or(1),
        })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Glossary {
    schema_version: i64,
    pub enabled: bool,
    pub min_hits: i64,
    entries: BTreeMap<Key, Entry>,
}
impl Default for Glossary {
    fn default() -> Self {
        Self {
            schema_version: 2,
            enabled: false,
            min_hits: 2,
            entries: BTreeMap::new(),
        }
    }
}
impl<'de> Deserialize<'de> for Glossary {
    fn deserialize<D: Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Saved {
            #[serde(default, deserialize_with = "optional_integer")]
            schema_version: Option<i64>,
            enabled: Option<bool>,
            #[serde(default, deserialize_with = "optional_integer")]
            min_hits: Option<i64>,
            entries: Option<BTreeMap<Key, Entry>>,
        }
        let saved = Saved::deserialize(decoder)?;
        Ok(Self {
            schema_version: 2,
            enabled: saved.enabled.unwrap_or(false),
            min_hits: saved
                .min_hits
                .unwrap_or(1)
                .max(if saved.schema_version.unwrap_or(1) < 2 {
                    2
                } else {
                    1
                }),
            entries: saved.entries.unwrap_or_default(),
        })
    }
}
impl Glossary {
    pub fn entries(&self) -> impl Iterator<Item = &Entry> {
        self.entries.values()
    }
    pub fn learn(&mut self, wrong: &str, right: &str) -> Result<(), &'static str> {
        if wrong.is_empty() || right.is_empty() || wrong.nfc().eq(right.nfc()) {
            return Ok(());
        }
        if let Some(entry) = self.entries.get_mut(&Key(wrong.into())) {
            // A malformed legacy count must not panic or wrap when learning.
            let hits = entry
                .hits
                .checked_add(1)
                .ok_or("glossary hit count overflow")?;
            if !entry.right.nfc().eq(right.nfc()) {
                entry.right = right.into();
            }
            entry.hits = hits;
        } else {
            self.entries.insert(
                Key(wrong.into()),
                Entry {
                    wrong: wrong.into(),
                    right: right.into(),
                    hits: 1,
                },
            );
        }
        Ok(())
    }
    pub fn active_entries(&self) -> Vec<&Entry> {
        let mut entries: Vec<_> = self
            .entries
            .values()
            .filter(|entry| entry.hits >= self.min_hits.max(1))
            .collect();
        entries.sort_by(|a, b| a.wrong.nfc().cmp(b.wrong.nfc()));
        entries
    }
    pub fn display_entries(&self) -> Vec<&Entry> {
        let mut entries: Vec<_> = self.entries.values().collect();
        entries.sort_by(|a, b| {
            b.hits
                .cmp(&a.hits)
                .then_with(|| a.wrong.nfc().cmp(b.wrong.nfc()))
        });
        entries
    }
    pub fn exact(&self, wrong: &str) -> Option<&Entry> {
        self.entries
            .get(&Key(wrong.into()))
            .filter(|entry| entry.hits >= self.min_hits.max(1))
    }
    pub fn clear(&mut self) {
        self.entries.clear();
    }
    pub fn forget(&mut self, wrong: &str) {
        self.entries.remove(&Key(wrong.into()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exhausted_legacy_hit_counter_rejects_learning_without_replacing_the_rule() {
        let mut glossary: Glossary = serde_json::from_str(
            r#"{"schemaVersion":2,"entries":{"old":{"wrong":"old","right":"saved","hits":9223372036854775807}}}"#,
        ).unwrap();
        let before = glossary.clone();
        assert!(glossary.learn("old", "replacement").is_err());
        assert_eq!(glossary, before);
    }
}
