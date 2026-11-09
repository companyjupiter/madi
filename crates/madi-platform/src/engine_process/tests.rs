use super::*;
use madi_core::session::Session;
use madi_protocol::{structured, transcribe};
use tokio::time::timeout;

fn token() -> Token {
    let mut session = Session::default();
    session.begin_live();
    session.engine_token().unwrap()
}

fn python(script: &str, directory: &Path) -> Launch {
    Launch {
        executable: std::env::var_os("MADI_TEST_PYTHON")
            .unwrap_or_else(|| {
                if cfg!(windows) {
                    "python".into()
                } else {
                    "python3".into()
                }
            })
            .into(),
        arguments: vec!["-u".into(), "-c".into(), script.into()],
        working_directory: directory.to_owned(),
        environment: BTreeMap::new(),
    }
}

async fn next(process: &mut EngineProcess) -> Message {
    timeout(Duration::from_secs(6), process.next())
        .await
        .expect("engine event timeout")
        .expect("event stream ended early")
}

async fn drain(process: &mut EngineProcess) -> Vec<Message> {
    let mut messages = Vec::new();
    while let Some(message) = timeout(Duration::from_secs(6), process.next())
        .await
        .expect("engine drain timeout")
    {
        messages.push(message);
    }
    process.wait().await.unwrap();
    messages
}

#[tokio::test]
async fn preserves_json_barriers_unicode_tail_and_exit_then_cleans_only_owned_files() {
    let root = tempfile::tempdir().unwrap();
    let original = root.path().join("user-original.wav");
    std::fs::write(&original, b"must survive").unwrap();
    let identity = token();
    let script = r#"
import os,sys
with open(os.environ['EVENTS_FILE'],'wb',buffering=0) as f:
    raw='{"t":"partial","t0":1,"text":"안녕"}\n'.encode()
    split=raw.index('안'.encode())+1
    f.write(b'{"t":"ready"}\n'+raw[:split])
    os.write(1,b'[caps] preview-fp other\n[stream] ready\n<<SEG_END>>\n')
    assert sys.stdin.buffer.readline()==b'ACK\n'
    f.write(raw[split:]+b'{"t":"flush_end"}\n')
    os.write(1,b'<<SEG_END>>\n'*1000+b'<<FLUSH_END>>')
sys.exit(7)
"#;
    let mut launch = python(script, root.path());
    launch
        .environment
        .insert("EVENTS_FILE".into(), Some(original.clone().into()));
    let mut process = EngineProcess::spawn(launch, identity, root.path()).unwrap();
    let temporary = process.events_path().parent().unwrap().to_owned();
    let mut messages = Vec::new();
    loop {
        let message = next(&mut process).await;
        let first_barrier =
            message.event == Event::Protocol(Output::Stdout(transcribe::Event::SegmentEnd));
        messages.push(message);
        if first_barrier {
            process.send_line("ACK").unwrap();
            break;
        }
    }
    messages.extend(drain(&mut process).await);
    assert!(messages.iter().all(|m| m.token == identity));
    assert_eq!(
        messages[0].event,
        Event::Capabilities(vec!["other".into(), "preview-fp".into()])
    );
    let events: Vec<_> = messages
        .iter()
        .filter_map(|m| match &m.event {
            Event::Protocol(event) => Some(event),
            _ => None,
        })
        .collect();
    assert_eq!(events[0], &Output::Stdout(transcribe::Event::Ready));
    assert_eq!(events[1], &Output::Structured(structured::Event::Ready));
    assert_eq!(events[2], &Output::Stdout(transcribe::Event::SegmentEnd));
    assert_eq!(
        events[3],
        &Output::Structured(structured::Event::Partial {
            t0: 1.0,
            text: "안녕".into()
        })
    );
    assert_eq!(events[4], &Output::Structured(structured::Event::FlushEnd));
    assert_eq!(
        events
            .iter()
            .filter(|e| ***e == Output::Stdout(transcribe::Event::SegmentEnd))
            .count(),
        1001
    );
    assert_eq!(
        events[events.len() - 2],
        &Output::Stdout(transcribe::Event::FlushEnd)
    );
    assert_eq!(events.last(), Some(&&Output::Terminated(7)));
    assert!(
        !messages
            .iter()
            .any(|m| matches!(m.event, Event::IoFailure { .. }))
    );
    assert!(!temporary.exists());
    assert_eq!(std::fs::read(original).unwrap(), b"must survive");
}

