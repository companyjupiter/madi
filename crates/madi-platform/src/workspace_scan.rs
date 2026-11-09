//! Workspace metadata uses the native Foundation enumeration/sorting contract.
//! Paths stay owned by the native service; UI requests identify a published row.
use serde::Serialize;
use std::{
    io,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Node {
    pub path: PathBuf,
    pub name: String,
    pub is_dir: bool,
    pub children: Option<Vec<Node>>,
    pub is_transcript: bool,
    pub is_summary: bool,
    pub modified: Option<f64>,
}
pub fn recent(nodes: &[Node]) -> Vec<&Node> {
    fn collect<'a>(nodes: &'a [Node], files: &mut Vec<&'a Node>) {
        for node in nodes {
            if let Some(children) = &node.children {
                collect(children, files);
            } else if node.is_transcript && node.modified.is_some() {
                files.push(node);
            }
        }
    }
    let mut files = Vec::new();
    collect(nodes, &mut files);
    files.sort_by(|a, b| b.modified.unwrap().total_cmp(&a.modified.unwrap()));
    files
}
pub fn scan(root: &Path) -> io::Result<Vec<Node>> {
    #[cfg(target_os = "macos")]
    {
        macos::scan(root)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = root;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "native workspace scan is not implemented on this platform",
        ))
    }
}
#[cfg(target_os = "macos")]
pub mod macos {
    use super::*;
    use objc2::{
        MainThreadMarker,
        rc::{Retained, autoreleasepool},
    };
    use objc2_foundation::{
        NSArray, NSCalendar, NSCalendarOptions, NSCalendarUnit, NSComparisonResult, NSDate,
        NSDirectoryEnumerationOptions, NSFileManager, NSFileModificationDate, NSNumber, NSString,
        NSURL, NSURLIsDirectoryKey,
    };
    use std::{ffi::CStr, os::unix::ffi::OsStrExt};

