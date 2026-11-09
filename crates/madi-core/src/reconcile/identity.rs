//! Equality-only counterpart of CoreFoundation's nonlocalized, nonliteral,
//! case-insensitive comparison. Fold only at unequal UTF-16 positions: a single
//! normalized key changes the original's combining-mark and surrogate behavior.
//! Algorithm reference: swiftlang/swift-corelibs-foundation, CFString.c,
//! CFStringCompareWithOptionsAndLocale / __CFStringFoldCharacterClusterAtIndex.
use super::name_fold::{EXTEND, NAME_FOLD};
use unicode_normalization::{UnicodeNormalization, char::canonical_combining_class};
use unicode_segmentation::UnicodeSegmentation;

fn extend(c: u32) -> bool {
    EXTEND.binary_search(&c).is_ok()
}
fn decompose(c: u32) -> Vec<u32> {
    char::from_u32(c).map_or_else(|| vec![c], |c| c.to_string().nfd().map(u32::from).collect())
}
struct Cursor<'a> {
    text: &'a str,
    units: Vec<u16>,
    index: usize,
    used: usize,
    folded: Vec<u32>,
    next: usize,
    prevent_until: usize,
}
impl<'a> Cursor<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            text,
            units: text.encode_utf16().collect(),
            index: 0,
            used: 1,
            folded: Vec::new(),
            next: 0,
            prevent_until: 0,
        }
    }
    fn scalar(&self, index: usize) -> Option<(u32, usize)> {
        let first = *self.units.get(index)?;
        if (0xd800..=0xdbff).contains(&first)
            && let Some(&second) = self.units.get(index + 1)
            && (0xdc00..=0xdfff).contains(&second)
        {
            return Some((
                0x10000 + ((u32::from(first) - 0xd800) << 10) + (u32::from(second) - 0xdc00),
                2,
            ));
        }
        Some((u32::from(first), 1))
    }
    fn current(&mut self) -> u32 {
        if self.folded.is_empty() {
            self.used = 1;
            let c = u32::from(self.units[self.index]);
            if (65..=90).contains(&c) { c + 32 } else { c }
        } else {
            let c = self.folded[self.next];
            self.next += 1;
            c
        }
    }
    fn expand(&mut self, c: u32) -> u32 {
        if (0xd800..=0xdbff).contains(&c)
            && let Some((value, 2)) = self.scalar(self.index)
        {
            self.used = 2;
            value
        } else {
            c
        }
    }
    fn fold(&mut self, c: u32) -> u32 {
        if c == 0
            || !self.folded.is_empty()
            || (self.prevent_until != 0 && self.prevent_until != self.index)
        {
            return c;
        }
        self.prevent_until = 0;
        let mut end = self.index + self.used;
        let mut folded = decompose(c);
        let base = folded[0];
        let mut changed = folded != [c];
        if let Some(base) = char::from_u32(base)
            && let Ok(index) = NAME_FOLD.binary_search_by_key(&base, |(key, _)| *key)
        {
            let mut mapped: Vec<_> = NAME_FOLD[index].1.chars().map(u32::from).collect();
            mapped.extend_from_slice(&folded[1..]);
            folded = mapped;
            changed = true;
        }
        let mut overflow = false;
        while let Some((value, width)) = self.scalar(end) {
            if !extend(value) {
                break;
            }
            let marks = decompose(value);
            if folded.len() + marks.len() > 64 {
                overflow = true;
                break;
            }
            folded.extend(marks);
            end += width;
            changed = true;
            if folded.len() == 64 {
                overflow = true;
                break;
            }
        }
        if !changed {
            return c;
        }
        // Sort only the trailing combining sequence, preserving earlier case
        // expansions. The first scalar can itself be a nonstarter.
        let mut sort = folded.len() - 1;
        while sort > 0 && extend(folded[sort]) {
            sort -= 1;
        }
        folded[sort..].sort_by_key(|c| char::from_u32(*c).map_or(0, canonical_combining_class));
        if overflow {
            let mut boundary = 0;
            for cluster in self.text.graphemes(true) {
                boundary += cluster.encode_utf16().count();
                if boundary > self.index {
                    self.prevent_until = boundary;
                    break;
                }
            }
        }
        self.used = end - self.index;
        self.next = 1;
        let result = folded[0];
        self.folded = folded;
        result
    }
    fn advance(&mut self) {
        if self.next == self.folded.len() {
            self.folded.clear();
            self.next = 0;
        }
        if self.folded.is_empty() {
            self.index += self.used;
        }
    }
}
pub(super) fn equal(a: &str, b: &str) -> bool {
    let (mut a, mut b) = (Cursor::new(a), Cursor::new(b));
    while a.index < a.units.len() && b.index < b.units.len() {
        let (mut x, mut y) = (a.current(), b.current());
        if x != y {
            x = a.expand(x);
            y = b.expand(y);
            if x != y {
                x = a.fold(x);
                if a.folded.is_empty() && !b.folded.is_empty() {
                    return false;
                }
                if b.folded.is_empty() && (a.folded.is_empty() || x != y) {
                    y = b.fold(y);
                    if b.folded.is_empty() || x != y {
                        return false;
                    }
                } else if x != y {
                    return false;
                }
            }
        }
        a.advance();
        b.advance();
    }
    a.index == a.units.len() && b.index == b.units.len()
}
