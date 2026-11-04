use super::*;
use crate::{
    audio_capture::Event,
    live_session::{
        Control,
        tests::{fixture, input, request},
    },
};
use tokio::time::{sleep, timeout};

const ENGINE: &str = r#"
print('[stream] ready',flush=True)
count=0
for line in sys.stdin:
    if line.strip()=='FLUSH':
        assert count==1
        print('<<FLUSH_END>>',flush=True)
        break
    offset,path=line.rstrip('\n').split(' ',1)
    with wave.open(path,'rb') as wav:
        (root/'frames').write_text(str(wav.getnframes()))
    count+=1
    print('SPK 0 2 5 1',flush=True)
    print('=== WORD TIMESTAMPS ===',flush=True)
    print('[0.0s-0.4s] Last «conf 0.99»',flush=True)
    print('[0.5s-0.9s] words. «conf 0.98»',flush=True)
    print('<<SEG_END>>',flush=True)
"#;
fn setup() -> (tempfile::TempDir, FileWorkflow) {
    let (root, live) = fixture(ENGINE);
    let config = Configuration {
        decoder: live.resources.executable.clone(),
        resources: live.resources,
        scratch_parent: live.scratch_parent,
    };
    let workflow = FileWorkflow::with_archive(
        config,
        Some(ArchiveSettings {
            enabled: true,
            folder: root.path().join("archive"),
        }),
        |_| {},
    )
    .unwrap();
    (root, workflow)
}
async fn state(workflow: &FileWorkflow, predicate: impl Fn(&Snapshot) -> bool) -> Snapshot {
    timeout(Duration::from_secs(10), async {
        let mut changes = workflow.owner.snapshot.clone();
        loop {
            let state = changes.borrow_and_update().clone();
            if predicate(&state) {
                return state;
            }
            changes.changed().await.expect("workflow ended early");
        }
    })
    .await
    .expect("expected live state")
}
async fn control(receive: &mut mpsc::UnboundedReceiver<Control>, expected: Control) {
    assert_eq!(
        timeout(Duration::from_secs(8), receive.recv())
            .await
            .unwrap(),
        Some(expected)
    );
}
fn samples(n: usize) -> Event {
    Event::Samples {
        microphone: true,
        pcm: vec![4000; n],
    }
}

#[tokio::test]
async fn countdown_cancel_never_spawns_and_old_controls_cannot_stop_a_replacement() {
    let (root, workflow) = setup();
    let (first, _, _) = input();
    workflow.start_live(request(first), None).await.unwrap();
    let countdown = state(&workflow, |s| {
        s.phase == ViewPhase::CountingDown { remaining: 3 }
    })
    .await;
    let generation = countdown.generation;
    let attempted_file = workflow
        .start(
            root.path().join("should-not-start.wav"),
            FileSettings::default(),
            None,
        )
        .await
        .unwrap();
    assert_eq!(attempted_file.generation, generation);
    assert!(matches!(
        attempted_file.phase,
        ViewPhase::CountingDown { .. }
    ));
    workflow
        .live_control(generation, LiveControl::CancelCountdown)
        .await
        .unwrap();
    sleep(Duration::from_millis(1100)).await;
    assert_eq!(workflow.snapshot().phase, ViewPhase::Idle);
    assert!(!root.path().join("engine-started").exists());

    let (second, events, mut controls) = input();
    workflow.start_live(request(second), None).await.unwrap();
    state(&workflow, |s| {
        matches!(s.phase, ViewPhase::CountingDown { .. })
    })
    .await;
    workflow
        .live_control(generation, LiveControl::CancelCountdown)
        .await
        .unwrap();
    assert!(matches!(
        workflow.snapshot().phase,
        ViewPhase::CountingDown { .. }
    ));
    events.send(Event::Started).unwrap();
    let active = state(&workflow, |s| s.phase == ViewPhase::Recording).await;
    assert!(active.generation > generation);
    workflow
        .live_control(generation, LiveControl::Stop)
        .await
        .unwrap();
    assert!(controls.try_recv().is_err());
    // Reset/back must not silently discard a running recording.
    assert_eq!(
        workflow.reset(active.generation).await.unwrap().phase,
        ViewPhase::Recording
    );
    events.send(samples(1000)).unwrap();
    workflow
        .live_control(active.generation, LiveControl::Stop)
        .await
        .unwrap();
    control(&mut controls, Control::Stop).await;
    events.send(Event::Stopped).unwrap();
    state(&workflow, |s| s.phase == ViewPhase::Done).await;
    workflow.shutdown().await.unwrap();
}

