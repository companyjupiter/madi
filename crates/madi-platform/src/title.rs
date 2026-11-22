//! Use the installed Foundation classifier, like the original macOS title policy.
#[cfg(target_os = "macos")]
pub fn sanitize(raw: &str) -> Option<String> {
    madi_core::title::sanitize_with(raw, alphanumeric)
}

#[cfg(target_os = "macos")]
fn alphanumeric(ch: char) -> bool {
    use std::ffi::c_void;
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFCharacterSetGetPredefined(identifier: isize) -> *const c_void;
        fn CFCharacterSetIsLongCharacterMember(set: *const c_void, scalar: u32) -> u8;
    }
    // kCFCharacterSetAlphaNumeric = 10; the immutable predefined set is CF-owned.
    unsafe { CFCharacterSetIsLongCharacterMember(CFCharacterSetGetPredefined(10), ch as u32) != 0 }
}
