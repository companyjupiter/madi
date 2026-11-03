//! Binary fixture driver used only by scripts/check_translate_parser_parity.py.
use madi_protocol::translate::{Event, TranslateStreamParser, Utf8BomPolicy};
use std::io::{self, Read, Write};

fn word(cursor: &mut io::Cursor<Vec<u8>>) -> io::Result<u32> {
    let mut bytes = [0; 4];
    cursor.read_exact(&mut bytes)?;
    Ok(u32::from_le_bytes(bytes))
}

fn main() -> io::Result<()> {
    let bom_policy = if std::env::args().any(|arg| arg == "--preserve-bom") {
        Utf8BomPolicy::Preserve
    } else {
        Utf8BomPolicy::StripLeading
    };
    let mut input = Vec::new();
    io::stdin().read_to_end(&mut input)?;
    let mut cursor = io::Cursor::new(input);
    let mut out = io::BufWriter::new(io::stdout().lock());
    for case in 0..word(&mut cursor)? {
        let mut mode = [0];
        cursor.read_exact(&mut mode)?;
        let mut parser = TranslateStreamParser::with_bom_policy(mode[0] != 0, bom_policy);
        for chunk in 0..word(&mut cursor)? {
            let mut bytes = vec![0; word(&mut cursor)? as usize];
            cursor.read_exact(&mut bytes)?;
            for event in parser.ingest(&bytes) {
                let (kind, value) = match event {
                    Event::Ready => ("ready", String::new()),
                    Event::PrefixReady(slot) => ("prefix", slot.to_string()),
                    Event::Capabilities(caps) => ("caps", caps.join("\0")),
                    Event::ReplyDelta(text) => ("delta", text),
                    Event::TurnComplete(text) => ("complete", text),
                };
                write!(out, "{case}:{chunk}:{kind}:")?;
                for byte in value.bytes() {
                    write!(out, "{byte:02x}")?;
                }
                writeln!(out)?;
            }
        }
    }
    Ok(())
}
