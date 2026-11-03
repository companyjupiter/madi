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
            "file_snapshot",
            "file_start",
            "file_reset",
            "file_edit",
            "file_copy_line",
            "file_rename_speaker",
        ]));
    tauri_build::try_build(attributes).expect("failed to build the parity host");
}
