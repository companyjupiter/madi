fn main() {
    let attributes =
        tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
            "setup_snapshot",
            "setup_command",
            "audio_inputs",
            "choose_file",
            "models_snapshot",
            "models_command",
            "models_artwork",
        ]));
    tauri_build::try_build(attributes).expect("failed to build the parity host");
}
