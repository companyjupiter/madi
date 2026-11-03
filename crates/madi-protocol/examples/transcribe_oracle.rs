use madi_protocol::transcribe::{Decoder, Event, FloatSyntax, SpeakerLabel};
use std::io::{self, Read, Write};

fn word(cursor: &mut io::Cursor<Vec<u8>>) -> io::Result<u32> {
    let mut bytes = [0; 4];
    cursor.read_exact(&mut bytes)?;
    Ok(u32::from_le_bytes(bytes))
}
fn hex(text: &str) -> String {
    text.bytes().map(|b| format!("{b:02x}")).collect()
}
fn number(value: f64) -> String {
    format!("{:016x}", value.to_bits())
}
fn speaker(kind: &str, label: SpeakerLabel) -> String {
    format!(
        "{kind}:{}:{}:{}:{}",
        number(label.time),
        label.id,
        number(label.duration),
        number(label.margin)
    )
}
fn render(event: Event) -> String {
    match event {
        Event::Ready => "ready".into(),
        Event::WordSectionBegin => "words".into(),
        Event::Word {
            t0,
            t1,
            text,
            confidence,
        } => format!(
            "word:{}:{}:{}:{}",
            number(t0),
            number(t1),
            number(confidence),
            hex(&text)
        ),
        Event::Speaker(label) => speaker("speaker", label),
        Event::SpeakerFix(label) => speaker("fix", label),
        Event::SpeakerOverlap(label) => speaker("overlap", label),
        Event::SpeakerOverlapReset => "overlap-reset".into(),
        Event::SpeakerName { id, name } => format!("name:{id}:{}", hex(&name)),
        Event::FlushEnd => "flush".into(),
        Event::ProgressTotal(n) => format!("total:{n}"),
        Event::ProgressChunk(n) => format!("chunk:{n}"),
        Event::LanguageDetected(n) => format!("language:{n}"),
        Event::Partial { t0, text } => format!("partial:{}:{}", number(t0), hex(&text)),
        Event::SegmentEnd => "segment".into(),
        Event::PreviewBegin => "preview-begin".into(),
        Event::PreviewEnd => "preview-end".into(),
        Event::PreviewPartial(text) => format!("preview-partial:{}", hex(&text)),
        Event::PreviewWord { t0, t1, text } => {
            format!("preview-word:{}:{}:{}", number(t0), number(t1), hex(&text))
        }
        Event::Other(text) => format!("other:{}", hex(&text)),
    }
}
fn main() -> io::Result<()> {
    let mut input = Vec::new();
    io::stdin().read_to_end(&mut input)?;
    let mut input = io::Cursor::new(input);
    let mut output = io::BufWriter::new(io::stdout().lock());
    for case in 0..word(&mut input)? {
        let syntax = if std::env::args().any(|arg| arg == "--legacy-float-syntax") {
            FloatSyntax::LegacySwift
        } else {
            FloatSyntax::CurrentSwift
        };
        let mut decoder = Decoder::with_float_syntax(syntax);
        for line in 0..word(&mut input)? {
            let mut bytes = vec![0; word(&mut input)? as usize];
            input.read_exact(&mut bytes)?;
            let text = std::str::from_utf8(&bytes).map_err(io::Error::other)?;
            writeln!(output, "{case}:{line}:{}", render(decoder.decode(text)))?;
        }
    }
    Ok(())
}
