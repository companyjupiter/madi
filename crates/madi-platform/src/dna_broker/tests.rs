use super::*;
use std::path::Path;
use tokio::time::timeout;

const ENGINE: &str = r#"
import os,sys,time,pathlib,signal
root=pathlib.Path(sys.argv[1])
assert os.environ['SOV_NSTEPS']=='512'
assert 'SOV_DEBUG' not in os.environ
with (root/'launches').open('a',encoding='utf-8') as f:f.write(str(os.getpid())+'\n')
count=len((root/'launches').read_text(encoding='utf-8').splitlines())
os.write(1,(('[caps] fp max\n' if count==1 else '[caps] max\n')+'READY\n').encode())
for raw in sys.stdin.buffer:
    line=raw.decode('utf-8').rstrip('\n')
    with (root/'commands').open('a',encoding='utf-8') as f:f.write(line+'\n')
    if line=='CRASH':sys.exit(7)
    if line.startswith('WEDGE'):
        if line=='WEDGE_IGNORE' and os.name!='nt':
            signal.signal(signal.SIGTERM,signal.SIG_IGN)
            os.write(1,b'[perf] prefill: 1 tok\nignoring')
        continue
    if line.startswith('%%PFX '):
        slot=line.split(' ')[1]
        os.write(1,('PFX_OK 99 12\nPFX_OK '+slot+' 12\n').encode())
        continue
    os.write(1,b'[perf] prefill: 1 tok\n')
    if line.startswith('BLOCK'):
        os.write(1,b'working')
        while not (root/'release').exists():time.sleep(0.005)
        result=' done'
    elif line=='LINES':result='first\nsecond'
    elif line=='EMPTY':result=''
    else:result='ok:'+line
    os.write(1,result.encode()+b'\n[perf] generation: 1 tok\n> ')
"#;

fn launch(root: &Path) -> Launch {
    Launch {
        engine: std::env::var_os("MADI_TEST_PYTHON")
            .unwrap_or_else(|| {
                if cfg!(windows) {
                    "python".into()
                } else {
                    "python3".into()
                }
            })
            .into(),
        model: root.to_owned(),
        arguments: vec!["-u".into(), "-c".into(), ENGINE.into()],
    }
}