#[tokio::test]
async fn live_clock_pause_device_switch_and_final_archive_share_the_file_presentation_owner() {
    let (root, workflow) = setup();
    let (input, events, mut controls) = input();
    workflow.start_live(request(input), None).await.unwrap();
    events.send(Event::Started).unwrap();
    let active = state(&workflow, |s| {
        s.phase == ViewPhase::Recording && s.live.as_ref().unwrap().seconds >= 1.0
    })
    .await;
    let generation = active.generation;
    workflow
        .live_control(
            generation,
            LiveControl::InputDevice(Some("coreaudio:83".into())),
        )
        .await
        .unwrap();
    control(&mut controls, Control::InputDevice(Some(83))).await;
    assert_eq!(
        workflow.snapshot().live.unwrap().input_device.as_deref(),
        Some("coreaudio:83")
    );
    events.send(samples(1000)).unwrap();
    workflow
        .live_control(generation, LiveControl::Pause)
        .await
        .unwrap();
    control(&mut controls, Control::Pause).await;
    events.send(Event::Paused).unwrap();
    let paused = state(&workflow, |s| s.phase == ViewPhase::Paused).await;
    // RecordedSeconds follows Phase on the same event queue.
    sleep(Duration::from_millis(30)).await;
    let frozen = workflow.snapshot().live.unwrap().seconds;
    events.send(samples(5000)).unwrap();
    sleep(Duration::from_millis(1100)).await;
    assert_eq!(workflow.snapshot().live.unwrap().seconds, frozen);
    assert!(paused.live.unwrap().seconds >= 1.0);
    workflow
        .live_control(generation, LiveControl::Resume)
        .await
        .unwrap();
    control(&mut controls, Control::Resume).await;
    events.send(Event::Resumed).unwrap();
    state(&workflow, |s| s.phase == ViewPhase::Recording).await;
    workflow
        .live_control(generation, LiveControl::Stop)
        .await
        .unwrap();
    control(&mut controls, Control::Stop).await;
    events.send(samples(600)).unwrap();
    events.send(Event::Stopped).unwrap();
    let done = state(&workflow, |s| {
        s.phase == ViewPhase::Done && s.archive.transcript.is_some()
    })
    .await;
    assert_eq!(
        std::fs::read_to_string(root.path().join("frames")).unwrap(),
        "1600"
    );
    assert_eq!(
        done.lines
            .iter()
            .map(|l| l.text.as_str())
            .collect::<Vec<_>>(),
        ["Last words."]
    );
    let archive = done.archive.transcript.unwrap();
    // NSURL.fileSystemRepresentation decomposes Hangul on macOS.
    let name = archive.file_name().unwrap().to_str().unwrap();
    assert!(
        personal_vocabulary::canonically_equal(name.split(' ').next().unwrap(), "회의"),
        "unexpected live archive name: {name:?}"
    );
    assert!(
        std::fs::read_to_string(&archive)
            .unwrap()
            .contains("Last words.")
    );
    let id = done.lines[0].line.id.to_string();
    workflow
        .edit(
            generation,
            Edit::Line {
                id,
                text: "Reviewed last words.".into(),
            },
        )
        .await
        .unwrap();
    let edited = state(&workflow, |s| s.lines[0].text == "Reviewed last words.").await;
    assert_eq!(edited.generation, generation);
    workflow.reset(generation).await.unwrap();
    let reopened = workflow
        .open_archive(workflow.snapshot().generation, archive)
        .await
        .unwrap();
    assert!(reopened.live.is_none());
    assert_eq!(reopened.lines[0].text, "Last words."); // manual edits don't rewrite an owned archive until checkpoint
    workflow.shutdown().await.unwrap();
}

#[tokio::test]
async fn shutdown_waits_for_capture_tail_engine_flush_and_atomic_archive() {
    let (root, workflow) = setup();
    let (input, events, mut controls) = input();
    workflow.start_live(request(input), None).await.unwrap();
    events.send(Event::Started).unwrap();
    state(&workflow, |s| s.phase == ViewPhase::Recording).await;
    events.send(samples(1000)).unwrap();
    let quit = workflow.clone();
    let task = tokio::spawn(async move { quit.shutdown().await });
    control(&mut controls, Control::Stop).await;
    assert!(!task.is_finished());
    events.send(samples(600)).unwrap();
    events.send(Event::Stopped).unwrap();
    timeout(Duration::from_secs(10), task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let done = workflow.snapshot();
    assert_eq!(done.phase, ViewPhase::Done);
    assert!(
        std::fs::read_to_string(done.archive.transcript.unwrap())
            .unwrap()
            .contains("Last words.")
    );
    assert_eq!(
        std::fs::read_to_string(root.path().join("frames")).unwrap(),
        "1600"
    );
    let owned = std::fs::read_to_string(root.path().join("engine-started")).unwrap();
    assert!(!std::path::Path::new(&owned).exists());
}