    pub fn url(path: &Path) -> io::Result<Retained<NSURL>> {
        let path = path.to_str().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "workspace path is not UTF-8")
        })?;
        Ok(NSURL::fileURLWithPath(&NSString::from_str(path)))
    }
    pub fn path(url: &NSURL) -> PathBuf {
        // Foundation retains the NUL-terminated representation until this copy.
        let bytes = unsafe { CStr::from_ptr(url.fileSystemRepresentation().as_ptr()) }.to_bytes();
        PathBuf::from(std::ffi::OsStr::from_bytes(bytes))
    }
    pub fn scan(root: &Path) -> io::Result<Vec<Node>> {
        autoreleasepool(|_| {
            let root = url(root)?;
            Ok(children(&root, 0, 4, 2000))
        })
    }
    fn children(directory: &NSURL, depth: usize, max_depth: usize, max_items: usize) -> Vec<Node> {
        if depth >= max_depth {
            return Vec::new();
        }
        let fm = NSFileManager::defaultManager();
        // Both framework keys are immutable, process-lived constants.
        let key = unsafe { NSURLIsDirectoryKey };
        let keys = NSArray::from_slice(&[key]);
        let Ok(items) = fm.contentsOfDirectoryAtURL_includingPropertiesForKeys_options_error(
            directory,
            Some(&keys),
            NSDirectoryEnumerationOptions::SkipsHiddenFiles,
        ) else {
            return Vec::new();
        };
        let mut nodes = Vec::new();
        for index in 0..items.count().min(max_items) {
            let url = items.objectAtIndex(index);
            let is_dir = url
                .resourceValuesForKeys_error(&keys)
                .ok()
                .and_then(|values| values.objectForKey(key))
                .and_then(|value| value.downcast::<NSNumber>().ok())
                .is_some_and(|value| value.boolValue());
            let name = url
                .lastPathComponent()
                .map(|name| name.to_string())
                .unwrap_or_default();
            let is_transcript = !is_dir
                && url
                    .pathExtension()
                    .is_some_and(|ext| ext.to_string().to_lowercase() == "md");
            let stem = url
                .URLByDeletingPathExtension()
                .and_then(|url| url.lastPathComponent())
                .map(|name| name.to_string())
                .unwrap_or_default();
            let modified = url
                .path()
                .and_then(|path| fm.attributesOfItemAtPath_error(&path).ok())
                .and_then(|values| values.objectForKey(unsafe { NSFileModificationDate }))
                .and_then(|value| value.downcast::<NSDate>().ok())
                .map(|date| date.timeIntervalSince1970());
            nodes.push(Node {
                path: path(&url),
                name,
                is_dir,
                children: if is_dir {
                    Some(children(&url, depth + 1, max_depth, max_items))
                } else {
                    None
                },
                is_transcript,
                is_summary: is_transcript && madi_core::workspace::is_summary_stem(&stem),
                modified,
            });
        }
        nodes.sort_by(|a, b| {
            b.is_dir.cmp(&a.is_dir).then_with(|| {
                match NSString::from_str(&a.name)
                    .localizedStandardCompare(&NSString::from_str(&b.name))
                {
                    NSComparisonResult::Ascending => std::cmp::Ordering::Less,
                    NSComparisonResult::Descending => std::cmp::Ordering::Greater,
                    _ => std::cmp::Ordering::Equal,
                }
            })
        });
        nodes
    }
    pub fn weeks_ago(date: f64, now: f64, calendar: &NSCalendar) -> i64 {
        fn start(date: f64, calendar: &NSCalendar) -> Retained<NSDate> {
            let date = NSDate::dateWithTimeIntervalSince1970(date);
            calendar
                .dateFromComponents(&calendar.components_fromDate(
                    NSCalendarUnit::YearForWeekOfYear | NSCalendarUnit::WeekOfYear,
                    &date,
                ))
                .unwrap_or(date)
        }
        calendar
            .components_fromDate_toDate_options(
                NSCalendarUnit::WeekOfYear,
                &start(date, calendar),
                &start(now, calendar),
                NSCalendarOptions::empty(),
            )
            .weekOfYear() as i64
    }
    pub fn statistics(nodes: &[Node], now: f64) -> madi_core::workspace::Stats {
        autoreleasepool(|_| {
            let calendar = NSCalendar::currentCalendar();
            let mut stats = madi_core::workspace::Stats::default();
            fn walk(
                nodes: &[Node],
                stats: &mut madi_core::workspace::Stats,
                calendar: &NSCalendar,
                now: f64,
            ) {
                for node in nodes {
                    if let Some(children) = &node.children {
                        walk(children, stats, calendar, now);
                    } else if node.is_transcript
                        && !node.is_summary
                        && let Ok(text) = std::fs::read_to_string(&node.path)
                        && let Some(parsed) = madi_core::transcript::archive::parse(&text)
                    {
                        // Imported text can contain overflowing numeric timecodes.
                        // Keep non-finite values away from native/JS formatting.
                        if parsed
                            .lines
                            .iter()
                            .any(|line| !line.start.is_finite() || !line.end.is_finite())
                        {
                            continue;
                        }
                        let date = NSFileManager::defaultManager()
                            .attributesOfItemAtPath_error(&NSString::from_str(
                                &node.path.to_string_lossy(),
                            ))
                            .ok()
                            .and_then(|attrs| attrs.objectForKey(unsafe { NSFileModificationDate }))
                            .and_then(|value| value.downcast::<NSDate>().ok())
                            .map(|date| date.timeIntervalSince1970())
                            .unwrap_or(now);
                        stats.add(&parsed.lines, weeks_ago(date, now, calendar));
                    }
                }
            }
            walk(nodes, &mut stats, &calendar, now);
            stats
        })
    }
    pub fn choose_folder(current: &Path) -> io::Result<Option<PathBuf>> {
        choose_folder_with_copy(current, None)
    }
    pub fn choose_folder_with_copy(
        current: &Path,
        copy: Option<(&str, &str)>,
    ) -> io::Result<Option<PathBuf>> {
        use objc2_app_kit::{NSModalResponseOK, NSOpenPanel};
        let mtm = MainThreadMarker::new()
            .ok_or_else(|| io::Error::other("workspace picker requires the main thread"))?;
        let panel = NSOpenPanel::openPanel(mtm);
        panel.setCanChooseDirectories(true);
        panel.setCanChooseFiles(false);
        panel.setAllowsMultipleSelection(false);
        let current = url(current)?;
        panel.setDirectoryURL(Some(&current));
        if let Some((prompt, message)) = copy {
            panel.setPrompt(Some(&NSString::from_str(prompt)));
            panel.setMessage(Some(&NSString::from_str(message)));
        }
        if panel.runModal() != NSModalResponseOK {
            return Ok(None);
        }
        Ok(panel.URL().map(|url| path(&url)))
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    #[test]
    fn statistics_reads_saved_transcripts_excludes_summaries_and_refreshes_modification_dates() {
        let root = tempfile::tempdir().unwrap();
        let saved = root.path().join("meeting.md");
        let body = "- **[00:01] Speaker 0** one two\n- **[00:03] Speaker 1** three\n";
        std::fs::write(&saved, body).unwrap();
        std::fs::write(root.path().join("meeting 요약.md"), body).unwrap();
        std::fs::write(root.path().join("not-transcript.md"), "# summary only").unwrap();
        std::fs::write(root.path().join("ignored.txt"), body).unwrap();
        let now = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1793740000);
        let file = std::fs::File::options().write(true).open(&saved).unwrap();
        file.set_times(
            std::fs::FileTimes::new()
                .set_modified(now - std::time::Duration::from_secs(10 * 7 * 86400)),
        )
        .unwrap();
        let nodes = scan(root.path()).unwrap();
        let old = macos::statistics(&nodes, 1793740000.0);
        assert_eq!(old.meeting_count, 1);
        assert_eq!(old.total_words, 3);
        assert_eq!(old.speaker_sum, 2);
        assert_eq!(old.total_seconds, 3.0);
        assert_eq!(old.this_week_count, 0);
        file.set_times(std::fs::FileTimes::new().set_modified(now))
            .unwrap();
        let updated = macos::statistics(&nodes, 1793740000.0);
        assert_eq!(updated.this_week_count, 1);
        assert_eq!(updated.weekly_trend, [0, 0, 0, 0, 0, 1]);
        assert_eq!(std::fs::read_to_string(saved).unwrap(), body);
    }
}
