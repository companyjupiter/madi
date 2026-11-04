//! Native metadata and owned system-symbol bitmaps; no window or screen capture.
#[cfg(target_os = "macos")]
fn main() {
    use madi_platform::model_presentation;
    let bytes = [
        0, 1, 999, 1000, 867485320, 1312165344, 2783447424, 2179650664, 3650932744,
    ];
    let titles =
        [0.0, 1735689600.0, 1793800800.0].map(madi_platform::session_archive::live_fallback_title);
    println!(
        "{}",
        serde_json::json!({
            "physicalMemory": model_presentation::physical_memory(),
            "sizes": bytes.map(model_presentation::file_size),
            "liveFallbackTitles": titles,
            "artwork": model_presentation::artwork().expect("native system artwork"),
            "transcriptArtwork": model_presentation::transcript_artwork().expect("native transcript artwork"),
        })
    );
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("Native model presentation requires macOS");
    std::process::exit(1);
}
