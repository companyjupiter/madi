//! Serial post-converter capture and owned WAV output. Run on a blocking worker,
//! never inside the native audio callback or on the WebView/main thread.
use madi_core::capture_stream::{CaptureStream, Configuration, Output, SAMPLE_RATE};
use std::{
    io::{self, BufWriter, Write},
    path::{Path, PathBuf},
    sync::Arc,
};
use tempfile::{NamedTempFile, TempDir};

/// A queued engine/AI job retains the directory even after capture is retired.
/// No constructor accepts arbitrary paths; dropping a lease cannot delete input files.
#[derive(Clone, Debug)]
pub struct OwnedWav {
    directory: Arc<TempDir>,
    path: PathBuf,
}
impl OwnedWav {
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn directory(&self) -> &Path {
        self.directory.path()
    }
}

#[derive(Debug)]
pub enum Event {
    Level(f32),
    Segment {
        offset: f64,
        wav: OwnedWav,
        had_speech: bool,
    },
    Preview {
        offset: f64,
        wav: OwnedWav,
    },
    /// Original committed writes log failures; previews are best-effort. The
    /// caller receives diagnostics, but no successful file/segment notification.
    WriteFailed {
        name: String,
        preview: bool,
        error: io::Error,
    },
}

pub struct CapturePipeline {
    stream: CaptureStream,
    directory: Arc<TempDir>,
}
impl CapturePipeline {
    pub fn new(configuration: Configuration, scratch_parent: &Path) -> io::Result<Self> {
        let stream = CaptureStream::new(configuration).map_err(io::Error::other)?;
        let directory = tempfile::Builder::new()
            .prefix("madi-segs-")
            .tempdir_in(scratch_parent)?;
        Ok(Self {
            stream,
            directory: Arc::new(directory),
        })
    }
    pub fn directory(&self) -> &Path {
        self.directory.path()
    }
    pub fn start(&mut self) {
        self.stream.start();
    }
    pub fn configure(&mut self, configuration: Configuration) -> Result<(), &'static str> {
        self.stream.configure(configuration)
    }
    pub fn pause(&mut self) {
        self.stream.pause();
    }
    pub fn resume(&mut self) {
        self.stream.resume();
    }
    pub fn ingest(&mut self, pcm: &[i16], microphone: bool) -> Vec<Event> {
        let output = self.stream.ingest(pcm, microphone);
        self.materialize(output)
    }
    /// Native Stopped is a prerequisite. Deliver all returned tails before FLUSH.
    pub fn stop(&mut self) -> Vec<Event> {
        let output = self.stream.stop();
        self.materialize(output)
    }
    pub fn abort(&mut self) -> Vec<Event> {
        let output = self.stream.abort();
        self.materialize(output)
    }
    fn materialize(&self, output: Vec<Output>) -> Vec<Event> {
        output
            .into_iter()
            .map(|output| {
                let (name, samples, offset, speech) = match output {
                    Output::Level(level) => return Event::Level(level),
                    Output::Segment { index, segment } => (
                        format!("seg{index:05}.wav"),
                        segment.samples,
                        segment.offset,
                        Some(segment.had_speech),
                    ),
                    Output::Preview {
                        slot,
                        offset,
                        samples,
                    } => (format!("preview-{slot}.wav"), samples, offset, None),
                };
                match self.write(&name, &samples) {
                    Ok(wav) => match speech {
                        Some(had_speech) => Event::Segment {
                            offset,
                            wav,
                            had_speech,
                        },
                        None => Event::Preview { offset, wav },
                    },
                    Err(error) => Event::WriteFailed {
                        name,
                        preview: speech.is_none(),
                        error,
                    },
                }
            })
            .collect()
    }
    fn write(&self, name: &str, samples: &[i16]) -> io::Result<OwnedWav> {
        let bytes = samples
            .len()
            .checked_mul(2)
            .and_then(|n| u32::try_from(n).ok())
            .filter(|n| n.checked_add(36).is_some())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WAV exceeds RIFF size"))?;
        let path = self.directory.path().join(name);
        let mut temporary = NamedTempFile::new_in(self.directory.path())?;
        {
            let mut output = BufWriter::new(temporary.as_file_mut());
            output.write_all(b"RIFF")?;
            output.write_all(&(bytes + 36).to_le_bytes())?;
            output.write_all(b"WAVEfmt ")?;
            output.write_all(&16_u32.to_le_bytes())?;
            output.write_all(&1_u16.to_le_bytes())?;
            output.write_all(&1_u16.to_le_bytes())?;
            output.write_all(&SAMPLE_RATE.to_le_bytes())?;
            output.write_all(&(SAMPLE_RATE * 2).to_le_bytes())?;
            output.write_all(&2_u16.to_le_bytes())?;
            output.write_all(&16_u16.to_le_bytes())?;
            output.write_all(b"data")?;
            output.write_all(&bytes.to_le_bytes())?;
            for sample in samples {
                output.write_all(&sample.to_le_bytes())?;
            }
            output.flush()?;
        }
        // Atomic publication mirrors Data.write(.atomic), including preview reuse.
        temporary.persist(&path).map_err(|failure| failure.error)?;
        Ok(OwnedWav {
            directory: self.directory.clone(),
            path,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[test]
    fn queued_jobs_retain_only_their_owned_directory() {
        let scratch = tempfile::tempdir().unwrap();
        let original = scratch.path().join("original.wav");
        fs::write(&original, b"original bytes").unwrap();
        let mut first = CapturePipeline::new(Configuration::default(), scratch.path()).unwrap();
        let second = CapturePipeline::new(Configuration::default(), scratch.path()).unwrap();
        let retired = first.directory().to_owned();
        assert_ne!(first.directory(), second.directory());
        first.start();
        first.ingest(&[-32768, 0, 32767], true);
        let mut output = first.stop();
        let Event::Segment { wav, .. } = output.pop().unwrap() else {
            panic!()
        };
        assert_eq!(
            &fs::read(wav.path()).unwrap()[44..],
            &[0, 128, 0, 0, 255, 127]
        );
        drop(first);
        assert!(wav.path().exists());
        drop(wav);
        assert!(!retired.exists());
        assert!(second.directory().exists());
        drop(second);
        assert_eq!(fs::read(original).unwrap(), b"original bytes");
    }
    #[test]
    fn failed_publication_emits_no_success_and_does_not_reuse_segment_index() {
        let scratch = tempfile::tempdir().unwrap();
        let config = Configuration {
            first_segment_seconds: 0.001,
            segment_seconds: 0.001,
            ..Configuration::default()
        };
        let mut capture = CapturePipeline::new(config, scratch.path()).unwrap();
        fs::create_dir(capture.directory().join("seg00000.wav")).unwrap();
        capture.start();
        let output = capture.ingest(&[1000; 32], true);
        assert!(matches!(
            &output[1],
            Event::WriteFailed { preview: false, .. }
        ));
        assert!(
            matches!(&output[2], Event::Segment { wav, .. } if wav.path().ends_with("seg00001.wav"))
        );
        assert_eq!(fs::read_dir(capture.directory()).unwrap().count(), 2);
    }
    #[test]
    fn preview_files_rotate_three_slots_and_abort_cannot_write_a_tail() {
        let scratch = tempfile::tempdir().unwrap();
        let config = Configuration {
            preview_enabled: true,
            first_segment_seconds: 10.0,
            ..Configuration::default()
        };
        let mut capture = CapturePipeline::new(config, scratch.path()).unwrap();
        capture.start();
        let mut names = Vec::new();
        for _ in 0..4 {
            for event in capture.ingest(&[3000; 16_000], true) {
                if let Event::Preview { wav, .. } = event {
                    names.push(wav.path().file_name().unwrap().to_str().unwrap().to_owned());
                }
            }
        }
        assert_eq!(
            names,
            [
                "preview-1.wav",
                "preview-2.wav",
                "preview-0.wav",
                "preview-1.wav"
            ]
        );
        assert_eq!(fs::read_dir(capture.directory()).unwrap().count(), 3);
        assert!(matches!(capture.abort().as_slice(), [Event::Level(0.0)]));
        assert!(capture.ingest(&[1; 16_000], true).is_empty());
        assert!(capture.stop().is_empty());
    }
}
