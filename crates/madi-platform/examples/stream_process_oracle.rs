//! Differential driver for the actual native ASR process supervisor.
use madi_core::session::Session;
use madi_platform::engine_process::{EngineProcess, Event, Launch};
use madi_protocol::{stream::Output, structured::Event as J, transcribe::Event as E};
use std::{collections::BTreeMap, io, path::PathBuf};
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
#[tokio::main(flavor = "current_thread")]
async fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    let root = PathBuf::from(&args[4]);
    let fixture: serde_json::Value = serde_json::from_slice(&std::fs::read(&args[3])?)?;
    let acknowledge = fixture["batches"]
        .as_array()
        .unwrap()
        .iter()
        .any(|batch| batch["ack"] == true);
    // Identity only: this oracle tests transport, not the session effect executor.
    let mut session = Session::default();
    session.begin_live();
    let token = session.engine_token().unwrap();
    let launch = Launch {
        executable: PathBuf::from(&args[1]),
        arguments: vec![args[2].clone(), args[3].clone()],
        working_directory: root.clone(),
        environment: BTreeMap::new(),
    };
    let mut engine = EngineProcess::spawn(launch, token, &root)?;
    let mut capabilities = Vec::new();
    while let Some(message) = engine.next().await {
        assert_eq!(message.token, token);
        match message.event {
            Event::Capabilities(value) => capabilities = value,
            Event::Protocol(output) => {
                println!("{}", render(&output));
                if acknowledge && matches!(output, Output::Stdout(E::SegmentEnd)) {
                    let _ = engine.send_line("ACK");
                }
            }
            Event::IoFailure { operation, message } => {
                return Err(io::Error::other(format!("{operation}: {message}")));
            }
        }
    }
    engine.wait().await?;
    assert!(!engine.events_path().parent().unwrap().exists());
    println!("caps:{}", capabilities.join(","));
    Ok(())
}
