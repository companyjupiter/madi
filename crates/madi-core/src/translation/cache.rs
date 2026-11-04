//! Exact FAQ lookup and session-local interim reuse. No inference or fuzzy match.
use crate::transcript::{lowercase, whitespace_and_newline};
use regex::Regex;
use std::{
    collections::{BTreeMap, VecDeque},
    sync::OnceLock,
};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

pub type Entry = BTreeMap<String, String>;
/// Portable Foundation baseline (macOS 27.2). Native macOS supplies its own
/// CharacterSet classifier so the installed OS follows the original app.
pub fn faq_symbol(ch: char) -> bool {
    static STRIP: OnceLock<Regex> = OnceLock::new();
    let mut bytes = [0; 4];
    STRIP
        .get_or_init(|| Regex::new(r"[\p{P}\p{S}]").unwrap())
        .is_match(ch.encode_utf8(&mut bytes))
        || matches!(ch as u32,
            0x20c1 | 0x2b96 | 0xfbc3..=0xfbd2 | 0xfd90..=0xfd91 | 0xfdc8..=0xfdce |
            0x10ed0..=0x10ed8 | 0x1ccfa..=0x1ccfc | 0x1ceba..=0x1ced0 | 0x1cee0..=0x1cef0 |
            0x1f6d8 | 0x1f777..=0x1f77a | 0x1f8d0..=0x1f8d8 | 0x1fa54..=0x1fa57 |
            0x1fa8a | 0x1fa8e | 0x1fac8 | 0x1facd | 0x1faea | 0x1faef | 0x1fbfa)
}
pub fn faq_normalize(text: &str) -> Option<String> {
    faq_normalize_with(text, faq_symbol)
}
pub fn faq_normalize_with(text: &str, symbol: fn(char) -> bool) -> Option<String> {
    let lower = lowercase(text);
    let out: String = lower
        .chars()
        .filter(|c| !whitespace_and_newline(*c) && !symbol(*c))
        .collect();
    (out.graphemes(true).count() >= 4).then_some(out)
}
fn faq_key(text: &str, symbol: fn(char) -> bool) -> Option<String> {
    faq_normalize_with(text, symbol).map(|s| s.nfc().collect())
}

pub struct Faq {
    entries: Vec<Entry>,
    index: BTreeMap<String, usize>,
    symbol: fn(char) -> bool,
}
impl Default for Faq {
    fn default() -> Self {
        Self::new(Vec::new())
    }
}
impl Faq {
    pub fn new(entries: Vec<Entry>) -> Self {
        Self::with_classifier(entries, faq_symbol)
    }
    pub fn with_classifier(entries: Vec<Entry>, symbol: fn(char) -> bool) -> Self {
        let mut index = BTreeMap::new();
        for (i, entry) in entries.iter().enumerate() {
            for text in entry.values() {
                if let Some(key) = faq_key(text, symbol) {
                    index.insert(key, i);
                }
            }
        }
        Self {
            entries,
            index,
            symbol,
        }
    }
    pub fn starter_entries() -> Vec<Entry> {
        serde_json::from_str(include_str!("faq_starter.json"))
            .expect("bundled native FAQ starter pack")
    }
    pub fn starter() -> Self {
        Self::new(Self::starter_entries())
    }
    pub fn lookup(&self, text: &str) -> Option<Entry> {
        let key = faq_key(text, self.symbol)?;
        let entry = &self.entries[*self.index.get(&key)?];
        let source = entry
            .iter()
            .find(|(_, text)| faq_key(text, self.symbol).as_ref() == Some(&key))?
            .0;
        let others: Entry = entry
            .iter()
            .filter(|(lang, _)| *lang != source)
            .map(|(lang, text)| (lang.clone(), text.clone()))
            .collect();
        (!others.is_empty()).then_some(others)
    }
}

pub struct Interim {
    capacity: usize,
    order: VecDeque<String>,
    entries: BTreeMap<String, Entry>,
}
impl Default for Interim {
    fn default() -> Self {
        Self::new(15)
    }
}
impl Interim {
    pub fn new(capacity: i64) -> Self {
        Self {
            capacity: capacity.max(1) as usize,
            order: VecDeque::new(),
            entries: BTreeMap::new(),
        }
    }
    pub fn normalize(text: &str) -> Option<String> {
        let source = super::client::one_line(text);
        (!source.is_empty()).then_some(source)
    }
    fn key(text: &str) -> Option<String> {
        Self::normalize(text).map(|s| s.nfc().collect())
    }
    fn touch(&mut self, key: &str) {
        self.order.retain(|s| s != key);
        self.order.push_back(key.into());
    }
    pub fn put(&mut self, source: &str, translations: Entry) {
        if translations.is_empty() {
            return;
        }
        let Some(key) = Self::key(source) else {
            return;
        };
        self.touch(&key);
        self.entries.entry(key).or_default().extend(translations);
        while self.order.len() > self.capacity {
            if let Some(oldest) = self.order.pop_front() {
                self.entries.remove(&oldest);
            }
        }
    }
    pub fn get(&mut self, source: &str) -> Option<Entry> {
        let key = Self::key(source)?;
        let entry = self.entries.get(&key)?.clone();
        self.touch(&key);
        Some(entry)
    }
    pub fn peek(&self, source: &str) -> Option<&Entry> {
        self.entries.get(&Self::key(source)?)
    }
    pub fn clear(&mut self) {
        self.order.clear();
        self.entries.clear();
    }
    pub fn len(&self) -> usize {
        self.entries.len()
    }
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}
