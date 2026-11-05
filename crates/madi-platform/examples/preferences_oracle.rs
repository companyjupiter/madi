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
    let settings = &restored.settings;
    let mut caption = settings.clone();
    caption
        .apply(
            &mut setup.clone(),
            &madi_core::settings::SettingsCommand::PatientPanel(
                settings.caption.patient_panel_enabled,
            ),
        )
        .unwrap();
    let settings_bits = [
        settings.live_window_seconds,
        settings.translate_tail_seconds,
        settings.vad_conf_threshold,
        settings.caption.staff_font_size,
        settings.caption.patient_font_size,
        settings.caption.panel_width,
        settings.caption.min_scale_factor,
    ]
    .map(|value| format!("{:016x}", value.to_bits()));
    json!({"settingsNumericBits":settings_bits,"effectiveWindow":settings.effective_window_seconds(&setup),"multiTranslateForcesAccurate":settings.multi_translate_forces_accurate(&setup),"clampedCaption":caption.caption,"restored":restored,"fontSteps":steps,"inputLanguage":setup.input_language,"engineToken":madi_platform::asr_config::FileSettings::from_setup(&setup,0,Vec::new()).unwrap().language_token,"nonEnglishFeatures":madi_core::transcript::Features::for_language(setup.language_token()).speaker_island_absorption})
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
        let registration = NSString::from_str("NSRegistrationDomain");
        if let Some(blob) = raw.get("__captionJSON").and_then(Value::as_str) {
            let key = NSString::from_str("captionSettings.v1");
            let data = NSData::with_bytes(blob.as_bytes());
            let values = NSDictionary::<NSString, objc2::runtime::AnyObject>::from_slices(
                &[&*key],
                &[&*data],
            );
            unsafe {
                defaults.setVolatileDomain_forName(&values, &registration);
            }
        }
        let legacy = madi_platform::preferences::read_legacy(&defaults);
        defaults.removeVolatileDomainForName(&registration);
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
