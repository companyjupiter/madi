use madi_protocol::structured::{DuplicateKeys, Event, decode_with_duplicate_policy};
use std::io::{self, Read, Write};
fn word(cursor: &mut io::Cursor<Vec<u8>>) -> io::Result<u32> {
    let mut bytes = [0; 4];
    cursor.read_exact(&mut bytes)?;
    Ok(u32::from_le_bytes(bytes))
}
fn h(s: &str) -> String {
    s.bytes().map(|b| format!("{b:02x}")).collect()
}
fn n(d: f64) -> String {
    format!("{:016x}", d.to_bits())
}
fn render(event: Option<Event>) -> String {
    match event {
        None => "nil".into(),
        Some(Event::Meta {
            model,
            language,
            sample_rate,
            version,
        }) => format!("meta:{}:{language}:{sample_rate}:{version}", h(&model)),
        Some(Event::Ready) => "ready".into(),
        Some(Event::Partial { t0, text }) => format!("partial:{}:{}", n(t0), h(&text)),
        Some(Event::Word {
            t0,
            t1,
            confidence,
            speaker,
            text,
        }) => format!(
            "word:{}:{}:{}:{speaker}:{}",
            n(t0),
            n(t1),
            n(confidence),
            h(&text)
        ),
        Some(Event::SpeakerSegment { t0, speaker, text }) => {
            format!("speaker:{}:{speaker}:{}", n(t0), h(&text))
        }
        Some(Event::Segment(s)) => [
            "seg".into(),
            s.index.to_string(),
            n(s.t0),
            n(s.t1),
            n(s.avg_logprob),
            h(&s.fallback),
            n(s.tokens_per_second),
            n(s.encoder_ms),
            n(s.decoder_ms),
            s.passes.to_string(),
            s.dropped.to_string(),
            h(&s.text),
            s.bias_hits
                .iter()
                .map(|s| h(s))
                .collect::<Vec<_>>()
                .join(","),
        ]
        .join(":"),
        Some(Event::Diarization {
            speakers,
            silhouette,
            separation,
            tau,
            segments,
        }) => format!(
            "diar:{speakers}:{}:{}:{}:{segments}",
            n(silhouette),
            n(separation),
            n(tau)
        ),
        Some(Event::SegmentEnd) => "segment".into(),
        Some(Event::FlushEnd) => "flush".into(),
        Some(Event::Unknown(t)) => format!("unknown:{}", h(&t)),
    }
}
fn main() -> io::Result<()> {
    let mut input = Vec::new();
    io::stdin().read_to_end(&mut input)?;
    let mut input = io::Cursor::new(input);
    let mut output = io::BufWriter::new(io::stdout().lock());
    for index in 0..word(&mut input)? {
        let mut bytes = vec![0; word(&mut input)? as usize];
        input.read_exact(&mut bytes)?;
        let text = std::str::from_utf8(&bytes).map_err(io::Error::other)?;
        writeln!(
            output,
            "{index}:{}",
            render(decode_with_duplicate_policy(
                text,
                if std::env::args().any(|a| a == "--last-duplicate-key") {
                    DuplicateKeys::KeepLast
                } else {
                    DuplicateKeys::KeepFirst
                }
            ))
        )?;
    }
    Ok(())
}