async fn until(broker: &mut DnaBroker, mut predicate: impl FnMut(&Event) -> bool) -> Vec<Event> {
    timeout(Duration::from_secs(15), async {
        let mut events = Vec::new();
        loop {
            let event = broker.next().await.expect("broker event stream ended");
            let matched = predicate(&event);
            events.push(event);
            if matched {
                return events;
            }
        }
    })
    .await
    .expect("DNA event deadline")
}
async fn ready(broker: &mut DnaBroker, client: ClientId) -> Vec<Event> {
    until(
        broker,
        |e| matches!(e, Event::Ready { client: c, .. } if *c == client),
    )
    .await
}
async fn completed(broker: &mut DnaBroker, id: RequestId) -> Option<String> {
    let events = until(
        broker,
        |e| matches!(e, Event::Completed { request, .. } if *request == id),
    )
    .await;
    match events.last().unwrap() {
        Event::Completed { text, .. } => text.clone(),
        _ => unreachable!(),
    }
}
async fn stop(broker: &mut DnaBroker) {
    broker.shutdown();
    timeout(Duration::from_secs(8), broker.wait())
        .await
        .unwrap()
        .unwrap();
}
fn commands(root: &Path) -> Vec<String> {
    std::fs::read_to_string(root.join("commands"))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

#[tokio::test]
async fn resident_clients_share_prefixes_unicode_newline_policy_and_one_protocol_line() {
    let root = tempfile::tempdir().unwrap();
    let mut broker = DnaBroker::new().unwrap();
    let first = broker.attach(launch(root.path())).await.unwrap();
    let initial = ready(&mut broker, first).await;
    assert!(
        initial
            .iter()
            .any(|e| matches!(e,Event::Ready { capabilities, .. } if capabilities.contains("fp")))
    );
    let second = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, second).await;
    let foreign = tempfile::tempdir().unwrap();
    assert_eq!(
        broker
            .attach(launch(foreign.path()))
            .await
            .unwrap_err()
            .kind(),
        io::ErrorKind::InvalidInput
    );
    let prefix = broker
        .submit(
            first,
            Request::Prefix {
                slot: 2,
                text: " prefix\n한글\r日 ".into(),
            },
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    assert_eq!(
        completed(&mut broker, prefix).await.as_deref(),
        Some("PFX_OK")
    );
    let turn = broker
        .submit(
            second,
            Request::turn("\u{200b}Hello\n한글\r日\u{200b}"),
            Priority::LiveRail,
        )
        .await
        .unwrap();
    assert_eq!(
        completed(&mut broker, turn).await.as_deref(),
        Some("ok:Hello 한글 日")
    );
    for preserve in [false, true] {
        let id = broker
            .submit(
                second,
                Request::Turn {
                    prompt: "LINES".into(),
                    preserve_newlines: preserve,
                },
                Priority::PostSession,
            )
            .await
            .unwrap();
        assert_eq!(
            completed(&mut broker, id).await.as_deref(),
            Some(if preserve {
                "first\nsecond"
            } else {
                "first second"
            })
        );
    }
    let empty = broker
        .submit(first, Request::turn("EMPTY"), Priority::CommittedCaption)
        .await
        .unwrap();
    assert_eq!(completed(&mut broker, empty).await, None);
    assert_eq!(
        broker
            .submit(
                first,
                Request::turn("bad\0input"),
                Priority::CommittedCaption
            )
            .await
            .unwrap_err()
            .kind(),
        io::ErrorKind::InvalidInput
    );
    broker.detach(first).await.unwrap();
    assert_eq!(
        broker
            .submit(first, Request::turn("detached"), Priority::CommittedCaption)
            .await
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotConnected
    );
    let id = broker
        .submit(second, Request::turn("alive"), Priority::LiveRail)
        .await
        .unwrap();
    assert_eq!(
        completed(&mut broker, id).await.as_deref(),
        Some("ok:alive")
    );
    broker.detach(second).await.unwrap();
    assert_eq!(
        std::fs::read_to_string(root.path().join("launches"))
            .unwrap()
            .lines()
            .count(),
        1
    );
    assert_eq!(
        &commands(root.path())[..2],
        ["%%PFX 2 prefix 한글 日", "Hello 한글 日"]
    );
    stop(&mut broker).await;
}

#[tokio::test]
async fn captions_precede_background_fifo_and_cancel_drains_only_queued_client_work() {
    let root = tempfile::tempdir().unwrap();
    let mut broker = DnaBroker::new().unwrap();
    let caption = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, caption).await;
    let background = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, background).await;
    let blocker = broker
        .submit(background, Request::turn("BLOCK"), Priority::LiveRail)
        .await
        .unwrap();
    until(
        &mut broker,
        |e| matches!(e,Event::Partial { request, .. } if *request==blocker),
    )
    .await;
    broker.report_caption_pressure(3).unwrap();
    let post = broker
        .submit(background, Request::turn("post"), Priority::PostSession)
        .await
        .unwrap();
    let rail = broker
        .submit(background, Request::turn("rail"), Priority::LiveRail)
        .await
        .unwrap();
    let interim = broker
        .submit(caption, Request::turn("interim"), Priority::InterimCaption)
        .await
        .unwrap();
    let c1 = broker
        .submit(
            caption,
            Request::turn("caption1"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    let c2 = broker
        .submit(
            caption,
            Request::turn("caption2"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    let drop = broker
        .submit(background, Request::turn("cancelled"), Priority::LiveRail)
        .await
        .unwrap();
    broker.cancel_pending(background).await.unwrap();
    let cancelled = until(
        &mut broker,
        |e| matches!(e,Event::Completed { request, .. } if *request==drop),
    )
    .await;
    let ids: Vec<_> = cancelled
        .iter()
        .filter_map(|e| match e {
            Event::Completed {
                request,
                text: None,
                ..
            } => Some(*request),
            _ => None,
        })
        .collect();
    assert_eq!(ids, [post, rail, drop]);
    std::fs::write(root.path().join("release"), b"").unwrap();
    let done = until(
        &mut broker,
        |e| matches!(e,Event::Completed { request,.. } if *request==interim),
    )
    .await;
    let ids: Vec<_> = done
        .iter()
        .filter_map(|e| match e {
            Event::Completed { request, .. } => Some(*request),
            _ => None,
        })
        .collect();
    assert_eq!(ids, [blocker, c1, c2, interim]);
    let held = broker
        .submit(background, Request::turn("held"), Priority::LiveRail)
        .await
        .unwrap();
    // This acknowledgement orders the pressure/submit commands; no sleeps are
    // used to infer eligibility or to make the expected ordering pass.
    broker.cancel_pending(caption).await.unwrap();
    assert!(!commands(root.path()).contains(&"held".to_owned()));
    broker.report_caption_pressure(0).unwrap();
    assert_eq!(
        completed(&mut broker, held).await.as_deref(),
        Some("ok:held")
    );
    assert_eq!(
        commands(root.path()),
        ["BLOCK", "caption1", "caption2", "interim", "held"]
    );
    stop(&mut broker).await;
}

#[tokio::test]
async fn wedge_fails_every_request_restarts_before_callbacks_and_redeclares_capabilities() {
    let root = tempfile::tempdir().unwrap();
    let mut broker = DnaBroker::with_timeout(Some(Duration::from_millis(250))).unwrap();
    let client = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, client).await;
    let wedge = broker
        .submit(client, Request::turn("WEDGE"), Priority::CommittedCaption)
        .await
        .unwrap();
    let queued = broker
        .submit(client, Request::turn("queued"), Priority::CommittedCaption)
        .await
        .unwrap();
    let events = until(
        &mut broker,
        |e| matches!(e,Event::Completed { request,.. } if *request==wedge),
    )
    .await;
    assert!(
        events
            .iter()
            .any(|e| matches!(e,Event::Completed { request,text:None,.. } if *request==queued))
    );
    let started = events
        .iter()
        .position(|e| matches!(e, Event::Started { generation: 2, .. }))
        .unwrap();
    let failed = events
        .iter()
        .position(|e| matches!(e, Event::Completed { .. }))
        .unwrap();
    assert!(started < failed);
    // Submit directly from completion handling, before consuming the new READY.
    let id = broker
        .submit(
            client,
            Request::turn("after-restart"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    let events = until(
        &mut broker,
        |e| matches!(e,Event::Completed { request,.. } if *request==id),
    )
    .await;
    assert!(events.iter().any(|e|matches!(e,Event::Ready { generation:2,capabilities,.. } if !capabilities.contains("fp") && capabilities.contains("max"))));
    assert!(events.iter().any(|e|matches!(e,Event::Completed { request,text:Some(text),.. } if *request==id && text=="ok:after-restart")));
    assert!(!commands(root.path()).contains(&"queued".to_owned()));
    stop(&mut broker).await;
}

#[tokio::test]
async fn repeated_wedges_stop_after_two_restarts_but_normal_death_never_restarts() {
    let root = tempfile::tempdir().unwrap();
    let mut broker = DnaBroker::with_timeout(Some(Duration::from_millis(150))).unwrap();
    let client = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, client).await;
    for _ in 0..3 {
        let id = broker
            .submit(client, Request::turn("WEDGE"), Priority::CommittedCaption)
            .await
            .unwrap();
        assert_eq!(completed(&mut broker, id).await, None);
    }
    assert_eq!(
        broker
            .submit(
                client,
                Request::turn("stranded"),
                Priority::CommittedCaption
            )
            .await
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotConnected
    );
    assert_eq!(
        std::fs::read_to_string(root.path().join("launches"))
            .unwrap()
            .lines()
            .count(),
        3
    );
    broker.detach(client).await.unwrap();
    let fresh = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, fresh).await;
    let id = broker
        .submit(fresh, Request::turn("CRASH"), Priority::CommittedCaption)
        .await
        .unwrap();
    let events = until(
        &mut broker,
        |e| matches!(e,Event::Completed { request,.. } if *request==id),
    )
    .await;
    assert!(events.contains(&Event::Stopped {
        generation: 4,
        code: Some(7),
        reason: StopReason::Exited
    }));
    assert_eq!(
        broker
            .submit(fresh, Request::turn("stranded"), Priority::CommittedCaption)
            .await
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotConnected
    );
    assert_eq!(
        std::fs::read_to_string(root.path().join("launches"))
            .unwrap()
            .lines()
            .count(),
        4
    );
    stop(&mut broker).await;
}

#[tokio::test]
async fn detached_active_client_is_drained_without_delivering_its_reply_to_another_client() {
    let root = tempfile::tempdir().unwrap();
    let mut broker = DnaBroker::new().unwrap();
    let a = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, a).await;
    let b = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, b).await;
    let old = broker
        .submit(a, Request::turn("BLOCK"), Priority::CommittedCaption)
        .await
        .unwrap();
    until(
        &mut broker,
        |e| matches!(e,Event::Partial { request,.. } if *request==old),
    )
    .await;
    broker.detach(a).await.unwrap();
    let new = broker
        .submit(b, Request::turn("new"), Priority::CommittedCaption)
        .await
        .unwrap();
    std::fs::write(root.path().join("release"), b"").unwrap();
    let events = until(
        &mut broker,
        |e| matches!(e,Event::Completed { request,.. } if *request==new),
    )
    .await;
    assert!(!events.iter().any(
        |e| matches!(e,Event::Partial {client,..}|Event::Completed {client,..} if *client==a)
    ));
    assert_eq!(
        events.last(),
        Some(&Event::Completed {
            client: b,
            request: new,
            text: Some("ok:new".into())
        })
    );
    stop(&mut broker).await;
}

