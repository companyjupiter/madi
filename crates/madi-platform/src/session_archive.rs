//! Session-owned archive pointer and no-clobber allocation. File I/O belongs on
//! the workflow's blocking worker, never on the native UI thread.
use std::{
    fs,
    io::{self, Write},
    path::{Component, Path, PathBuf},
};
use tempfile::{Builder, NamedTempFile};

#[derive(Debug, Default)]
pub struct SessionArchiveWriter {
    transcript: Option<PathBuf>,
    last_error: Option<String>,
}
impl SessionArchiveWriter {
    pub fn transcript(&self) -> Option<&Path> {
        self.transcript.as_deref()
    }
    pub fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }
    pub fn reset(&mut self) {
        self.transcript = None;
        self.last_error = None;
    }

    pub fn save_transcript(&mut self, markdown: &str, folder: &Path, base: &str) -> bool {
        let result = (|| {
            let destination = if let Some(destination) = &self.transcript {
                let parent = destination.parent().ok_or_else(invalid_name)?;
                fs::create_dir_all(parent)?;
                let file = prepared(parent, markdown.as_bytes())?;
                file.persist(destination).map_err(|failure| failure.error)?;
                destination.clone()
            } else {
                validate_base(base)?;
                fs::create_dir_all(folder)?;
                persist_new(prepared(folder, markdown.as_bytes())?, folder, base)?
            };
            self.transcript = Some(destination);
            Ok(())
        })();
        self.record(result)
    }

    pub fn save_summary(&mut self, summary: &str) -> bool {
        let Some(transcript) = self.transcript.clone() else {
            return false;
        };
        let result = (|| {
            let base = stem(&transcript)?;
            let folder = transcript.parent().ok_or_else(invalid_name)?;
            fs::create_dir_all(folder)?;
            let content = format!("# {base} — 회의 요약\n\n{summary}\n");
            persist_new(
                prepared(folder, content.as_bytes())?,
                folder,
                &format!("{base} 요약"),
            )?;
            Ok(())
        })();
        self.record(result)
    }

    pub fn rename(&mut self, title: &str, folder: &Path) -> bool {
        let Some(source) = self.transcript.clone() else {
            return false;
        };
        let result = (|| {
            validate_base(title)?;
            fs::create_dir_all(folder)?;
            let destination = move_available(&source, folder, title)?;
            // A companion failure must not leave the pointer at the old path.
            self.transcript = Some(destination.clone());
            let old_summary = source.with_file_name(format!("{} 요약.md", stem(&source)?));
            if old_summary.exists() {
                move_available(
                    &old_summary,
                    folder,
                    &format!("{} 요약", stem(&destination)?),
                )?;
            }
            Ok(())
        })();
        self.record(result)
    }
    fn record(&mut self, result: io::Result<()>) -> bool {
        self.last_error = result.as_ref().err().map(ToString::to_string);
        result.is_ok()
    }
}
fn invalid_name() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "archive name must be a single file name",
    )
}
fn validate_base(base: &str) -> io::Result<()> {
    // Names originate from the native filename or the title generator. Never
    // permit a future renderer command to escape the selected workspace.
    if !base.is_empty()
        && (base.contains(['/', '\0'])
            || (cfg!(windows) && base.contains('\\'))
            || !matches!(
                Path::new(base).components().collect::<Vec<_>>().as_slice(),
                [Component::Normal(_)]
            ))
    {
        return Err(invalid_name());
    }
    Ok(())
}
fn stem(path: &Path) -> io::Result<&str> {
    path.file_stem()
        .and_then(|name| name.to_str())
        .ok_or_else(invalid_name)
}
fn candidate(folder: &Path, base: &str, suffix: u64) -> io::Result<PathBuf> {
    let base = if suffix == 1 {
        base.to_owned()
    } else {
        format!("{base} {suffix}")
    };
    #[cfg(target_os = "macos")]
    {
        use objc2_foundation::{NSString, NSURL};
        use std::{ffi::CStr, os::unix::ffi::OsStrExt};
        // Keep Foundation's filename representation, including its filesystem
        // decomposition rules. This is not ordinary Unicode NFD (e.g. U+212B).
        // Blocking workers do not inherit AppKit's event-loop autorelease pool.
        objc2::rc::autoreleasepool(|_| {
            let folder = folder.to_str().ok_or_else(invalid_name)?;
            let url = NSURL::fileURLWithPath_isDirectory(&NSString::from_str(folder), true)
                .URLByAppendingPathComponent(&NSString::from_str(&base))
                .ok_or_else(invalid_name)?
                .URLByAppendingPathExtension(&NSString::from_str("md"))
                .ok_or_else(invalid_name)?;
            // URL owns this representation until the owned PathBuf is copied.
            let bytes =
                unsafe { CStr::from_ptr(url.fileSystemRepresentation().as_ptr()) }.to_bytes();
            Ok(PathBuf::from(std::ffi::OsStr::from_bytes(bytes)))
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(folder.join(format!("{base}.md")))
    }
}
fn next_suffix(suffix: u64) -> io::Result<u64> {
    suffix
        .checked_add(1)
        .ok_or_else(|| io::Error::other("archive name suffix exhausted"))
}
fn prepared(folder: &Path, contents: &[u8]) -> io::Result<NamedTempFile> {
    let mut file = Builder::new()
        .prefix(".madi-archive-")
        .tempfile_in(folder)?;
    file.write_all(contents)?;
    file.as_file().sync_all()?;
    Ok(file)
}
fn persist_new(mut file: NamedTempFile, folder: &Path, base: &str) -> io::Result<PathBuf> {
    let mut suffix = 1;
    loop {
        let destination = candidate(folder, base, suffix)?;
        // Includes directories and dangling links; atomic persist below also
        // protects against another writer claiming the candidate after this.
        if fs::symlink_metadata(&destination).is_ok() {
            suffix = next_suffix(suffix)?;
            continue;
        }
        match file.persist_noclobber(&destination) {
            Ok(_) => return Ok(destination),
            Err(failure) if failure.error.kind() == io::ErrorKind::AlreadyExists => {
                file = failure.file;
                suffix = next_suffix(suffix)?;
            }
            Err(failure) => return Err(failure.error),
        }
    }
}
fn move_available(source: &Path, folder: &Path, base: &str) -> io::Result<PathBuf> {
    let mut suffix = 1;
    loop {
        let destination = candidate(folder, base, suffix)?;
        if fs::symlink_metadata(&destination).is_ok() {
            suffix = next_suffix(suffix)?;
            continue;
        }
        match move_no_replace(source, &destination) {
            Ok(()) => return Ok(destination),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                suffix = next_suffix(suffix)?
            }
            Err(error) if error.kind() == io::ErrorKind::CrossesDevices => {
                let mut file = Builder::new()
                    .prefix(".madi-archive-")
                    .tempfile_in(folder)?;
                io::copy(&mut fs::File::open(source)?, file.as_file_mut())?;
                file.as_file().sync_all()?;
                let destination = persist_new(file, folder, base)?;
                fs::remove_file(source)?;
                return Ok(destination);
            }
            Err(error) => return Err(error),
        }
    }
}
#[cfg(target_os = "macos")]
fn move_no_replace(source: &Path, destination: &Path) -> io::Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let source = CString::new(source.as_os_str().as_bytes()).map_err(|_| invalid_name())?;
    let destination =
        CString::new(destination.as_os_str().as_bytes()).map_err(|_| invalid_name())?;
    // Both paths remain alive for the system call. RENAME_EXCL never replaces
    // a file created by a competing session after our availability check.
    if unsafe { libc::renamex_np(source.as_ptr(), destination.as_ptr(), libc::RENAME_EXCL) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
#[cfg(target_os = "windows")]
fn move_no_replace(source: &Path, destination: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "Kernel32")]
    unsafe extern "system" {
        fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
    }
    fn wide(path: &Path) -> io::Result<Vec<u16>> {
        let mut value: Vec<_> = path.as_os_str().encode_wide().collect();
        if value.contains(&0) {
            return Err(invalid_name());
        }
        value.push(0);
        Ok(value)
    }
    let source = wide(source)?;
    let destination = wide(destination)?;
    // COPY_ALLOWED preserves native move behavior across volumes. Deliberately
    // omit REPLACE_EXISTING; this call owns both NUL-terminated buffers.
    if unsafe { MoveFileExW(source.as_ptr(), destination.as_ptr(), 2) } != 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn move_no_replace(source: &Path, destination: &Path) -> io::Result<()> {
    fs::hard_link(source, destination)?;
    fs::remove_file(source)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn concurrent_sessions_never_overwrite_and_checkpoints_keep_their_file() {
        let directory = tempfile::tempdir().unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(12));
        let workers: Vec<_> = (0..12)
            .map(|index| {
                let path = directory.path().to_path_buf();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    let mut writer = SessionArchiveWriter::default();
                    barrier.wait();
                    assert!(
                        writer.save_transcript(&index.to_string(), &path, "회의"),
                        "initial archive {index}: {:?}",
                        writer.last_error()
                    );
                    let destination = writer.transcript().unwrap().to_path_buf();
                    assert!(
                        writer.save_transcript(
                            &format!("updated-{index}"),
                            &path.join("ignored"),
                            "also ignored"
                        ),
                        "checkpoint {index} at {}: {:?}",
                        destination.display(),
                        writer.last_error()
                    );
                    assert_eq!(writer.transcript(), Some(destination.as_path()));
                    (destination, index)
                })
            })
            .collect();
        let results: Vec<_> = workers
            .into_iter()
            .map(|worker| worker.join().unwrap())
            .collect();
        let paths: std::collections::BTreeSet<_> = results.iter().map(|(path, _)| path).collect();
        assert_eq!(paths.len(), 12);
        for (path, index) in results {
            assert_eq!(
                fs::read_to_string(path).unwrap(),
                format!("updated-{index}")
            );
        }
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 12);
    }
    #[test]
    fn failed_writes_do_not_advance_pointer_or_erase_prior_content() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("workspace");
        fs::write(&folder, "blocker").unwrap();
        let mut writer = SessionArchiveWriter::default();
        assert!(!writer.save_transcript("lost", &folder, "record"));
        assert!(writer.transcript().is_none() && writer.last_error().is_some());
        fs::remove_file(&folder).unwrap();
        assert!(writer.save_transcript("retained", &folder, "record"));
        let path = writer.transcript().unwrap().to_path_buf();
        assert!(writer.last_error().is_none());
        assert!(!writer.rename("../escape", &folder));
        assert_eq!(writer.transcript(), Some(path.as_path()));
        assert_eq!(fs::read_to_string(&path).unwrap(), "retained");
        // A directory at the checkpoint path cannot be replaced by persist.
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        fs::write(path.join("keep"), "foreign").unwrap();
        assert!(!writer.save_transcript("new", &folder, "ignored"));
        assert_eq!(fs::read_to_string(path.join("keep")).unwrap(), "foreign");
        assert_eq!(writer.transcript(), Some(path.as_path()));
        assert_eq!(fs::read_dir(&folder).unwrap().count(), 1);
        writer.reset();
        assert!(writer.transcript().is_none() && writer.last_error().is_none());
    }
    #[test]
    fn summaries_and_renames_follow_the_session_pointer() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path();
        let mut writer = SessionArchiveWriter::default();
        assert!(!writer.save_summary("no transcript"));
        assert!(!writer.rename("ignored", folder));
        fs::write(folder.join("meeting.md"), "unrelated").unwrap();
        assert!(writer.save_transcript("record", folder, "meeting"));
        assert!(writer.save_summary("first"));
        assert!(writer.save_summary("second"));
        assert!(writer.rename("renamed", folder));
        assert_eq!(
            fs::read_to_string(folder.join("renamed.md")).unwrap(),
            "record"
        );
        assert_eq!(
            fs::read_to_string(folder.join("renamed 요약.md")).unwrap(),
            "# meeting 2 — 회의 요약\n\nfirst\n"
        );
        assert!(folder.join("meeting 2 요약 2.md").exists());
        assert_eq!(
            fs::read_to_string(folder.join("meeting.md")).unwrap(),
            "unrelated"
        );
        writer.reset();
        assert!(writer.save_transcript("new", folder, "renamed"));
        assert!(folder.join("renamed 2.md").exists());
    }
}
