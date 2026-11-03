use super::*;

const ABC: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

#[test]
fn integrity_rejects_same_size_tampering_truncation_and_non_files() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("model.bin");
    std::fs::write(&path, b"abc").unwrap();
    assert_eq!(sha256(&path).unwrap(), ABC);
    assert!(file_is_valid(&path, 3, ABC));
    assert!(!file_is_valid(&path, 3, &ABC.to_uppercase()));
    std::fs::write(&path, b"abd").unwrap();
    assert!(!file_is_valid(&path, 3, ABC));
    std::fs::write(&path, b"ab").unwrap();
    assert!(!file_is_valid(&path, 3, ABC));
    assert!(!file_is_valid(root.path(), 0, ABC));
    assert!(!file_is_valid(&root.path().join("missing"), 3, ABC));
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let fifo = root.path().join("not-a-model");
        let name = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        // Own temporary directory; this verifies special files cannot wedge the
        // verifier waiting for a FIFO writer. No device/user path is involved.
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        assert!(!file_is_valid(&fifo, 0, ABC));
        assert!(sha256(&fifo).is_err());
    }
}

#[test]
fn fast_gate_and_full_integrity_have_deliberately_different_link_contracts() {
    let root = tempfile::tempdir().unwrap();
    let original = root.path().join("original.bin");
    std::fs::write(&original, b"abc").unwrap();
    let small_asset = RemoteAsset {
        size_bytes: 3,
        ..TRANSCRIPTION
    };
    assert!(fast_size_matches(&original, small_asset));
    std::fs::write(&original, b"abd").unwrap();
    assert!(fast_size_matches(&original, small_asset));
    assert!(!file_is_valid(&original, 3, ABC));
    std::fs::write(&original, b"abc").unwrap();
    let link = root.path().join("dev-seed.bin");
    #[cfg(unix)]
    std::os::unix::fs::symlink(&original, &link).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_file(&original, &link).unwrap();
    assert!(fast_size_matches(&link, small_asset));
    assert_eq!(sha256(&link).unwrap(), ABC);
    assert!(!file_is_valid(&link, 3, ABC));
    assert_eq!(std::fs::read(&original).unwrap(), b"abc");
}

#[test]
fn lookup_is_read_only_and_existing_bundled_model_wins_even_when_invalid() {
    let root = tempfile::tempdir().unwrap();
    let locations = Locations {
        bundle_resources: root.path().join("Resources"),
        bundle_executables: root.path().join("MacOS"),
        support: root.path().join("Madi"),
    };
    assert_eq!(
        locations.transcription_model(),
        locations.support.join(TRANSCRIPTION.name)
    );
    assert!(!locations.support.exists());
    for variant in [
        TranslationVariant::Quality4B,
        TranslationVariant::Realtime2B,
    ] {
        assert_eq!(
            locations.translation_model(variant),
            locations.support.join(variant.asset().name)
        );
        assert!(!locations.translation_available(variant));
    }
    std::fs::create_dir(&locations.bundle_resources).unwrap();
    let bundled = locations.bundle_resources.join(TRANSCRIPTION.name);
    std::fs::write(&bundled, b"invalid bundled model").unwrap();
    assert_eq!(locations.transcription_model(), bundled);
    assert!(!fast_size_matches(&bundled, TRANSCRIPTION));
    std::fs::create_dir(&locations.bundle_executables).unwrap();
    let engine = locations.bundle_executables.join(if cfg!(windows) {
        "translate-engine-4b.exe"
    } else {
        "translate-engine-4b"
    });
    std::fs::write(&engine, b"test fixture, not an executable").unwrap();
    assert_eq!(
        locations.translation_engine(TranslationVariant::Quality4B),
        Some(engine)
    );
    // As in Swift, locating an engine is only an existence check. It must not
    // imply its model is ready or claim the engine can execute.
    assert!(!locations.translation_available(TranslationVariant::Quality4B));
    assert!(!locations.support.exists());
    assert_eq!(std::fs::read(&bundled).unwrap(), b"invalid bundled model");
}
