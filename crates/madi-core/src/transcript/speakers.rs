use serde::Serialize;
use std::collections::BTreeMap;

pub const UNKNOWN_SPEAKER: i64 = 255;
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SpeakerNumbers {
    pub numbers: BTreeMap<i64, u64>,
    next: u64,
}
impl Default for SpeakerNumbers {
    fn default() -> Self {
        Self {
            numbers: BTreeMap::new(),
            next: 1,
        }
    }
}
impl SpeakerNumbers {
    pub fn assign(&mut self, id: i64) -> Option<u64> {
        if id == UNKNOWN_SPEAKER {
            return None;
        }
        if let Some(number) = self.numbers.get(&id) {
            return Some(*number);
        }
        let number = self.next;
        self.next += 1;
        self.numbers.insert(id, number);
        Some(number)
    }
    pub fn assign_all(&mut self, ids: impl IntoIterator<Item = i64>) {
        for id in ids {
            self.assign(id);
        }
    }
    pub fn merge(&mut self, from: i64, into: i64) {
        match (
            self.numbers.get(&from).copied(),
            self.numbers.get(&into).copied(),
        ) {
            (Some(a), Some(b)) => {
                self.numbers.insert(into, a.min(b));
                self.numbers.insert(from, a.min(b));
            }
            (Some(a), None) => {
                self.numbers.insert(into, a);
            }
            _ => (),
        }
    }
    pub fn reset(&mut self) {
        *self = Self::default();
    }
    pub fn is_deciding(margin: f64, age: f64) -> bool {
        margin < 0.35 && age < 300.0
    }
}
