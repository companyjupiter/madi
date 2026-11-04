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
async fn preview_latest_only_yields_to_commit_and_never_enters_archive_or_exports() {
    const PREVIEW_ENGINE: &str = r#"
print('[caps] preview-fp',flush=True)
print('[stream] ready',flush=True)
p=0;s=0;records=[]
def hold(name):
    while not (root/name).exists():time.sleep(.005)
for line in sys.stdin:
    line=line.rstrip('\n')
    if line=='FLUSH':
        records.append({'kind':'flush'});(root/'commands.json').write_text(json.dumps(records))
        print('<<FLUSH_END>>',flush=True);break
    preview=line.startswith('PREVIEW ')
    if preview:
        p+=1;path,_,forced=line[8:].partition(' %%FP ')
    else:
        s+=1;offset,path=line.split(' ',1);forced=''
    with wave.open(path,'rb') as wav:frames=wav.getnframes()
    item={'kind':'preview' if preview else 'segment','name':pathlib.Path(path).name,'frames':frames,'forced':forced}
    records.append(item)
    (root/('preview-'+str(p) if preview else 'segment-'+str(s))).write_text(json.dumps(item))
    if preview:
        hold('release-preview-'+str(p))
        print('<<PREVIEW_BEGIN>>',flush=True)
        print('SPK 0 99 1 1\n[lang] locked token 50266\n<<FLUSH_END>>',flush=True)
        print('=== WORD TIMESTAMPS ===',flush=True)
        for i,word in enumerate((forced+' '+('live tail' if p>=3 else 'ghost preview')).split()):
            print('['+str(i*.1)+'s-'+str(i*.1+.1)+'s] '+word,flush=True)
        print('<<PREVIEW_END>>',flush=True)
    else:
        if s==1:hold('release-segment-1')
        print('SPK 0 0 9 1\n=== WORD TIMESTAMPS ===',flush=True)
        print('[3.1s-3.4s] Hello\n[3.5s-3.8s] world.',flush=True)
        print('<<SEG_END>>',flush=True)
"#;
    let (root, live) = fixture(PREVIEW_ENGINE);
    let workflow = FileWorkflow::with_archive(
        Configuration {
            decoder: live.resources.executable.clone(),
            resources: live.resources,
            scratch_parent: live.scratch_parent,
        },
        Some(ArchiveSettings {
            enabled: true,
            folder: root.path().join("archive"),
        }),
        |_| {},
    )
    .unwrap();
    let (input, events, mut controls) = input();
    let mut request = request(input);
    request.settings.common.language_token = Some(50259);
    request.capture.preview_enabled = true;
    request.capture.first_segment_seconds = 4.;
    request.capture.overlap_seconds = 1.;
    workflow.start_live(request, None).await.unwrap();
    events.send(Event::Started).unwrap();
    let active = state(&workflow, |s| s.phase == ViewPhase::Recording).await;
    async fn read(path: PathBuf) -> serde_json::Value {
        timeout(Duration::from_secs(10), async {
            loop {
                if let Ok(bytes) = std::fs::read(&path)
                    && let Ok(value) = serde_json::from_slice(&bytes)
                {
                    return value;
                }
                sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap()
    }
    events.send(samples(16000)).unwrap();
    let first = read(root.path().join("preview-1")).await;
    assert_eq!(first["frames"], 16000);
    // Keep the real subprocess busy while newer capture snapshots supersede it.
    events.send(samples(16000)).unwrap();
    events.send(samples(16000)).unwrap();
    let owned = PathBuf::from(std::fs::read_to_string(root.path().join("engine-started")).unwrap());
    timeout(Duration::from_secs(10), async {
        while !owned.join("preview-0.wav").exists() {
            sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    // A published meter revision proves that the presentation owner consumed
    // the capture batch containing the newest preview before releasing decode.
    let revision = workflow.snapshot().revision;
    state(&workflow, |s| s.revision > revision).await;
    std::fs::write(root.path().join("release-preview-1"), "").unwrap();
    let second = read(root.path().join("preview-2")).await;
    assert_eq!(second["name"], "preview-0.wav");
    assert_eq!(second["frames"], 48000);
    state(&workflow, |s| s.partial == "ghost preview").await;
    assert!(workflow.snapshot().lines.is_empty());
    events.send(samples(16000)).unwrap(); // first committed job enters stdin
    events.send(samples(16000)).unwrap();
    events.send(samples(16000)).unwrap();
    timeout(Duration::from_secs(10), async {
        while !std::fs::metadata(owned.join("preview-2.wav")).is_ok_and(|m| m.len() == 96044) {
            sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    let revision = workflow.snapshot().revision;
    state(&workflow, |s| s.revision > revision).await;
    std::fs::write(root.path().join("release-preview-2"), "").unwrap();
    read(root.path().join("segment-1")).await;
    assert!(!root.path().join("preview-3").exists());
    std::fs::write(root.path().join("release-segment-1"), "").unwrap();
    let third = read(root.path().join("preview-3")).await;
    assert_eq!(third["forced"], "Hello world.");
    assert_eq!(third["name"], "preview-2.wav");
    std::fs::write(root.path().join("release-preview-3"), "").unwrap();
    state(&workflow, |s| {
        s.partial == "live tail" && !s.lines.is_empty()
    })
    .await;
    let exported = workflow
        .render_export(
            active.generation,
            crate::transcript_export::Format::Txt,
            Default::default(),
        )
        .await
        .unwrap()
        .unwrap();
    assert!(exported.contains("Hello world."));
    assert!(!exported.contains("ghost"));
    assert!(!exported.contains("live tail"));
    workflow
        .live_control(active.generation, LiveControl::Stop)
        .await
        .unwrap();
    control(&mut controls, Control::Stop).await;
    events.send(Event::Stopped).unwrap();
    let done = state(&workflow, |s| s.phase == ViewPhase::Done).await;
    assert!(done.partial.is_empty());
    assert!(done.lines.iter().all(|l| l.line.speaker != 99));
    let archived = std::fs::read_to_string(done.archive.transcript.unwrap()).unwrap();
    assert!(archived.contains("Hello world."));
    assert!(!archived.contains("ghost"));
    assert!(!archived.contains("live tail"));
    let commands = read(root.path().join("commands.json")).await;
    assert_eq!(
        commands
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["kind"].as_str().unwrap())
            .collect::<Vec<_>>(),
        [
            "preview", "preview", "segment", "preview", "segment", "flush"
        ]
    );
    workflow.shutdown().await.unwrap();
    assert!(!owned.exists());
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