#[cfg(unix)]
#[tokio::test]
async fn last_detach_escalates_ignored_sigterm_and_wait_cancellation_keeps_supervision() {
    let root = tempfile::tempdir().unwrap();
    let mut broker = DnaBroker::new().unwrap();
    let client = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, client).await;
    // The fixture enables SIGTERM ignore before answering the next command.
    let ignored = broker
        .submit(
            client,
            Request::turn("WEDGE_IGNORE"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    until(
        &mut broker,
        |e| matches!(e, Event::Partial {request, ..} if *request == ignored),
    )
    .await;
    // Cancellation of wait must leave the JoinHandle available for shutdown.
    assert!(
        timeout(Duration::from_millis(10), broker.wait())
            .await
            .is_err()
    );
    assert!(broker.task.is_some());
    let pid = std::fs::read_to_string(root.path().join("launches"))
        .unwrap()
        .trim()
        .parse::<i32>()
        .unwrap();
    broker.detach(client).await.unwrap();
    // SAFETY: signal 0 checks existence only. Reaping precedes detach's reply.
    assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    stop(&mut broker).await;
}

#[tokio::test]
async fn a_successful_turn_restores_the_consecutive_wedge_budget() {
    let root = tempfile::tempdir().unwrap();
    let mut broker = DnaBroker::with_timeout(Some(Duration::from_millis(500))).unwrap();
    let client = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, client).await;
    for round in 0..2 {
        for _ in 0..2 {
            let id = broker
                .submit(client, Request::turn("WEDGE"), Priority::CommittedCaption)
                .await
                .unwrap();
            assert_eq!(completed(&mut broker, id).await, None);
        }
        let id = broker
            .submit(
                client,
                Request::turn(format!("healthy-{round}")),
                Priority::CommittedCaption,
            )
            .await
            .unwrap();
        assert_eq!(
            completed(&mut broker, id).await,
            Some(format!("ok:healthy-{round}"))
        );
    }
    assert_eq!(
        std::fs::read_to_string(root.path().join("launches"))
            .unwrap()
            .lines()
            .count(),
        5
    );
    stop(&mut broker).await;
}

