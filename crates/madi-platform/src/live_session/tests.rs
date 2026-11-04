use super::*;
use std::path::Path;
use tokio::time::{sleep, timeout};

/// A controllable native boundary; the engine and WAV I/O are real. The same
/// executor is exercised without permission prompts or a test-thread main loop.
pub struct Scripted {
    pub(super) events: Option<mpsc::UnboundedReceiver<CaptureEvent>>,
    pub(super) controls: mpsc::UnboundedSender<Control>,
}
impl Scripted {
    pub(super) fn take(&mut self) -> Self {
        Self {
            events: Some(self.events.take().unwrap()),
            controls: self.controls.clone(),
        }
    }
}
fn input() -> (
    Input,
    mpsc::UnboundedSender<CaptureEvent>,
    mpsc::UnboundedReceiver<Control>,
) {
    let (send, events) = mpsc::unbounded_channel();
    let (controls, receive) = mpsc::unbounded_channel();
    (
        Input::Scripted(Scripted {
            events: Some(events),
            controls,
        }),
        send,
        receive,
    )
}
fn request(input: Input) -> Request {
    Request {
        settings: LiveSettings {
            common: Default::default(),
            language_candidates: Vec::new(),
        },
        capture: capture_stream::Configuration::default(),
        input,
    }
}
fn fixture(script: &str) -> (tempfile::TempDir, Configuration) {
    let root = tempfile::tempdir().unwrap();
    let output = std::process::Command::new(
        std::env::var_os("MADI_TEST_PYTHON").unwrap_or_else(|| "python3".into()),
    )
    .args(["-c", "import sys;print(sys.executable)"])
    .output()
    .unwrap();
    assert!(output.status.success());
    let python = PathBuf::from(String::from_utf8(output.stdout).unwrap().trim());
    let model = root.path().join("live fixture.py");
    std::fs::write(
        &model,
        format!(
            r#"import json,os,pathlib,signal,sys,time,wave
sys.stdout.reconfigure(encoding='utf-8')
root=pathlib.Path(__file__).parent
owned=pathlib.Path(os.environ['STREAM_WAV_ROOTS'])
assert owned.is_dir() and os.environ['STREAM']=='1' and 'APP_FILE' not in os.environ
assert sys.argv[1]=='/dev/null'
(root/'engine-started').write_text(str(owned))
{script}
"#
        ),
    )
    .unwrap();
    let configuration = Configuration {
        resources: Resources {
            executable: python,
            model,
            bpe: root.path().join("unused.bpe"),
            assets: root.path().to_owned(),
        },
        scratch_parent: root.path().to_owned(),
    };
    (root, configuration)
}
const SUCCESS: &str = r#"
print('[stream] ready',flush=True)
records=[]
for line in sys.stdin:
    if line.strip()=='FLUSH':
        assert records
        (root/'stdin.json').write_text(json.dumps(records+['FLUSH']))
        with open(os.environ['EVENTS_FILE'],'w',encoding='utf-8') as out:
            out.write(json.dumps({'t':'seg','idx':0,'t0':0,'t1':1,'text':'kept live tail 한글'})+'\n')
        print('<<FLUSH_END>>',flush=True)
        break
    offset,path=line.rstrip('\n').split(' ',1)
    path=pathlib.Path(path)
    assert path.parent.resolve()==owned and path.exists()
    with wave.open(str(path),'rb') as wav:
        assert wav.getframerate()==16000 and wav.getnchannels()==1
        records.append({'offset':float(offset),'name':path.name,'frames':wav.getnframes(),'samples':list(wav.readframes(wav.getnframes()))})
    print('<<SEG_END>>',flush=True)
