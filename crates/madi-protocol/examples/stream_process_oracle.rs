//! Test-only process driver. Product supervision is intentionally a separate adapter.
use madi_protocol::{
    stream::{EventStream, Output},
    structured::Event as J,
    transcribe::Event as E,
};
use std::{
    fs::File,
    io::{self, Read, Seek, SeekFrom, Write},
    path::PathBuf,
    process::{Command, Stdio},
};
fn bits(d: f64) -> String {
    format!("{:016x}", d.to_bits())
}
fn hex(s: &str) -> String {
    s.bytes().map(|b| format!("{b:02x}")).collect()
}
fn render(output: &Output) -> String {
    match output {
        Output::Stdout(E::Ready) => "ready".into(),
        Output::Stdout(E::FlushEnd) => "flush".into(),
        Output::Stdout(E::WordSectionBegin) => "words".into(),
        Output::Stdout(E::Word {
            t0,
            t1,
            text,
            confidence,
        }) => format!(
            "word:{}:{}:{}:{}",
            bits(*t0),
            bits(*t1),
            bits(*confidence),
            hex(text)
        ),
        Output::Stdout(E::SegmentEnd) => "segment".into(),
        Output::Stdout(E::ProgressTotal(count)) => format!("total:{count}"),
        Output::Stdout(E::PreviewBegin) => "preview-begin".into(),
        Output::Stdout(E::PreviewEnd) => "preview-end".into(),
        Output::Stdout(E::Other(text)) => format!("other:{}", hex(text)),
        Output::Structured(J::Ready) => "json:ready".into(),
        Output::Structured(J::FlushEnd) => "json:flush".into(),
        Output::Structured(J::Partial { t0, text }) => {
            format!("json:partial:{}:{}", bits(*t0), hex(text))
        }
        Output::Terminated(code) => format!("exit:{code}"),
        other => format!("unexpected:{other:?}"),
    }
}
fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    let events = PathBuf::from(&args[4]).join("rust.events.jsonl");
    let mut child = Command::new(&args[1])
        .arg(&args[2])
        .arg(&args[3])
        .env("EVENTS_FILE", &events)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let mut offset = 0;
    let mut read_appended = || {
        let mut fresh = Vec::new();
        if let Ok(mut file) = File::open(&events) {
            if file.seek(SeekFrom::Start(offset)).is_ok() && file.read_to_end(&mut fresh).is_ok() {
                offset += fresh.len() as u64;
            } else {
                fresh.clear();
            }
        }
        fresh
    };
    let mut stream = EventStream::default();
    let mut bytes = [0; 31];
    loop {
        let count = stdout.read(&mut bytes)?;
        if count == 0 {
            break;
        }
        for output in stream.ingest_stdout(&bytes[..count], &mut read_appended) {
            println!("{}", render(&output));
            if matches!(output, Output::Stdout(E::SegmentEnd)) {
                let _ = stdin.write_all(b"ACK\n");
            }
        }
    }
    let code = child.wait()?.code().unwrap_or(-1);
    for output in stream.finish(code, &mut read_appended) {
        println!("{}", render(&output));
    }
    println!(
        "caps:{}",
        stream
            .capabilities()
            .iter()
            .cloned()
            .collect::<Vec<_>>()
            .join(",")
    );
    Ok(())
}
