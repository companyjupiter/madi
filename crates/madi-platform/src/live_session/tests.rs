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
pub(crate) fn input() -> (
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
pub(crate) fn request(input: Input) -> Request {
    Request {
        recovery_settings: None,
        wall_clock: None,
        settings: LiveSettings {
            common: Default::default(),
            language_candidates: Vec::new(),
        },
        capture: capture_stream::Configuration::default(),
        input,
    }
}
pub(crate) fn fixture(script: &str) -> (tempfile::TempDir, Configuration) {
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
        wall_clock: None,
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
    timeout(Duration::from_secs(15), async {
        let mut updates = Vec::new();
        loop {
            let update = next(session).await;
            let done = predicate(&update.kind);
            updates.push(update);
            if done {
                return updates;
            }
        }
    })
    .await
    .expect("expected live event; clock ticks do not extend the deadline")
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
async fn preview_transport_checks_language_committed_backlog_pause_run_root_and_capability() {
    for forced_capability in [true, false] {
        let (root, configuration) = fixture(
        &r#"
print('[caps] preview-fp',flush=True)
print('[stream] ready',flush=True)
p=0;segments=0
for line in sys.stdin:
    line=line.rstrip('\n')
    if line=='FLUSH':print('<<FLUSH_END>>',flush=True);break
    if line.startswith('PREVIEW '):
        p+=1;(root/('command-'+str(p))).write_text(line)
        while not (root/('release-preview-'+str(p))).exists():time.sleep(.005)
        print('<<PREVIEW_BEGIN>>\n=== WORD TIMESTAMPS ===\n[0s-1s] ephemeral\n<<PREVIEW_END>>',flush=True)
    else:
        segments+=1
        print('[lang] locked token 50259',flush=True)
        while not (root/'release-segment').exists():time.sleep(.005)
        if segments==2:
            (root/'retry-started').write_text('ready',encoding='utf-8')
            while not (root/'release-retry').exists():time.sleep(.005)
        print('<<SEG_END>>',flush=True)
"#.replace("print('[caps] preview-fp',flush=True)",if forced_capability {"print('[caps] preview-fp',flush=True)"}else{""}),
    );
        let mut session = LiveSession::new(configuration).unwrap();
        let (input, events, mut controls) = input();
        let mut request = request(input);
        request.capture.preview_enabled = true;
        request.capture.first_segment_seconds = 4.;
        let run = session.start(request).await.unwrap().unwrap();
        events.send(CaptureEvent::Started).unwrap();
        until(&mut session, |k| matches!(k, UpdateKind::RecordingStarted)).await;
        events.send(samples(16000, 4000)).unwrap();
        let updates = until(&mut session, |k| matches!(k, UpdateKind::Preview { .. })).await;
        let wav = updates
            .into_iter()
            .find_map(|u| {
                if let UpdateKind::Preview { wav, .. } = u.kind {
                    Some(wav)
                } else {
                    None
                }
            })
            .unwrap();
        assert!(
            !session
                .preview(run, wav.clone(), String::new())
                .await
                .unwrap(),
            "auto language must lock first"
        );
        events.send(samples(48000, 4000)).unwrap();
        until(&mut session, |k| {
            matches!(
                k,
                UpdateKind::Output(Output::Stdout(transcribe::Event::LanguageDetected(_)))
            )
        })
        .await;
        assert!(
            !session
                .preview(run, wav.clone(), String::new())
                .await
                .unwrap(),
            "committed decode retains priority after language lock"
        );
        std::fs::write(root.path().join("release-segment"), "").unwrap();
        until(&mut session, |k| {
            matches!(
                k,
                UpdateKind::Output(Output::Stdout(transcribe::Event::SegmentEnd))
            )
        })
        .await;
        marker(&root.path().join("retry-started")).await;
        assert!(
            !session
                .preview(run, wav.clone(), String::new())
                .await
                .unwrap(),
            "an empty speech segment's retry retains committed priority"
        );
        std::fs::write(root.path().join("release-retry"), b"go").unwrap();
        until(&mut session, |k| {
            matches!(
                k,
                UpdateKind::Coverage {
                    segments_in_flight: 0,
                    ..
                }
            )
        })
        .await;
        assert!(
            !session
                .preview(RunId(run.0 + 1), wav.clone(), String::new())
                .await
                .unwrap()
        );
        let mut foreign =
            CapturePipeline::new(capture_stream::Configuration::default(), root.path()).unwrap();
        foreign.start();
        foreign.ingest(&[4000; 160], true);
        let foreign = foreign
            .stop()
            .into_iter()
            .find_map(|event| {
                if let PipelineEvent::Segment { wav, .. } = event {
                    Some(wav)
                } else {
                    None
                }
            })
            .unwrap();
        assert!(
            !session.preview(run, foreign, String::new()).await.unwrap(),
            "foreign owned roots must still be rejected"
        );
        assert!(
            session
                .preview(run, wav.clone(), "\u{200b}line\nsafe\u{200b}".into())
                .await
                .unwrap()
        );
        marker(&root.path().join("command-1")).await;
        assert_eq!(
            std::fs::read_to_string(root.path().join("command-1"))
                .unwrap()
                .ends_with(" %%FP line safe"),
            forced_capability
        );
        assert!(
            !session
                .preview(run, wav.clone(), String::new())
                .await
                .unwrap(),
            "one preview in flight"
        );
        session.pause(run).unwrap();
        control(&mut controls, Control::Pause).await;
        events.send(CaptureEvent::Paused).unwrap();
        until(&mut session, |k| {
            matches!(k, UpdateKind::Phase(Phase::Paused))
        })
        .await;
        std::fs::write(root.path().join("release-preview-1"), "").unwrap();
        until(&mut session, |k| {
            matches!(
                k,
                UpdateKind::Output(Output::Stdout(transcribe::Event::PreviewEnd))
            )
        })
        .await;
        assert!(
            !session
                .preview(run, wav.clone(), String::new())
                .await
                .unwrap(),
            "no paused preview submission"
        );
        session.resume(run).unwrap();
        control(&mut controls, Control::Resume).await;
        events.send(CaptureEvent::Resumed).unwrap();
        until(&mut session, |k| {
            matches!(k, UpdateKind::Phase(Phase::Recording))
        })
        .await;
        assert!(
            session
                .preview(run, wav.clone(), "bad %%FP controls".into())
                .await
                .unwrap()
        );
        marker(&root.path().join("command-2")).await;
        assert!(
            !std::fs::read_to_string(root.path().join("command-2"))
                .unwrap()
                .contains("%%FP")
        );
        std::fs::write(root.path().join("release-preview-2"), "").unwrap();
        until(&mut session, |k| {
            matches!(
                k,
                UpdateKind::Output(Output::Stdout(transcribe::Event::PreviewEnd))
            )
        })
        .await;
        session.stop(run).unwrap();
        control(&mut controls, Control::Stop).await;
        events.send(CaptureEvent::Stopped).unwrap();
        let terminal = terminal(&mut session).await;
        assert!(matches!(
            terminal.last().unwrap().kind,
            UpdateKind::Finished
        ));
        assert!(
            !session
                .preview(run, wav.clone(), String::new())
                .await
                .unwrap()
        );
        session.shutdown().await.unwrap();
        let path = wav.directory().to_owned();
        drop(wav);
        assert!(!path.exists());
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

pub(crate) const COVERAGE_ENGINE: &str = r#"
import hashlib
print('[stream] ready',flush=True)
records=[];turn=0
for wire in sys.stdin:
    line=wire.rstrip('\n')
    if line=='FLUSH':
        (root/'coverage-wire.json').write_text(json.dumps(records+['FLUSH']),encoding='utf-8')
        print('<<FLUSH_END>>',flush=True)
        continue
    turn+=1
    offset,path=line.split(' ',1)
    record={'offset':float(offset),'name':pathlib.Path(path).name,'sha256':hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()}
    records.append(record)
    (root/('coverage-turn-'+str(turn))).write_text(json.dumps(record),encoding='utf-8')
    # Preview words AND its fake segment boundary must not satisfy/pop W1 jobs.
    if turn==1:print('<<PREVIEW_BEGIN>>\n=== WORD TIMESTAMPS ===\n[0s-0.1s] ghost\n<<SEG_END>>\n<<PREVIEW_END>>',flush=True)
    while not (root/('coverage-release-'+str(turn))).exists():
        if (root/'coverage-crash').exists():sys.exit(7)
        time.sleep(.005)
    if turn==2 and (root/'coverage-recover').exists():
        print('=== WORD TIMESTAMPS ===',flush=True)
        print(f'[{offset}s-{float(offset)+.5}s] Recovered. «conf 0.99»',flush=True)
    print('<<SEG_END>>',flush=True)
"#;
pub(crate) fn coverage_request(capture: Input) -> Request {
    let mut value = request(capture);
    value.capture.segment_seconds = 1.0;
    value.capture.first_segment_seconds = 1.0;
    value.capture.overlap_seconds = 0.0;
    value
}
pub(crate) async fn coverage_marker(path: &Path) {
    marker(path).await;
}
pub(crate) fn coverage_release(root: &Path, turn: usize) {
    std::fs::write(root.join(format!("coverage-release-{turn}")), b"go").unwrap();
}

#[tokio::test]
async fn coverage_retries_same_owned_audio_once_and_excludes_preview_and_silence() {
    for (had_speech, recovered) in [(true, true), (true, false), (false, false)] {
        let (root, configuration) = fixture(COVERAGE_ENGINE);
        if recovered {
            std::fs::write(root.path().join("coverage-recover"), b"yes").unwrap();
        }
        let original = root.path().join("original.wav");
        std::fs::write(&original, b"unchanged caller input").unwrap();
        let mut session = LiveSession::new(configuration).unwrap();
        let (capture, events, mut controls) = input();
        let run = session
            .start(coverage_request(capture))
            .await
            .unwrap()
            .unwrap();
        events.send(CaptureEvent::Started).unwrap();
        until(&mut session, |e| matches!(e, UpdateKind::RecordingStarted)).await;
        events
            .send(samples(16000, if had_speech { 4000 } else { 0 }))
            .unwrap();
        let first = until(&mut session, |e| matches!(e, UpdateKind::Segment { .. })).await;
        let wav = first
            .iter()
            .find_map(|e| {
                if let UpdateKind::Segment {
                    wav,
                    had_speech: actual,
                    ..
                } = &e.kind
                {
                    assert_eq!(*actual, had_speech);
                    Some(wav.clone())
                } else {
                    None
                }
            })
            .unwrap();
        let before = std::fs::read(wav.path()).unwrap();
        let dir = wav.directory().to_owned();
        marker(&root.path().join("coverage-turn-1")).await;
        until(&mut session, |e| {
            matches!(
                e,
                UpdateKind::Output(Output::Stdout(transcribe::Event::PreviewEnd))
            )
        })
        .await;
        coverage_release(root.path(), 1);
        if had_speech {
            marker(&root.path().join("coverage-turn-2")).await;
            let read = |n| {
                serde_json::from_slice::<serde_json::Value>(
                    &std::fs::read(root.path().join(format!("coverage-turn-{n}"))).unwrap(),
                )
                .unwrap()
            };
            assert_eq!(
                read(1),
                read(2),
                "retry must reuse offset, immutable path and exact bytes"
            );
            session.pause(run).unwrap();
            control(&mut controls, Control::Pause).await;
            events.send(CaptureEvent::Paused).unwrap();
            coverage_release(root.path(), 2);
        }
        let finished_job = until(&mut session, |e| {
            matches!(
                e,
                UpdateKind::Coverage {
                    segments_in_flight: 0,
                    ..
                }
            )
        })
        .await;
        let gaps = finished_job
            .iter()
            .find_map(|e| {
                if let UpdateKind::Coverage {
                    segments_in_flight: 0,
                    gaps,
                } = &e.kind
                {
                    Some(gaps.clone())
                } else {
                    None
                }
            })
            .unwrap();
        assert_eq!(
            gaps,
            if had_speech && !recovered {
                vec![0.]
            } else {
                vec![]
            }
        );
        session.stop(run).unwrap();
        control(&mut controls, Control::Stop).await;
        events.send(CaptureEvent::Stopped).unwrap();
        let done = terminal(&mut session).await;
        assert!(done.iter().any(|e| matches!(e.kind, UpdateKind::Finished)));
        let wire: serde_json::Value =
            serde_json::from_slice(&std::fs::read(root.path().join("coverage-wire.json")).unwrap())
                .unwrap();
        assert_eq!(
            wire.as_array().unwrap().len(),
            if had_speech { 3 } else { 2 }
        );
        assert_eq!(std::fs::read(wav.path()).unwrap(), before);
        session.reset().await.unwrap();
        assert!(wav.path().exists());
        drop(first);
        drop(finished_job);
        drop(done);
        drop(wav);
        assert!(!dir.exists());
        session.shutdown().await.unwrap();
        assert_eq!(std::fs::read(original).unwrap(), b"unchanged caller input");
        assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
    }
}

#[tokio::test]
async fn coverage_backlog_marks_gap_without_refeeding_past_later_audio() {
    let (root, configuration) = fixture(COVERAGE_ENGINE);
    std::fs::write(root.path().join("coverage-recover"), b"yes").unwrap();
    let mut session = LiveSession::new(configuration).unwrap();
    let (capture, events, mut controls) = input();
    let run = session
        .start(coverage_request(capture))
        .await
        .unwrap()
        .unwrap();
    events.send(CaptureEvent::Started).unwrap();
    until(&mut session, |e| matches!(e, UpdateKind::RecordingStarted)).await;
    events.send(samples(32000, 4000)).unwrap();
    let queued = until(&mut session, |e| {
        matches!(
            e,
            UpdateKind::Coverage {
                segments_in_flight: 2,
                ..
            }
        )
    })
    .await;
    marker(&root.path().join("coverage-turn-1")).await;
    coverage_release(root.path(), 1);
    let gap = until(
        &mut session,
        |e| matches!(e,UpdateKind::Coverage{segments_in_flight:1,gaps} if gaps==&[0.]),
    )
    .await;
    marker(&root.path().join("coverage-turn-2")).await;
    let second: serde_json::Value =
        serde_json::from_slice(&std::fs::read(root.path().join("coverage-turn-2")).unwrap())
            .unwrap();
    assert_eq!(second["offset"], 1.0);
    coverage_release(root.path(), 2);
    until(
        &mut session,
        |e| matches!(e,UpdateKind::Coverage{segments_in_flight:0,gaps} if gaps==&[0.]),
    )
    .await;
    session.stop(run).unwrap();
    control(&mut controls, Control::Stop).await;
    events.send(CaptureEvent::Stopped).unwrap();
    let done = terminal(&mut session).await;
    assert!(done.iter().any(|e| matches!(e.kind, UpdateKind::Finished)));
    let wire: serde_json::Value =
        serde_json::from_slice(&std::fs::read(root.path().join("coverage-wire.json")).unwrap())
            .unwrap();
    assert_eq!(wire.as_array().unwrap().len(), 3);
    session.reset().await.unwrap();
    drop(queued);
    drop(gap);
    drop(done);
    session.shutdown().await.unwrap();
    assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
}

#[tokio::test]
async fn coverage_pending_retry_is_retired_by_stop_reset_or_engine_failure() {
    for action in ["stop", "reset", "crash"] {
        let (root, configuration) = fixture(COVERAGE_ENGINE);
        let mut session = LiveSession::new(configuration).unwrap();
        let (capture, events, mut controls) = input();
        let run = session
            .start(coverage_request(capture))
            .await
            .unwrap()
            .unwrap();
        events.send(CaptureEvent::Started).unwrap();
        until(&mut session, |e| matches!(e, UpdateKind::RecordingStarted)).await;
        events.send(samples(16000, 4000)).unwrap();
        let first = until(&mut session, |e| matches!(e, UpdateKind::Segment { .. })).await;
        let wav = first
            .iter()
            .find_map(|e| match &e.kind {
                UpdateKind::Segment { wav, .. } => Some(wav.clone()),
                _ => None,
            })
            .unwrap();
        let dir = wav.directory().to_owned();
        marker(&root.path().join("coverage-turn-1")).await;
        if action == "stop" {
            // Enter flushing before the first boundary. W1 must still run;
            // the native capture acknowledgement and FLUSH come afterward.
            session.stop(run).unwrap();
            control(&mut controls, Control::Stop).await;
        }
        coverage_release(root.path(), 1);
        marker(&root.path().join("coverage-turn-2")).await;
        assert!(wav.path().exists());
        match action {
            "stop" => {
                events.send(CaptureEvent::Stopped).unwrap();
                coverage_release(root.path(), 2);
                let done = terminal(&mut session).await;
                assert!(matches!(done.last().unwrap().kind, UpdateKind::Finished));
                assert!(done.iter().any(|u| matches!(&u.kind,
                    UpdateKind::Coverage {segments_in_flight:0, gaps} if gaps == &[0.])));
                session.reset().await.unwrap();
            }
            "reset" => {
                let native = tokio::spawn(async move {
                    control(&mut controls, Control::Stop).await;
                    events.send(CaptureEvent::Stopped).unwrap();
                });
                session.reset().await.unwrap();
                native.await.unwrap();
                let reset = until(&mut session, |e| {
                    matches!(e, UpdateKind::Phase(Phase::Idle))
                })
                .await;
                assert!(reset.iter().any(|u| matches!(&u.kind,
                    UpdateKind::Coverage {segments_in_flight:0, gaps} if gaps.is_empty())));
                assert!(!reset.iter().any(|u| matches!(u.kind, UpdateKind::Finished)));
            }
            _ => {
                std::fs::write(root.path().join("coverage-crash"), b"go").unwrap();
                control(&mut controls, Control::Stop).await;
                events.send(CaptureEvent::Stopped).unwrap();
                let failed = terminal(&mut session).await;
                assert!(matches!(failed.last().unwrap().kind, UpdateKind::Failed));
                assert!(failed.iter().any(|u| matches!(&u.kind,
                    UpdateKind::Coverage {segments_in_flight:0, gaps} if gaps.is_empty())));
                assert!(
                    !failed
                        .iter()
                        .any(|u| matches!(u.kind, UpdateKind::Finished))
                );
                session.reset().await.unwrap();
            }
        }
        // External audio leases survive teardown; pending retry ownership does
        // not leak a private directory after the last consumer releases it.
        assert!(wav.path().exists());
        drop(first);
        drop(wav);
        assert!(!dir.exists());
        session.shutdown().await.unwrap();
        assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
    }
}

#[tokio::test]
async fn coverage_retry_after_queued_flush_does_not_reorder_or_extend_completion() {
    let (root, configuration) = fixture(
        r#"
import hashlib
print('[stream] ready',flush=True)
first=sys.stdin.readline().rstrip('\n')
offset,path=first.split(' ',1)
before=hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
(root/'first-read').write_text('ready',encoding='utf-8')
assert sys.stdin.readline().strip()=='FLUSH'
# Original stop queues FLUSH independently of W1. Complete the first job
# afterward so its retry must remain behind FLUSH on the same wire.
print('<<SEG_END>>',flush=True)
assert sys.stdin.readline().rstrip('\n')==first
assert hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()==before
(root/'retry-after-flush').write_text('same WAV',encoding='utf-8')
print('<<FLUSH_END>>',flush=True)
# These queued events belong to the retired engine, not a later session.
print('=== WORD TIMESTAMPS ===\n[0s-1s] Late. «conf 0.99»\n<<SEG_END>>',flush=True)
time.sleep(60)
"#,
    );
    let mut session = LiveSession::new(configuration).unwrap();
    let (capture, events, mut controls) = input();
    let run = session
        .start(coverage_request(capture))
        .await
        .unwrap()
        .unwrap();
    events.send(CaptureEvent::Started).unwrap();
    until(&mut session, |e| matches!(e, UpdateKind::RecordingStarted)).await;
    events.send(samples(16000, 4000)).unwrap();
    let first = until(&mut session, |e| matches!(e, UpdateKind::Segment { .. })).await;
    marker(&root.path().join("first-read")).await;
    session.stop(run).unwrap();
    control(&mut controls, Control::Stop).await;
    events.send(CaptureEvent::Stopped).unwrap();
    let done = terminal(&mut session).await;
    assert!(root.path().join("retry-after-flush").exists());
    assert!(matches!(done.last().unwrap().kind, UpdateKind::Finished));
    assert!(done.iter().any(|u| matches!(&u.kind,
        UpdateKind::Coverage {segments_in_flight:0, gaps} if gaps.is_empty())));
    assert!(!done.iter().any(|u| matches!(
        u.kind,
        UpdateKind::Output(Output::Stdout(transcribe::Event::Word { .. }))
    )));
    session.reset().await.unwrap();
    drop(first);
    drop(done);
    session.shutdown().await.unwrap();
    assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
}

pub(crate) const HANG_ENGINE: &str = r#"
import hashlib
counter=root/'generation'
generation=int(counter.read_text(encoding='utf-8'))+1 if counter.exists() else 1
counter.write_text(str(generation),encoding='utf-8')
(root/('engine-'+str(generation))).write_text(json.dumps({'pid':os.getpid(),'language':os.environ.get('WHISPER_LANG_ID')}),encoding='utf-8')
def retired(*args):
    print('=== WORD TIMESTAMPS ===\n[99s-100s] Stale. «conf 0.99»\n<<SEG_END>>',flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM,retired)
print('[stream] ready',flush=True)
records=[]
for wire in sys.stdin:
    line=wire.rstrip('\n')
    if line=='FLUSH':
        print('SPKFIX -0.2 99 5 1',flush=True)
        print('<<FLUSH_END>>',flush=True)
        continue
    offset,path=line.split(' ',1)
    record={'offset':float(offset),'name':pathlib.Path(path).name,'sha256':hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()}
    records.append(record)
    (root/('wire-'+str(generation))).write_text(json.dumps(records),encoding='utf-8')
    if generation==1:
        if len(records)==1:
            print('SPK 0 2 2 1\n=== WORD TIMESTAMPS ===\n[0s-0.4s] Before. «conf 0.99»',flush=True)
        if len(records)==2:
            (root/'hung').write_text('ready',encoding='utf-8')
            sent=set()
            while True:
                if (root/'progress').exists() and 'progress' not in sent:
                    sent.add('progress');print('<<PREVIEW_BEGIN>>\n=== WORD TIMESTAMPS ===\n[0s-0.1s] heartbeat\n<<PREVIEW_END>>',flush=True)
                if (root/'diagnostics').exists() and 'diagnostics' not in sent:
                    sent.add('diagnostics');print('[stream] ready\n[caps] preview-fp\nnoise acknowledgement',flush=True)
                time.sleep(.005)
    else:
        print('SPK '+offset+' 2 2 1\n=== WORD TIMESTAMPS ===',flush=True)
        print('['+offset+'s-'+str(float(offset)+.4)+'s] '+('Before.' if float(offset)==0 else 'Recovered.')+' «conf 0.99»',flush=True)
        print('<<SEG_END>>',flush=True)
"#;

pub(crate) fn hang_clock() -> std::sync::Arc<std::sync::atomic::AtomicU64> {
    std::sync::Arc::new(std::sync::atomic::AtomicU64::new(1000_f64.to_bits()))
}
pub(crate) async fn advance_watchdog(clock: &std::sync::atomic::AtomicU64, now: f64) {
    clock.store(now.to_bits(), std::sync::atomic::Ordering::SeqCst);
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(5)).await;
    tokio::time::resume();
}

#[tokio::test]
async fn hang_watchdog_respects_progress_replays_owned_queue_and_preserves_paused_capture() {
    for paused in [false, true] {
        let (root, mut configuration) = fixture(HANG_ENGINE);
        let clock = hang_clock();
        configuration.wall_clock = Some(clock.clone());
        let mut session = LiveSession::new(configuration).unwrap();
        let (capture, events, mut controls) = input();
        let mut request = coverage_request(capture);
        request.recovery_settings = Some(std::sync::Arc::new(|| {
            let mut settings = LiveSettings {
                common: Default::default(),
                language_candidates: vec![],
            };
            settings.common.language_token = Some(50264);
            Ok(settings)
        }));
        let run = session.start(request).await.unwrap().unwrap();
        events.send(CaptureEvent::Started).unwrap();
        until(&mut session, |e| matches!(e, UpdateKind::RecordingStarted)).await;
        events.send(samples(32000, 4000)).unwrap();
        let initial = until(
            &mut session,
            |e| matches!(e,UpdateKind::Segment{offset,..} if *offset==1.),
        )
        .await;
        marker(&root.path().join("hung")).await;
        until(&mut session, |e| {
            matches!(
                e,
                UpdateKind::Output(Output::Stdout(transcribe::Event::Word { .. }))
            )
        })
        .await;
        if paused {
            session.pause(run).unwrap();
            control(&mut controls, Control::Pause).await;
            events.send(CaptureEvent::Paused).unwrap();
            until(&mut session, |e| {
                matches!(e, UpdateKind::Phase(Phase::Paused))
            })
            .await;
        }
        advance_watchdog(&clock, 1044.).await;
        let checked = until(&mut session, |e| {
            matches!(e, UpdateKind::WatchdogChecked(_))
        })
        .await;
        assert!(matches!(
            checked.last().unwrap().kind,
            UpdateKind::WatchdogChecked(0)
        ));
        std::fs::write(root.path().join("progress"), b"go").unwrap();
        until(&mut session, |e| {
            matches!(
                e,
                UpdateKind::Output(Output::Stdout(transcribe::Event::PreviewEnd))
            )
        })
        .await;
        advance_watchdog(&clock, 1089.).await;
        let checked = until(&mut session, |e| {
            matches!(e, UpdateKind::WatchdogChecked(_))
        })
        .await;
        assert!(matches!(
            checked.last().unwrap().kind,
            UpdateKind::WatchdogChecked(0)
        ));
        std::fs::write(root.path().join("diagnostics"), b"go").unwrap();
        until(&mut session,|e|matches!(e,UpdateKind::Output(Output::Stdout(transcribe::Event::Other(s))) if s=="noise acknowledgement")).await;
        advance_watchdog(&clock, 1090.).await;
        let checked = until(&mut session, |e| {
            matches!(e, UpdateKind::WatchdogChecked(_))
        })
        .await;
        assert!(matches!(
            checked.last().unwrap().kind,
            UpdateKind::WatchdogChecked(1)
        ));
        assert!(checked.iter().any(|e| matches!(
            e.kind,
            UpdateKind::Recovery {
                attempts: 1,
                language_token: Some(50264)
            }
        )));
        let recovered = until(&mut session, |e| {
            matches!(
                e,
                UpdateKind::Coverage {
                    segments_in_flight: 0,
                    ..
                }
            )
        })
        .await;
        assert!(!recovered.iter().any(|e|matches!(&e.kind,UpdateKind::Output(Output::Stdout(transcribe::Event::Word{text,..})) if text=="Stale.")));
        assert!(
            !recovered
                .iter()
                .any(|e| matches!(e.kind, UpdateKind::RecordingStarted))
        );
        assert!(
            controls.try_recv().is_err(),
            "replacement cannot restart/resume capture"
        );
        let read = |name: &str| {
            serde_json::from_slice::<serde_json::Value>(
                &std::fs::read(root.path().join(name)).unwrap(),
            )
            .unwrap()
        };
        assert_eq!(
            read("wire-1"),
            read("wire-2"),
            "same offsets, paths, bytes and order"
        );
        assert_eq!(read("engine-2")["language"], "50264");
        advance_watchdog(&clock, 1200.).await;
        let checked = until(&mut session, |e| {
            matches!(e, UpdateKind::WatchdogChecked(_))
        })
        .await;
        assert!(
            matches!(checked.last().unwrap().kind, UpdateKind::WatchdogChecked(1)),
            "empty queue cannot restart"
        );
        session.stop(run).unwrap();
        control(&mut controls, Control::Stop).await;
        events.send(CaptureEvent::Stopped).unwrap();
        let done = terminal(&mut session).await;
        assert!(matches!(done.last().unwrap().kind, UpdateKind::Finished));
        session.reset().await.unwrap();
        drop(initial);
        drop(recovered);
        drop(done);
        session.shutdown().await.unwrap();
        assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
    }
}

#[tokio::test]
async fn hang_watchdog_replacement_spawn_failure_retires_capture_and_pending_audio() {
    let (root, mut configuration) = fixture(HANG_ENGINE);
    let clock = hang_clock();
    configuration.wall_clock = Some(clock.clone());
    let link = root.path().join("replaceable-python");
    std::os::unix::fs::symlink(&configuration.resources.executable, &link).unwrap();
    configuration.resources.executable = link.clone();
    let mut session = LiveSession::new(configuration).unwrap();
    let (capture, events, mut controls) = input();
    session.start(coverage_request(capture)).await.unwrap();
    events.send(CaptureEvent::Started).unwrap();
    until(&mut session, |e| matches!(e, UpdateKind::RecordingStarted)).await;
    events.send(samples(32000, 4000)).unwrap();
    marker(&root.path().join("hung")).await;
    until(&mut session, |e| {
        matches!(
            e,
            UpdateKind::Output(Output::Stdout(transcribe::Event::Word { .. }))
        )
    })
    .await;
    std::fs::remove_file(link).unwrap();
    advance_watchdog(&clock, 1046.).await;
    control(&mut controls, Control::Stop).await;
    events.send(CaptureEvent::Stopped).unwrap();
    let failed = terminal(&mut session).await;
    assert!(matches!(failed.last().unwrap().kind, UpdateKind::Failed));
    assert!(
        failed
            .iter()
            .any(|e| matches!(e.kind, UpdateKind::Recovery { attempts: 1, .. }))
    );
    assert!(failed.iter().any(|e| matches!(
        e.kind,
        UpdateKind::Coverage {
            segments_in_flight: 0,
            ..
        }
    )));
    session.reset().await.unwrap();
    drop(failed);
    session.shutdown().await.unwrap();
    assert_eq!(crate::file_session::tests::scratch_count(root.path()), 0);
}
