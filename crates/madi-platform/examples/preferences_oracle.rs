use madi_core::preferences::{Legacy, Preferences, PresentationCommand};
use serde_json::{Value, json};
use std::io::Read;
fn result(legacy: Legacy) -> Value {
    let restored = Preferences::from_legacy(legacy);
    restored.validate().unwrap();
    let setup = restored.setup();
    let mut presentation = restored.presentation.clone();
    let mut steps = vec![format!("{:016x}", presentation.font_size.to_bits())];
    for smaller in [true, true, false, false, false, true] {
        presentation.apply(if smaller {
            PresentationCommand::SmallerText
        } else {
            PresentationCommand::LargerText
        });
        steps.push(format!("{:016x}", presentation.font_size.to_bits()));
    }
    json!({"restored":restored,"fontSteps":steps,"inputLanguage":setup.input_language,"engineToken":madi_platform::asr_config::FileSettings::from_setup(&setup,true,0,Vec::new()).unwrap().language_token,"nonEnglishFeatures":madi_core::transcript::Features::for_language(setup.language_token()).speaker_island_absorption})
}
#[cfg(target_os = "macos")]
fn native(raw: &Value) -> Legacy {
    use objc2::{AllocAnyThread, rc::autoreleasepool};
    use objc2_foundation::{
        NSData, NSDictionary, NSJSONReadingOptions, NSJSONSerialization, NSString, NSUserDefaults,
    };
    autoreleasepool(|_| {
        let bytes = serde_json::to_vec(raw).unwrap();
        let object = NSJSONSerialization::JSONObjectWithData_options_error(
            &NSData::with_bytes(&bytes),
            NSJSONReadingOptions::empty(),
        )
        .unwrap();
        let dictionary = object.downcast::<NSDictionary>().unwrap();
        // JSON object keys are NSString; only the key generic is refined.
        let dictionary = unsafe {
            objc2::rc::Retained::cast_unchecked::<NSDictionary<NSString, objc2::runtime::AnyObject>>(
                dictionary,
            )
        };
        // Isolated process-only fixtures: no persistent suite, original domain,
        // or real user settings are read or written by this oracle.
        let defaults = NSUserDefaults::initWithSuiteName(
            NSUserDefaults::alloc(),
            Some(&NSString::from_str(&format!(
                "madi-preferences-oracle-{}",
                std::process::id()
            ))),
        )
        .unwrap();
        let domain = NSString::from_str("NSArgumentDomain");
        unsafe {
            defaults.setVolatileDomain_forName(&dictionary, &domain);
        }
        let legacy = madi_platform::preferences::read_legacy(&defaults);
        defaults.removeVolatileDomainForName(&domain);
        legacy
    })
}
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let values: Vec<Value> = serde_json::from_str(&input).unwrap();
    let normalized = std::env::args().any(|arg| arg == "--normalized");
    let results: Vec<_> = values
        .iter()
        .map(|value| {
            let legacy = if normalized {
                serde_json::from_value(value.clone()).unwrap()
            } else {
                #[cfg(target_os = "macos")]
                {
                    native(value)
                }
                #[cfg(not(target_os = "macos"))]
                {
                    panic!("native preferences oracle requires macOS");
                }
            };
            result(legacy)
        })
        .collect();
    println!("{}", json!(results));
}
