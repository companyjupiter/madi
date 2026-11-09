use madi_core::{
    capture_stream,
    settings::{LegacySettings, Settings},
    setup::{AudioSource, Language, SetupState},
};
use madi_platform::asr_config::{LiveSettings, Resources};
use serde::Deserialize;
use std::io::Read;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    speaker_count: u8,
    diarize: bool,
    osd: bool,
    input_language: Option<Language>,
    restored_language: Option<i64>,
    targets: Vec<String>,
    physical_memory: u64,
    bias_terms: Vec<String>,
    window: f64,
    preview: bool,
    source: AudioSource,
}
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&input).unwrap();
    let scratch = tempfile::tempdir().unwrap();
    let canonical = scratch.path().canonicalize().unwrap();
    let resources = Resources {
        executable: "/madi/engine".into(),
        model: "/madi/model".into(),
        bpe: "/madi/bpe".into(),
        assets: "/madi/assets".into(),
    };
    let results:Vec<_>=cases.into_iter().map(|case| {
        let setup=SetupState { speaker_count:case.speaker_count,diarize:case.diarize,osd:case.osd,input_language:case.input_language,restored_language_token:case.restored_language,translate_targets:case.targets,audio_source:case.source,..SetupState::default() };
        let settings=LiveSettings::from_setup(&setup,case.physical_memory,case.bias_terms).unwrap();
        let launch=resources.live_launch(scratch.path(),&settings).unwrap();
        assert_eq!(launch.environment.get(std::ffi::OsStr::new("STREAM_WAV_ROOTS")),Some(&Some(canonical.clone().into_os_string())));
        let mut environment:std::collections::BTreeMap<_,_>=launch.environment.into_iter().filter_map(|(key,value)|value.map(|v|(key.to_string_lossy().into_owned(),v.to_string_lossy().into_owned()))).collect();
        // Normalize only the asserted host-owned temporary path for comparison.
        environment.insert("STREAM_WAV_ROOTS".into(),"/madi/owned".into());
        let app_settings=Settings::from_legacy(LegacySettings { live_window_seconds:Some(case.window),live_preview_enabled:Some(case.preview),..LegacySettings::default() });
        serde_json::json!({"executable":launch.executable,"cwd":launch.working_directory,"arguments":launch.arguments.iter().map(|a|a.to_string_lossy()).collect::<Vec<_>>(),"environment":environment,"capture":capture_stream::Configuration::from_settings(&app_settings,&setup)})
    }).collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
