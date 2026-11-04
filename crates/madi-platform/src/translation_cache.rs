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
    #[cfg(target_os = "macos")]
    {
        cache::faq_normalize_lowered(&swift_lowercase(text), symbol)
    }
    #[cfg(not(target_os = "macos"))]
    cache::faq_normalize_with(text, symbol)
}
pub fn faq(entries: Vec<Entry>) -> Faq {
    Faq::with_normalizer(entries, normalize_faq)
}
pub fn starter_faq() -> Faq {
    faq(Faq::starter_entries())
}

#[cfg(target_os = "macos")]
fn swift_lowercase(text: &str) -> String {
    use std::ffi::c_void;
    unsafe extern "C" {
        fn madi_swift_lowercase(
            source: *const u8,
            count: isize,
            context: *mut c_void,
            output: unsafe extern "C" fn(*mut c_void, *const u8, isize),
        );
    }
    unsafe extern "C" fn copy(context: *mut c_void, bytes: *const u8, count: isize) {
        // The bridge calls synchronously with a borrowed, valid UTF-8 buffer.
        // Empty Swift arrays may have a null base address; do not dereference it.
        if count > 0 {
            unsafe {
                (*context.cast::<Vec<u8>>())
                    .extend_from_slice(std::slice::from_raw_parts(bytes, count as usize));
            }
        }
    }
    let mut result = Vec::<u8>::new();
    unsafe {
        madi_swift_lowercase(
            text.as_ptr(),
            text.len() as isize,
            (&mut result as *mut Vec<u8>).cast(),
            copy,
        );
    }
    String::from_utf8(result).expect("Swift lowercase produces valid UTF-8")
}
