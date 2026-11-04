fn main() {
    let attributes =
        tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
            "preferences_snapshot",
            "preferences_command",
            "settings_command",
            "glossary_snapshot",
            "glossary_command",
            "setup_snapshot",
            "setup_command",
            "audio_inputs",
            "choose_file",
            "models_snapshot",
            "models_command",
            "models_artwork",
            "file_snapshot",
            "file_artwork",
            "file_start",
            "file_reset",
            "file_edit",
            "file_copy_line",
            "file_rename_speaker",
            "workspace_snapshot",
            "workspace_command",
            "workspace_choose_folder",
            "workspace_open",
            "workspace_export",
        ]));
    tauri_build::try_build(attributes).expect("failed to build the parity host");
}
