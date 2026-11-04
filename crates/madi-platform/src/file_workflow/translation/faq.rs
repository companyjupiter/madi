//! Preserve the shipping legacy bank. Seed only a genuinely absent destination;
//! malformed or unreadable user bytes are retained and use an in-memory fallback.
use crate::translation_cache::starter_faq;
use madi_core::translation::cache::{Entry, Faq};
use std::{fs, io, path::Path};

fn read(path: &Path) -> io::Result<Faq> {
    serde_json::from_slice::<Vec<Entry>>(&fs::read(path)?)
        .map(crate::translation_cache::faq)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}
fn seed(path: &Path) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("FAQ path has no parent"))?;
    fs::create_dir_all(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    serde_json::to_writer_pretty(file.as_file_mut(), &Faq::starter_entries())
        .map_err(io::Error::other)?;
    file.as_file().sync_all()?;
    file.persist_noclobber(path).map_err(|e| e.error)?;
    Ok(())
}
pub(super) fn load(path: &Path) -> Faq {
    match read(path) {
        Ok(bank) => bank,
        Err(error) if error.kind() == io::ErrorKind::NotFound => match seed(path) {
            Ok(()) => starter_faq(),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                read(path).unwrap_or_else(|_| starter_faq())
            }
            Err(error) => {
                eprintln!("FAQ seed: {error}");
                starter_faq()
            }
        },
        Err(error) => {
            eprintln!("FAQ load (existing file retained): {error}");
            starter_faq()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_seed_and_valid_custom_bank_survive_reloads() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("Sovereign/faq_translations.json");
        let initial = load(&path);
        assert!(initial.lookup("아픈가요?").is_some());
        let entries: Vec<Entry> = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(entries.len(), 15);
        let custom = br#"[{"English":"custom phrase","Japanese":"custom answer"}]"#;
        fs::write(&path, custom).unwrap();
        assert_eq!(
            load(&path).lookup("custom phrase").unwrap()["Japanese"],
            "custom answer"
        );
        assert_eq!(fs::read(&path).unwrap(), custom);
        assert!(seed(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), custom);
    }
    #[test]
    fn malformed_file_and_nonfile_destination_are_never_overwritten() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("faq.json");
        fs::write(&path, b"{ important unfinished edit").unwrap();
        assert!(load(&path).lookup("아픈가요?").is_some());
        assert_eq!(fs::read(&path).unwrap(), b"{ important unfinished edit");
        let directory = root.path().join("directory");
        fs::create_dir(&directory).unwrap();
        load(&directory);
        assert!(directory.is_dir());
    }
    #[test]
    fn concurrent_first_load_publishes_one_complete_bank() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("faq.json");
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        let jobs: Vec<_> = (0..8)
            .map(|_| {
                let path = path.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    assert!(load(&path).lookup("아픈가요?").is_some());
                })
            })
            .collect();
        for job in jobs {
            job.join().unwrap();
        }
        assert_eq!(
            serde_json::from_slice::<Vec<Entry>>(&fs::read(path).unwrap())
                .unwrap()
                .len(),
            15
        );
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
    }
}
