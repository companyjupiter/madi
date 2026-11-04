//! Volatile native preference fixtures only; never accesses the original domain.
#[cfg(target_os = "macos")]
fn main() {
    use objc2::{AllocAnyThread, rc::autoreleasepool, runtime::AnyObject};
    use objc2_foundation::{NSData, NSDictionary, NSString, NSUserDefaults};
    use std::io::Read;
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Option<String>> = serde_json::from_str(&input).unwrap();
    let values: Vec<_> = cases
        .iter()
        .map(|raw| {
            autoreleasepool(|_| {
                let defaults = NSUserDefaults::initWithSuiteName(
                    NSUserDefaults::alloc(),
                    Some(&NSString::from_str(&format!(
                        "madi-glossary-oracle-{}",
                        std::process::id()
                    ))),
                )
                .unwrap();
                let domain = NSString::from_str("NSArgumentDomain");
                let key = NSString::from_str("personalGlossary");
                let value: objc2::rc::Retained<AnyObject> = raw.as_ref().map_or_else(
                    // A valid property-list value of the wrong type must fall
                    // back without consulting any other preference domain.
                    || NSString::from_str("not-data").into_super().into_super(),
                    |raw| NSData::with_bytes(raw.as_bytes()).into_super().into_super(),
                );
                let values = NSDictionary::<NSString, AnyObject>::from_slices(&[&*key], &[&*value]);
                unsafe {
                    defaults.setVolatileDomain_forName(&values, &domain);
                }
                let glossary = madi_platform::glossary_service::read_legacy(&defaults);
                defaults.removeVolatileDomainForName(&domain);
                glossary
            })
        })
        .collect();
    println!("{}", serde_json::to_string(&values).unwrap());
}
#[cfg(not(target_os = "macos"))]
fn main() {
    panic!("native Foundation glossary bridge requires macOS");
}
