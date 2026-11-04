//! Match the installed Foundation Unicode categories on macOS. Other platforms
//! use the pinned portable baseline checked against the original macOS app.
use madi_core::translation::cache::{self, Entry, Faq};
#[cfg(target_os = "macos")]
fn symbol(ch: char) -> bool {
    use std::ffi::c_void;
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFCharacterSetGetPredefined(identifier: isize) -> *const c_void;
        fn CFCharacterSetIsLongCharacterMember(set: *const c_void, scalar: u32) -> u8;
    }
    // CFCharacterSet.h: 11 = punctuation, 14 = symbols. Both references are
    // immutable, CF-owned predefined sets; no release or mutable alias exists.
    unsafe {
        CFCharacterSetIsLongCharacterMember(CFCharacterSetGetPredefined(11), ch as u32) != 0
            || CFCharacterSetIsLongCharacterMember(CFCharacterSetGetPredefined(14), ch as u32) != 0
    }
}
#[cfg(not(target_os = "macos"))]
fn symbol(ch: char) -> bool {
    cache::faq_symbol(ch)
}
pub fn normalize_faq(text: &str) -> Option<String> {
    cache::faq_normalize_with(text, symbol)
}
pub fn faq(entries: Vec<Entry>) -> Faq {
    Faq::with_classifier(entries, symbol)
}
pub fn starter_faq() -> Faq {
    faq(Faq::starter_entries())
}
