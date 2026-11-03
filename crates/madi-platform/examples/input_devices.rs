fn main() {
    println!(
        "{}",
        serde_json::to_string(&madi_platform::audio_devices::snapshot()).unwrap()
    );
}
