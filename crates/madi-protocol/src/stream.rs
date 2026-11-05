//! Ordered stdout and EVENTS_FILE delivery, independent of process/file APIs.
//! The reader callback returns bytes appended since its previous invocation.
use crate::{structured, transcribe, translate::Utf8BomPolicy};
use std::collections::BTreeSet;

#[derive(Debug, PartialEq)]
pub enum Output {
    Stdout(transcribe::Event),
    Structured(structured::Event),
    Terminated(i32),
}

#[derive(Default)]
struct Lines(Vec<u8>);
impl Lines {
    fn ingest(&mut self, bytes: &[u8]) -> Vec<Vec<u8>> {
        self.0.extend_from_slice(bytes);
        let mut lines = Vec::new();
        let mut start = 0;
        for (end, &byte) in self.0.iter().enumerate() {
            if byte == b'\n' {
                lines.push(self.0[start..end].to_vec());
                start = end + 1;
            }
        }
        self.0.drain(..start);
        lines
    }
}

pub struct EventStream {
    stdout: Lines,
    structured: Lines,
    decoder: transcribe::Decoder,
    capabilities: BTreeSet<String>,
    bom_policy: Utf8BomPolicy,
    finished: bool,
}

impl Default for EventStream {
    fn default() -> Self {
        Self::with_compatibility(
            Utf8BomPolicy::StripLeading,
            transcribe::FloatSyntax::CurrentSwift,
        )
    }
}

impl EventStream {
    pub fn with_compatibility(
        bom_policy: Utf8BomPolicy,
        float_syntax: transcribe::FloatSyntax,
    ) -> Self {
        Self {
            stdout: Lines::default(),
            structured: Lines::default(),
            decoder: transcribe::Decoder::with_float_syntax(float_syntax),
            capabilities: BTreeSet::new(),
            bom_policy,
            finished: false,
        }
    }

    pub fn capabilities(&self) -> &BTreeSet<String> {
        &self.capabilities
    }

    pub fn ingest_stdout(
        &mut self,
        bytes: &[u8],
        mut read_appended: impl FnMut() -> Vec<u8>,
    ) -> Vec<Output> {
        if self.finished {
            return Vec::new();
        }
        let mut outputs = Vec::new();
        for bytes in self.stdout.ingest(bytes) {
            let Ok(raw) = std::str::from_utf8(&bytes) else {
                continue;
            };
            let raw = self.bom_policy.apply(raw);
            if let Some(tokens) = raw.strip_prefix("[caps] ") {
                self.capabilities = tokens
                    .split(' ')
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned)
                    .collect();
                continue;
            }
            let event = self.decoder.decode(raw);
            if matches!(
                event,
                transcribe::Event::SegmentEnd | transcribe::Event::FlushEnd
            ) {
                for bytes in self.structured.ingest(&read_appended()) {
                    if let Ok(raw) = std::str::from_utf8(&bytes)
                        && let Some(event) = structured::decode(self.bom_policy.apply(raw))
                    {
                        outputs.push(Output::Structured(event));
                    }
                }
            }
            outputs.push(Output::Stdout(event));
        }
        outputs
    }

    /// Call after the OS pipe has been drained. Flush an unterminated stdout
    /// line, but do not manufacture a JSONL barrier or complete a partial JSON.
    pub fn finish(&mut self, code: i32, read_appended: impl FnMut() -> Vec<u8>) -> Vec<Output> {
        if self.finished {
            return Vec::new();
        }
        let mut outputs = if self.stdout.0.is_empty() {
            Vec::new()
        } else {
            self.ingest_stdout(b"\n", read_appended)
        };
        self.finished = true;
        outputs.push(Output::Terminated(code));
        outputs
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use transcribe::Event as E;

    #[test]
    fn every_split_preserves_tail_unicode_jsonl_barriers_and_exit_order() {
        let bytes = "[caps] preview-fp other\n=== WORD TIMESTAMPS ===\n[0s-1s] 한글 🙂\n<<SEG_END>>\n<<FLUSH_END>>".as_bytes();
        for split in 0..=bytes.len() {
            let mut stream = EventStream::default();
            let mut reads = 0;
            let mut reader = || {
                reads += 1;
                match reads {
                    1 => b"{\"t\":\"ready\"}\n{\"t\":\"flush_".to_vec(),
                    2 => b"end\"}\n{\"t\":\"ready\"}".to_vec(),
                    _ => panic!("unexpected structured read"),
                }
            };
            let mut output = stream.ingest_stdout(&bytes[..split], &mut reader);
            output.extend(stream.ingest_stdout(&bytes[split..], &mut reader));
            output.extend(stream.finish(7, &mut reader));
            assert_eq!(
                output,
                vec![
                    Output::Stdout(E::WordSectionBegin),
                    Output::Stdout(E::Word {
                        t0: 0.0,
                        t1: 1.0,
                        text: "한글 🙂".into(),
                        confidence: 1.0
                    }),
                    Output::Structured(structured::Event::Ready),
                    Output::Stdout(E::SegmentEnd),
                    Output::Structured(structured::Event::FlushEnd),
                    Output::Stdout(E::FlushEnd),
                    Output::Terminated(7)
                ],
                "split {split}"
            );
            assert!(stream.capabilities().contains("preview-fp"));
            assert!(stream.finish(0, || panic!("read after EOF")).is_empty());
            assert!(
                stream
                    .ingest_stdout(b"late\n", || panic!("read after EOF"))
                    .is_empty()
            );
            assert_eq!(reads, 2);
        }
    }

    #[test]
    fn preview_flush_is_not_a_barrier_and_invalid_utf8_is_dropped_per_line() {
        let mut stream = EventStream::default();
        let output = stream.ingest_stdout(
            b"\xff\n<<PREVIEW_BEGIN>>\n<<FLUSH_END>>\n<<PREVIEW_END>>\n",
            || panic!("preview caused a barrier"),
        );
        assert_eq!(
            output,
            vec![
                Output::Stdout(E::PreviewBegin),
                Output::Stdout(E::Other("<<FLUSH_END>>".into())),
                Output::Stdout(E::PreviewEnd)
            ]
        );
        assert_eq!(
            stream.finish(0, || panic!("exit caused a barrier")),
            vec![Output::Terminated(0)]
        );
    }
}