#[tokio::test]
async fn full_stdin_pipe_does_not_block_watchdog_or_shutdown() {
    let root = tempfile::tempdir().unwrap();
    let mut config = launch(root.path());
    config.arguments[2] = "import os,time;os.write(1,b'READY\\n');time.sleep(60)".into();
    let mut broker = DnaBroker::with_timeout(Some(Duration::from_millis(250))).unwrap();
    let client = broker.attach(config).await.unwrap();
    ready(&mut broker, client).await;
    let id = broker
        .submit(
            client,
            Request::turn("x".repeat(8 * 1024 * 1024)),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    assert_eq!(completed(&mut broker, id).await, None);
    stop(&mut broker).await;
}

#[tokio::test]
async fn half_closed_stdout_fails_queued_work_and_spawn_failure_leaves_no_client() {
    let root = tempfile::tempdir().unwrap();
    let mut broker = DnaBroker::new().unwrap();
    let mut invalid = launch(root.path());
    invalid.engine = root.path().join("missing");
    assert!(broker.attach(invalid).await.is_err());
    let mut config = launch(root.path());
    config.arguments[2] =
        "import os,time;os.write(1,b'READY\\n');os.close(1);time.sleep(60)".into();
    let client = broker.attach(config).await.unwrap();
    ready(&mut broker, client).await;
    let id = broker
        .submit(
            client,
            Request::turn("cannot-answer"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    assert_eq!(completed(&mut broker, id).await, None);
    assert_eq!(
        broker
            .submit(
                client,
                Request::turn("stranded"),
                Priority::CommittedCaption
            )
            .await
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotConnected
    );
    stop(&mut broker).await;
}

#[cfg(unix)]
#[tokio::test]
async fn owner_drop_reaps_child_and_shutdown_tail_cannot_complete_a_new_turn() {
    let root = tempfile::tempdir().unwrap();
    let mut config = launch(root.path());
    let modified = ENGINE.replace(
        "if line=='CRASH':sys.exit(7)",
        r#"if line=='LATE':
        def late(signum,frame):
            os.write(1,b'wrong old reply\n[perf] generation: 1 tok\n')
            sys.exit(0)
        signal.signal(signal.SIGTERM,late)
        os.write(1,b'[perf] prefill: 1 tok\nwaiting')
        continue
    if line=='CRASH':sys.exit(7)"#,
    );
    config.arguments[2] = modified.into();
    let mut broker = DnaBroker::with_timeout(Some(Duration::from_millis(500))).unwrap();
    let client = broker.attach(config).await.unwrap();
    ready(&mut broker, client).await;
    let old = broker
        .submit(client, Request::turn("LATE"), Priority::CommittedCaption)
        .await
        .unwrap();
    let events = until(
        &mut broker,
        |e| matches!(e, Event::Completed {request,..} if *request==old),
    )
    .await;
    assert!(!events.iter().any(|e| matches!(e, Event::Partial { text,..} | Event::Completed {text:Some(text),..} if text.contains("wrong"))));
    assert_eq!(
        events.last(),
        Some(&Event::Completed {
            client,
            request: old,
            text: None
        })
    );
    let new = broker
        .submit(client, Request::turn("fresh"), Priority::CommittedCaption)
        .await
        .unwrap();
    assert_eq!(
        completed(&mut broker, new).await.as_deref(),
        Some("ok:fresh")
    );
    let pids: Vec<i32> = std::fs::read_to_string(root.path().join("launches"))
        .unwrap()
        .lines()
        .map(|s| s.parse().unwrap())
        .collect();
    let task = broker.task.take().unwrap();
    drop(broker);
    timeout(Duration::from_secs(8), task)
        .await
        .unwrap()
        .unwrap();
    for pid in pids {
        // SAFETY: signal 0 probes process existence without sending a signal.
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    }
}

#[tokio::test]
async fn client_tokens_cannot_cross_owner_instances() {
    let root = tempfile::tempdir().unwrap();
    let mut old = DnaBroker::new().unwrap();
    let client = old.attach(launch(root.path())).await.unwrap();
    ready(&mut old, client).await;
    stop(&mut old).await;
    let mut new = DnaBroker::new().unwrap();
    let fresh = new.attach(launch(root.path())).await.unwrap();
    ready(&mut new, fresh).await;
    assert_ne!(client, fresh);
    assert_eq!(
        new.submit(client, Request::turn("stale"), Priority::CommittedCaption)
            .await
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotConnected
    );
    let id = new
        .submit(fresh, Request::turn("current"), Priority::CommittedCaption)
        .await
        .unwrap();
    assert_eq!(completed(&mut new, id).await.as_deref(), Some("ok:current"));
    stop(&mut new).await;
}

#[cfg(unix)]
#[tokio::test]
async fn shutdown_during_timeout_reaping_never_relaunches_a_model() {
    let root = tempfile::tempdir().unwrap();
    let mut broker = DnaBroker::with_timeout(Some(Duration::from_millis(1000))).unwrap();
    let client = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, client).await;
    let id = broker
        .submit(
            client,
            Request::turn("WEDGE_IGNORE"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    until(
        &mut broker,
        |e| matches!(e,Event::Partial {request,..} if *request==id),
    )
    .await;
    // The native process has acknowledged SIG_IGN. Observe an actual watchdog
    // expiry before requesting shutdown while the child is being reaped.
    tokio::time::pause();
    tokio::time::advance(Duration::from_millis(1001)).await;
    until(
        &mut broker,
        |e| matches!(e, Event::TimedOut {request,..} if *request==id),
    )
    .await;
    broker.shutdown();
    tokio::time::resume();
    timeout(Duration::from_secs(8), broker.wait())
        .await
        .unwrap()
        .unwrap();
    let mut starts = 0;
    while let Some(event) = broker.next().await {
        if matches!(event, Event::Started { .. }) {
            starts += 1;
        }
    }
    assert_eq!(starts, 0, "no additional process after initial READY");
    assert_eq!(
        std::fs::read_to_string(root.path().join("launches"))
            .unwrap()
            .lines()
            .count(),
        1
    );
}

#[cfg(unix)]
#[tokio::test]
async fn last_detach_during_timeout_reaps_before_deferred_attach_and_answers_duplicate_detach() {
    let root = tempfile::tempdir().unwrap();
    let next_root = tempfile::tempdir().unwrap();
    let mut broker = DnaBroker::with_timeout(Some(Duration::from_secs(1))).unwrap();
    let client = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, client).await;
    let id = broker
        .submit(
            client,
            Request::turn("WEDGE_IGNORE"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    until(
        &mut broker,
        |e| matches!(e,Event::Partial {request,..} if *request==id),
    )
    .await;
    tokio::time::pause();
    tokio::time::advance(Duration::from_millis(1001)).await;
    until(
        &mut broker,
        |e| matches!(e,Event::TimedOut {request,..} if *request==id),
    )
    .await;
    tokio::time::resume();
    let (a, b, attached) = tokio::join!(
        broker.detach(client),
        broker.detach(client),
        broker.attach(launch(next_root.path()))
    );
    a.unwrap();
    b.unwrap();
    let fresh = attached.unwrap();
    let old_pid = std::fs::read_to_string(root.path().join("launches")).unwrap();
    assert_eq!(
        old_pid.lines().count(),
        1,
        "last detach must suppress automatic restart"
    );
    // SAFETY: signal 0 checks existence only; both detach calls acknowledged.
    assert_eq!(
        unsafe { libc::kill(old_pid.trim().parse().unwrap(), 0) },
        -1
    );
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    ready(&mut broker, fresh).await;
    let id = broker
        .submit(
            fresh,
            Request::turn("replacement"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    assert_eq!(
        completed(&mut broker, id).await.as_deref(),
        Some("ok:replacement")
    );
    stop(&mut broker).await;
}

#[cfg(unix)]
#[tokio::test]
async fn cancelling_a_deferred_attach_does_not_launch_an_unowned_model() {
    let root = tempfile::tempdir().unwrap();
    let mut broker = DnaBroker::with_timeout(Some(Duration::from_secs(1))).unwrap();
    let client = broker.attach(launch(root.path())).await.unwrap();
    ready(&mut broker, client).await;
    let id = broker
        .submit(
            client,
            Request::turn("WEDGE_IGNORE"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    until(
        &mut broker,
        |e| matches!(e,Event::Partial {request,..} if *request==id),
    )
    .await;
    tokio::time::pause();
    tokio::time::advance(Duration::from_millis(1001)).await;
    until(
        &mut broker,
        |e| matches!(e,Event::TimedOut {request,..} if *request==id),
    )
    .await;
    tokio::time::resume();
    let (detach_tx, detach_rx) = oneshot::channel();
    let (attach_tx, attach_rx) = oneshot::channel();
    broker
        .commands
        .send(Control::Detach(client, detach_tx))
        .unwrap();
    broker
        .commands
        .send(Control::Attach(launch(root.path()), attach_tx))
        .unwrap();
    // Cancel is an acknowledgement barrier after the deferred attach command.
    broker.cancel_pending(client).await.unwrap();
    drop(attach_rx);
    timeout(Duration::from_secs(8), detach_rx)
        .await
        .unwrap()
        .unwrap();
    broker.cancel_pending(client).await.unwrap();
    while let Ok(event) = broker.events.try_recv() {
        assert!(
            !matches!(event, Event::Started { .. }),
            "cancelled attach spawned a model: {event:?}"
        );
    }
    assert_eq!(
        std::fs::read_to_string(root.path().join("launches"))
            .unwrap()
            .lines()
            .count(),
        1
    );
    stop(&mut broker).await;
}