#[tokio::test]
async fn queued_input_precedes_eof_and_protocol_injection_is_rejected() {
    let root = tempfile::tempdir().unwrap();
    let script =
        "import os,sys\nfor line in sys.stdin.buffer: os.write(1,line)\nos.write(1,b'tail')\n";
    let mut process =
        EngineProcess::spawn(python(script, root.path()), token(), root.path()).unwrap();
    for invalid in ["first\nFLUSH", "first\rFLUSH", "bad\0path"] {
        assert_eq!(
            process.send_line(invalid).unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }
    process.send_line("first").unwrap();
    process.send_line("second").unwrap();
    process.close_input();
    assert_eq!(
        process.send_line("late").unwrap_err().kind(),
        io::ErrorKind::BrokenPipe
    );
    let messages = drain(&mut process).await;
    assert_eq!(
        messages.iter().map(|m| &m.event).collect::<Vec<_>>(),
        vec![
            &Event::Protocol(Output::Stdout(transcribe::Event::Other("first".into()))),
            &Event::Protocol(Output::Stdout(transcribe::Event::Other("second".into()))),
            &Event::Protocol(Output::Stdout(transcribe::Event::Other("tail".into()))),
            &Event::Protocol(Output::Terminated(0)),
        ]
    );
}

#[tokio::test]
async fn blocked_stdin_cannot_prevent_termination_and_ignored_sigterm_escalates() {
    let root = tempfile::tempdir().unwrap();
    let script = "import os,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nos.write(1,b'[stream] ready\\n')\ntime.sleep(60)\n";
    let mut process =
        EngineProcess::spawn(python(script, root.path()), token(), root.path()).unwrap();
    assert_eq!(
        next(&mut process).await.event,
        Event::Protocol(Output::Stdout(transcribe::Event::Ready))
    );
    process.send_line(&"x".repeat(4 * 1024 * 1024)).unwrap();
    // Let the write block on the child's full pipe before cancellation.
    tokio::time::sleep(Duration::from_millis(40)).await;
    process.terminate();
    let messages = drain(&mut process).await;
    assert!(
        matches!(messages.last().map(|m| &m.event), Some(Event::Protocol(Output::Terminated(code))) if *code != 0)
    );
    assert!(!process.events_path().parent().unwrap().exists());
}

#[tokio::test]
async fn dropping_owner_reaps_child_and_removes_its_scratch_directory() {
    let root = tempfile::tempdir().unwrap();
    let mut process = EngineProcess::spawn(
        python(
            "import os,time\nos.write(1,b'[stream] ready\\n')\ntime.sleep(60)",
            root.path(),
        ),
        token(),
        root.path(),
    )
    .unwrap();
    next(&mut process).await;
    let temporary = process.events_path().parent().unwrap().to_owned();
    let task = process.task.take().unwrap();
    drop(process);
    timeout(Duration::from_secs(6), task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(!temporary.exists());
}

#[tokio::test]
async fn cancelling_wait_does_not_detach_the_completion_handle() {
    let root = tempfile::tempdir().unwrap();
    let mut process = EngineProcess::spawn(
        python(
            "import os,time\nos.write(1,b'[stream] ready\\n')\ntime.sleep(60)",
            root.path(),
        ),
        token(),
        root.path(),
    )
    .unwrap();
    next(&mut process).await;
    assert!(
        timeout(Duration::from_millis(30), process.wait())
            .await
            .is_err()
    );
    assert!(process.task.is_some());
    process.terminate();
    timeout(Duration::from_secs(6), process.wait())
        .await
        .unwrap()
        .unwrap();
    assert!(!process.events_path().parent().unwrap().exists());
    let messages = drain(&mut process).await;
    assert!(matches!(
        messages.last().map(|m| &m.event),
        Some(Event::Protocol(Output::Terminated(_)))
    ));
}

#[tokio::test]
async fn replacing_process_keeps_identity_and_cancellation_separate() {
    let root = tempfile::tempdir().unwrap();
    let script = "import os,sys\nos.write(1,b'[stream] ready\\n')\nfor line in sys.stdin.buffer: os.write(1,line)";
    let mut session = Session::default();
    session.begin_live();
    let old_token = session.engine_token().unwrap();
    let mut old =
        EngineProcess::spawn(python(script, root.path()), old_token, root.path()).unwrap();
    next(&mut old).await;
    session.reset();
    session.begin_live();
    let new_token = session.engine_token().unwrap();
    let mut new =
        EngineProcess::spawn(python(script, root.path()), new_token, root.path()).unwrap();
    next(&mut new).await;
    assert_ne!(old.events_path(), new.events_path());
    old.terminate();
    assert!(drain(&mut old).await.iter().all(|m| m.token == old_token));
    new.send_line("new engine survives").unwrap();
    new.close_input();
    let messages = drain(&mut new).await;
    assert!(messages.iter().all(|m| m.token == new_token));
    assert_eq!(
        messages[0].event,
        Event::Protocol(Output::Stdout(transcribe::Event::Other(
            "new engine survives".into()
        )))
    );
    assert_eq!(
        messages.last().unwrap().event,
        Event::Protocol(Output::Terminated(0))
    );
}

#[tokio::test]
async fn spawn_failure_does_not_leave_an_owned_directory_or_remove_originals() {
    let root = tempfile::tempdir().unwrap();
    let original = root.path().join("original.wav");
    std::fs::write(&original, b"original").unwrap();
    let mut launch = python("", root.path());
    launch.executable = root.path().join("missing-engine");
    assert!(EngineProcess::spawn(launch, token(), root.path()).is_err());
    assert_eq!(std::fs::read(original).unwrap(), b"original");
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
}

#[tokio::test]
async fn inherited_stdout_timeout_is_reported_as_failure_not_a_clean_drain() {
    let root = tempfile::tempdir().unwrap();
    let script = "import subprocess,sys\nsubprocess.Popen([sys.executable,'-c','import time;time.sleep(3)'])\n";
    let mut process =
        EngineProcess::spawn(python(script, root.path()), token(), root.path()).unwrap();
    let messages = drain(&mut process).await;
    assert!(messages.iter().any(|m| matches!(
        m.event,
        Event::IoFailure {
            operation: "drain stdout",
            ..
        }
    )));
    assert_eq!(
        messages.last().unwrap().event,
        Event::Protocol(Output::Terminated(0))
    );
    assert!(!process.events_path().parent().unwrap().exists());
}