"#;
async fn next(session: &mut LiveSession) -> Update {
    timeout(Duration::from_secs(10), session.next())
        .await
        .unwrap()
        .expect("live session closed early")
}
async fn until(session: &mut LiveSession, predicate: impl Fn(&UpdateKind) -> bool) -> Vec<Update> {
    let mut updates = Vec::new();
    loop {
        let update = next(session).await;
        let done = predicate(&update.kind);
        updates.push(update);
        if done {
            return updates;
        }
    }
}
async fn terminal(session: &mut LiveSession) -> Vec<Update> {
    until(session, |kind| {
        matches!(
            kind,
            UpdateKind::Finished | UpdateKind::Failed | UpdateKind::Fault(_)
        )
    })
    .await
}
async fn control(controls: &mut mpsc::UnboundedReceiver<Control>, expected: Control) {
    assert_eq!(
        timeout(Duration::from_secs(8), controls.recv())
            .await
            .unwrap(),
        Some(expected)
    );
}
async fn marker(path: &Path) {
    timeout(Duration::from_secs(8), async {
        while !path.exists() {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
}
fn samples(count: usize, sample: i16) -> CaptureEvent {
    CaptureEvent::Samples {
        microphone: true,
        pcm: vec![sample; count],
    }
}

#[tokio::test]
async fn pause_markers_omit_only_paused_samples_and_tail_precedes_flush_with_retained_lease() {
    let (root, config) = fixture(SUCCESS);
    let original = root.path().join("original.wav");
    std::fs::write(&original, b"untouched input").unwrap();
    let mut session = LiveSession::new(config).unwrap();
    let (input, events, mut controls) = input();
    let run = session.start(request(input)).await.unwrap().unwrap();
    events.send(CaptureEvent::Started).unwrap();
    until(&mut session, |k| matches!(k, UpdateKind::RecordingStarted)).await;
    events.send(samples(1000, 1)).unwrap();
    session.pause(run).unwrap();
    control(&mut controls, Control::Pause).await;
    events.send(samples(200, 2)).unwrap(); // queued before native pause marker
    events.send(CaptureEvent::Paused).unwrap();
    events.send(samples(4000, 99)).unwrap();
    session.resume(run).unwrap();
    control(&mut controls, Control::Resume).await;
    events.send(CaptureEvent::Resumed).unwrap();
    events.send(samples(800, 3)).unwrap();
    session.stop(run).unwrap();
    control(&mut controls, Control::Stop).await;
    events.send(samples(400, 4)).unwrap(); // final queued PCM must not be discarded
    events.send(CaptureEvent::Stopped).unwrap();
    let updates = terminal(&mut session).await;
    assert!(updates.iter().all(|u| u.run == run));
    assert_eq!(
        updates
            .iter()
            .filter(|u| matches!(u.kind, UpdateKind::Finished))
            .count(),
        1
    );
    assert!(
        !updates
            .iter()
            .any(|u| matches!(u.kind, UpdateKind::Failed | UpdateKind::Fault(_)))
    );
    let wav = updates
        .iter()
        .find_map(|u| {
            if let UpdateKind::Segment { wav, .. } = &u.kind {
                Some(wav.clone())
            } else {
                None
            }
        })
        .unwrap();
    let dir = wav.directory().to_owned();
    let wire: serde_json::Value =
        serde_json::from_slice(&std::fs::read(root.path().join("stdin.json")).unwrap()).unwrap();
    assert_eq!(wire[0]["frames"], 2400);
    assert_eq!(wire[1], "FLUSH");
    let pcm = std::fs::read(wav.path()).unwrap();
    let samples: Vec<i16> = pcm[44..]
        .as_chunks::<2>()
        .0
        .iter()
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect();
    assert_eq!(
        samples,
        [vec![1; 1000], vec![2; 200], vec![3; 800], vec![4; 400]].concat()
    );
    let structured=updates.iter().position(|u|matches!(&u.kind,UpdateKind::Output(Output::Structured(madi_protocol::structured::Event::Segment(s))) if s.text=="kept live tail 한글")).unwrap();
    let finish = updates
        .iter()
        .position(|u| matches!(u.kind, UpdateKind::Finished))
        .unwrap();
    assert!(structured < finish);
    session.reset().await.unwrap();
    assert!(wav.path().exists());
    drop(updates);
    drop(wav);
    assert!(!dir.exists());
    session.shutdown().await.unwrap();
    assert_eq!(std::fs::read(original).unwrap(), b"untouched input");
    assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
}

#[tokio::test]
async fn startup_failure_never_announces_recording_or_sends_flush() {
    let (root, config) = fixture(SUCCESS);
    let mut session = LiveSession::new(config).unwrap();
    let (input, events, mut controls) = input();
    session.start(request(input)).await.unwrap();
    events
        .send(CaptureEvent::Fault("permission fixture".into()))
        .unwrap();
    events.send(CaptureEvent::Stopped).unwrap();
    let updates = terminal(&mut session).await;
    control(&mut controls, Control::Stop).await;
    assert!(matches!(updates.last().unwrap().kind, UpdateKind::Failed));
    assert!(
        !updates
            .iter()
            .any(|u| matches!(u.kind, UpdateKind::RecordingStarted | UpdateKind::Finished))
    );
    assert!(!root.path().join("stdin.json").exists());
    session.shutdown().await.unwrap();
    assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
}

#[tokio::test]
async fn interrupted_input_keeps_audio_and_finishes_through_normal_flush() {
    let (root, config) = fixture(SUCCESS);
    let mut session = LiveSession::new(config).unwrap();
    let (input, events, mut controls) = input();
    session.start(request(input)).await.unwrap();
    events.send(CaptureEvent::Started).unwrap();
    until(&mut session, |k| matches!(k, UpdateKind::RecordingStarted)).await;
    events.send(samples(1600, 3000)).unwrap();
    events
        .send(CaptureEvent::Fault("device unplugged".into()))
        .unwrap();
    control(&mut controls, Control::Stop).await;
    events.send(CaptureEvent::Stopped).unwrap();
    let updates = terminal(&mut session).await;
    assert!(
        updates
            .iter()
            .any(|u| matches!(&u.kind,UpdateKind::CaptureInterrupted(m) if m=="device unplugged"))
    );
    assert!(matches!(updates.last().unwrap().kind, UpdateKind::Finished));
    drop(updates);
    session.shutdown().await.unwrap();
    assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
}

#[tokio::test]
async fn early_clean_engine_exit_or_flush_cannot_discard_pending_native_tail() {
    for end in [
        "sys.exit(0)",
        "print('<<FLUSH_END>>',flush=True);time.sleep(60)",
    ] {
        let script = format!(
            "print('[stream] ready',flush=True)\nwhile not (root/'end-now').exists():time.sleep(.005)\n{end}"
        );
        let (root, config) = fixture(&script);
        let mut session = LiveSession::new(config).unwrap();
        let (input, events, mut controls) = input();
        let run = session.start(request(input)).await.unwrap().unwrap();
        events.send(CaptureEvent::Started).unwrap();
        until(&mut session, |k| matches!(k, UpdateKind::RecordingStarted)).await;
        session.stop(run).unwrap();
        control(&mut controls, Control::Stop).await;
        std::fs::write(root.path().join("end-now"), b"go").unwrap();
        // Second stop is cleanup after rejecting the premature engine completion.
        control(&mut controls, Control::Stop).await;
        events.send(CaptureEvent::Stopped).unwrap();
        let updates = terminal(&mut session).await;
        assert!(matches!(updates.last().unwrap().kind, UpdateKind::Failed));
        assert!(
            !updates
                .iter()
                .any(|u| matches!(u.kind, UpdateKind::Finished))
        );
        assert!(updates.iter().any(|u|matches!(&u.kind,UpdateKind::Phase(Phase::Error(Failure::Message(m))) if m.contains("before capture tail"))));
        session.shutdown().await.unwrap();
        assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
    }
}

#[tokio::test]
async fn reset_during_pending_start_drains_late_ready_and_cannot_control_the_next_run() {
    let (root, config) = fixture(SUCCESS);
    let mut session = LiveSession::new(config).unwrap();
    let (first_input, events, mut controls) = input();
    let first = session.start(request(first_input)).await.unwrap().unwrap();
    until(&mut session, |k| {
        matches!(k, UpdateKind::Phase(Phase::Ready))
    })
    .await;
    let native = tokio::spawn(async move {
        control(&mut controls, Control::Stop).await;
        events.send(CaptureEvent::Started).unwrap();
        events.send(samples(1600, 1)).unwrap();
        events.send(CaptureEvent::Stopped).unwrap();
    });
    session.reset().await.unwrap();
    native.await.unwrap();
    assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
    let (second_input, events, mut controls) = input();
    let second = session.start(request(second_input)).await.unwrap().unwrap();
    assert_ne!(first, second);
    events.send(CaptureEvent::Started).unwrap();
    until(&mut session, |k| matches!(k, UpdateKind::RecordingStarted)).await;
    session.stop(first).unwrap();
    session.pause(first).unwrap();
    events.send(samples(1600, 5)).unwrap();
    session.stop(second).unwrap();
    control(&mut controls, Control::Stop).await;
    events.send(CaptureEvent::Stopped).unwrap();
    let updates = terminal(&mut session).await;
    assert!(updates.iter().all(|u| u.run == second));
    assert!(matches!(updates.last().unwrap().kind, UpdateKind::Finished));
    drop(updates);
    session.shutdown().await.unwrap();
}

#[tokio::test]
async fn teardown_fault_is_reported_after_engine_reap_without_success() {
    let (root, config) = fixture("print('[stream] ready',flush=True)\ntime.sleep(60)");
    let mut session = LiveSession::new(config).unwrap();
    let (input, events, mut controls) = input();
    session.start(request(input)).await.unwrap();
    events.send(CaptureEvent::Started).unwrap();
    until(&mut session, |k| matches!(k, UpdateKind::RecordingStarted)).await;
    let native = tokio::spawn(async move {
        control(&mut controls, Control::Stop).await;
        events
            .send(CaptureEvent::Fault("native stop fixture".into()))
            .unwrap();
        events.send(CaptureEvent::Stopped).unwrap();
    });
    assert!(session.reset().await.is_err());
    native.await.unwrap();
    let updates = terminal(&mut session).await;
    assert!(
        matches!(&updates.last().unwrap().kind,UpdateKind::Fault(m) if m.contains("native stop fixture"))
    );
    assert!(session.shutdown().await.is_err());
    assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
}

#[tokio::test]
async fn startup_deadline_reaps_engine_without_opening_capture() {
    let (root, config) = fixture("time.sleep(60)");
    let mut session = LiveSession::new(config).unwrap();
    let (input, _events, mut controls) = input();
    session.start(request(input)).await.unwrap();
    marker(&root.path().join("engine-started")).await;
    // Process has really spawned; only the executor's clock is advanced.
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(46)).await;
    tokio::time::resume();
    let updates = terminal(&mut session).await;
    assert!(updates.iter().any(|u| matches!(
        u.kind,
        UpdateKind::Phase(Phase::Error(Failure::StartupTimeout))
    )));
    assert!(matches!(updates.last().unwrap().kind, UpdateKind::Failed));
    assert!(controls.try_recv().is_err());
    session.shutdown().await.unwrap();
    assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
}
