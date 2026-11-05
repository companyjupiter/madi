use super::*;
use madi_core::dna::Priority;
use std::{path::Path, time::Duration};
use tokio::time::timeout;

const ENGINE: &str = r#"
import os,sys,time,pathlib
root=pathlib.Path(sys.argv[1])
with (root/'launches').open('a',encoding='utf-8') as f:f.write(str(os.getpid())+'\n')
generation=len((root/'launches').read_text(encoding='utf-8').splitlines())
os.write(1,('[caps] '+('fp max' if generation==1 else 'max')+'\nREADY\n').encode())
for raw in sys.stdin.buffer:
 line=raw.decode('utf-8').rstrip('\n')
 with (root/'commands').open('a',encoding='utf-8') as f:f.write(line+'\n')
 if line.startswith('%%PFX '):
  slot=line.split()[1]
  os.write(1,('[perf] prefill: 1 tok\n\n[perf] generation: 0 tok\n> ' if (root/'fail-prefix').exists() else 'PFX_OK '+slot+' 12\n').encode());continue
 source=line.rsplit(' . ',1)[-1].split(' =>')[0]
 if line.startswith('You are '):source=line.split('Source ',1)[1].split(': ',1)[1].rsplit(' Target ',1)[0]
 if source=='CRASH':
  os.write(1,b'[perf] prefill: 1 tok\ncrashing')
  while not (root/'release').exists():time.sleep(0.005)
  sys.exit(7)
 if source=='WEDGE_ALWAYS' or (source=='WEDGE' and generation==1):
  os.write(1,b'[perf] prefill: 1 tok\nwedging');continue
 os.write(1,b'[perf] prefill: 1 tok\n')
 if source=='oldsource':
  os.write(1,b'old')
  while not (root/'release').exists():time.sleep(0.005)
  answer='source'
 elif source=='ECHOONLY':answer=source
 elif source=='RUNAWAY':answer='0123456789. '+('long answer '*30)
 elif source=='안녕하세요':answer='Hello.'
 elif source=='좋은 아침':answer='Good morning.'
 elif source=='시작':answer='Hello tail.'
 elif source=='EMPTY':answer=''
 else:answer='Translated answer.'
 os.write(1,answer.encode()+b'\n[perf] generation: 1 tok\n> ')
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
fn commands(root: &Path) -> String {
    std::fs::read_to_string(root.join("commands")).unwrap_or_default()
}
async fn drive(
    broker: &mut DnaBroker,
    client: &mut TranslationClient,
    mut done: impl FnMut(&Event, &Update) -> bool,
) -> Vec<Effect> {
    timeout(Duration::from_secs(15), async {
        let mut effects = Vec::new();
        loop {
            let event = broker.next().await.expect("broker closed");
            let update = client.handle(broker, &event).await;
            assert!(update.fault.is_none(), "{:?}", update.fault);
            let stop = done(&event, &update);
            effects.extend(update.events);
            if stop {
                return effects;
            }
        }
    })
    .await
    .expect("translation event deadline")
}
async fn ready(b: &mut DnaBroker, c: &mut TranslationClient) {
    let id = c.id();
    drive(
        b,
        c,
        |e, _| matches!(e,Event::Ready{client,..} if *client==id),
    )
    .await;
}
async fn submit(b: &DnaBroker, c: &mut TranslationClient, id: Uuid, source: &str) {
    let (accepted, update) = c
        .translate(
            b,
            source,
            &["English".into()],
            id,
            Kind::Committed,
            &BTreeMap::new(),
        )
        .await;
    assert!(accepted);
    assert!(update.fault.is_none());
}
async fn result(b: &mut DnaBroker, c: &mut TranslationClient, id: Uuid) -> Vec<Effect> {
    drive(b, c, |_, u| {
        u.events
            .iter()
            .any(|e| matches!(e,Effect::Result(t) if t.id==id))
    })
    .await
}
fn text(effects: &[Effect], id: Uuid) -> Vec<String> {
    effects
        .iter()
        .filter_map(|e| {
            if let Effect::Result(t) = e {
                (t.id == id).then(|| t.text.clone())
            } else {
                None
            }
        })
        .collect()
}

#[tokio::test]
async fn one_shared_process_registers_context_forced_prefix_and_drains_background() {
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::new().unwrap();
    let mut c = TranslationClient::attach(&b, launch(root.path()), Configuration::default())
        .await
        .unwrap();
    let background = b.attach(launch(root.path())).await.unwrap();
    ready(&mut b, &mut c).await;
    let first = Uuid::new_v4();
    submit(&b, &mut c, first, "안녕하세요").await;
    assert_eq!(
        text(&result(&mut b, &mut c, first).await, first),
        ["Hello."]
    );
    let second = Uuid::new_v4();
    submit(&b, &mut c, second, "좋은 아침").await;
    assert_eq!(
        text(&result(&mut b, &mut c, second).await, second),
        ["Good morning."]
    );
    let interim = Uuid::new_v4();
    let (accepted, u) = c
        .translate(
            &b,
            "시작",
            &["English".into()],
            interim,
            Kind::Interim,
            &BTreeMap::from([("English".into(), "Hello".into())]),
        )
        .await;
    assert!(accepted && u.fault.is_none());
    assert_eq!(
        text(&result(&mut b, &mut c, interim).await, interim),
        ["Hello tail."]
    );
    assert_eq!(c.depth(), 0);
    let wire = commands(root.path());
    assert_eq!(wire.matches("%%PFX 1 ").count(), 1);
    assert!(wire.contains("%%TRN 1 안녕하세요 => Hello. . 좋은 아침 => %%MAX 48"));
    assert!(wire.contains("%%FP Hello"));
    let r = b
        .submit(
            background,
            crate::dna_broker::Request::turn("BACKGROUND"),
            Priority::PostSession,
        )
        .await
        .unwrap();
    drive(
        &mut b,
        &mut c,
        |e, _| matches!(e,Event::Completed{request,text:Some(_),..} if *request==r),
    )
    .await;
    c.stop(&b).await.unwrap();
    assert_eq!(
        std::fs::read_to_string(root.path().join("launches"))
            .unwrap()
            .lines()
            .count(),
        1
    );
    b.detach(background).await.unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}

#[tokio::test]
async fn old_echo_cannot_retry_over_new_revision_and_invalid_replies_terminate() {
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::new().unwrap();
    let mut c = TranslationClient::attach(&b, launch(root.path()), Configuration::default())
        .await
        .unwrap();
    ready(&mut b, &mut c).await;
    let id = Uuid::new_v4();
    submit(&b, &mut c, id, "oldsource").await;
    drive(
        &mut b,
        &mut c,
        |e, _| matches!(e,Event::Partial{text,..} if text=="old"),
    )
    .await;
    submit(&b, &mut c, id, "newsource").await;
    std::fs::write(root.path().join("release"), b"").unwrap();
    let effects = result(&mut b, &mut c, id).await;
    assert!(
        effects
            .iter()
            .any(|e| matches!(e,Effect::Discard{source,..} if source=="oldsource"))
    );
    assert_eq!(text(&effects, id), ["Translated answer."]);
    assert!(!commands(root.path()).contains("Source English: oldsource"));
    let echo = Uuid::new_v4();
    submit(&b, &mut c, echo, "ECHOONLY").await;
    assert_eq!(text(&result(&mut b, &mut c, echo).await, echo), [""]);
    assert_eq!(
        commands(root.path())
            .matches("Source English: ECHOONLY")
            .count(),
        1
    );
    let runaway = Uuid::new_v4();
    submit(&b, &mut c, runaway, "RUNAWAY").await;
    assert_eq!(
        text(&result(&mut b, &mut c, runaway).await, runaway),
        ["0123456789."]
    );
    assert_eq!(c.runaway_truncations(), 1);
    let empty = Uuid::new_v4();
    submit(&b, &mut c, empty, "EMPTY").await;
    assert_eq!(text(&result(&mut b, &mut c, empty).await, empty), [""]);
    assert!(!commands(root.path()).contains("RUNAWAY => 0123456789."));
    c.stop(&b).await.unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}

#[tokio::test]
async fn timeout_re_registers_prefix_before_resuming_and_forgets_old_capabilities() {
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::with_timeout(Some(Duration::from_millis(350))).unwrap();
    let mut c = TranslationClient::attach(&b, launch(root.path()), Configuration::default())
        .await
        .unwrap();
    ready(&mut b, &mut c).await;
    let wedge = Uuid::new_v4();
    submit(&b, &mut c, wedge, "WEDGE").await;
    // The actual child has received the turn before another request enters the queue.
    drive(
        &mut b,
        &mut c,
        |e, _| matches!(e, Event::Partial{text,..} if text=="wedging"),
    )
    .await;
    let next = Uuid::new_v4();
    submit(&b, &mut c, next, "newsource").await;
    let effects = result(&mut b, &mut c, next).await;
    assert_eq!(text(&effects, wedge), [""]);
    assert_eq!(text(&effects, next), ["Translated answer."]);
    let wire = commands(root.path());
    assert_eq!(wire.matches("%%PFX 1 ").count(), 2);
    let new_turn = wire.lines().find(|l| l.contains("newsource")).unwrap();
    assert!(new_turn.starts_with("%%TRN 1 "));
    assert!(!new_turn.contains("%%MAX"));
    c.stop(&b).await.unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}

#[tokio::test]
async fn failed_prefix_uses_full_prompt_and_drop_releases_caption_pressure_and_residency() {
    let root = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("fail-prefix"), b"").unwrap();
    let mut b = DnaBroker::new().unwrap();
    let mut c = TranslationClient::attach(&b, launch(root.path()), Configuration::default())
        .await
        .unwrap();
    ready(&mut b, &mut c).await;
    let id = Uuid::new_v4();
    submit(&b, &mut c, id, "안녕하세요").await;
    assert_eq!(text(&result(&mut b, &mut c, id).await, id), ["Hello."]);
    let wire = commands(root.path());
    assert!(
        wire.lines()
            .any(|l| l.starts_with("Translate the following into English."))
    );
    assert!(!wire.contains("%%TRN"));
    drop(c);
    timeout(Duration::from_secs(5), async {
        loop {
            if matches!(
                b.next().await,
                Some(Event::Stopped {
                    reason: StopReason::Detached,
                    ..
                })
            ) {
                break;
            }
        }
    })
    .await
    .unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}

#[tokio::test]
async fn replacement_ignores_retained_stop_from_previous_process_generation() {
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::new().unwrap();
    let mut old = TranslationClient::attach(&b, launch(root.path()), Configuration::default())
        .await
        .unwrap();
    ready(&mut b, &mut old).await;
    old.stop(&b).await.unwrap();
    // Stopped is still in the event stream when the new client queues its first line.
    let mut new = TranslationClient::attach(&b, launch(root.path()), Configuration::default())
        .await
        .unwrap();
    let id = Uuid::new_v4();
    submit(&b, &mut new, id, "안녕하세요").await;
    assert_eq!(text(&result(&mut b, &mut new, id).await, id), ["Hello."]);
    new.stop(&b).await.unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}

#[tokio::test]
async fn crash_drains_client_owned_queue_and_rejects_later_phantom_work() {
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::new().unwrap();
    let mut c = TranslationClient::attach(&b, launch(root.path()), Configuration::default())
        .await
        .unwrap();
    ready(&mut b, &mut c).await;
    let ids = [Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4()];
    submit(&b, &mut c, ids[0], "CRASH").await;
    drive(
        &mut b,
        &mut c,
        |e, _| matches!(e,Event::Partial{text,..} if text=="crashing"),
    )
    .await;
    submit(&b, &mut c, ids[1], "queued one").await;
    submit(&b, &mut c, ids[2], "queued two").await;
    std::fs::write(root.path().join("release"), b"").unwrap();
    let effects = drive(&mut b, &mut c, |_, u| {
        u.events
            .iter()
            .any(|e| matches!(e, Effect::Depth { turns: 0, .. }))
    })
    .await;
    for id in ids {
        assert_eq!(text(&effects, id), [""]);
    }
    let (accepted, _) = c
        .translate(
            &b,
            "later",
            &["English".into()],
            Uuid::new_v4(),
            Kind::Committed,
            &BTreeMap::new(),
        )
        .await;
    assert!(!accepted);
    assert_eq!(c.depth(), 0);
    c.stop(&b).await.unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}

#[tokio::test]
async fn exhausted_restarts_drain_requests_never_submitted_to_the_broker() {
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::with_timeout(Some(Duration::from_millis(180))).unwrap();
    let mut c = TranslationClient::attach(&b, launch(root.path()), Configuration::default())
        .await
        .unwrap();
    ready(&mut b, &mut c).await;
    let ids: Vec<_> = (0..4).map(|_| Uuid::new_v4()).collect();
    for &id in &ids {
        let (accepted, u) = c
            .translate(
                &b,
                "WEDGE_ALWAYS",
                &["French".into()],
                id,
                Kind::Committed,
                &BTreeMap::new(),
            )
            .await;
        assert!(accepted && u.fault.is_none());
    }
    let effects = drive(&mut b, &mut c, |e, _| {
        matches!(
            e,
            Event::Unavailable {
                reason: StopReason::Timeout,
                ..
            }
        )
    })
    .await;
    for id in ids {
        assert_eq!(text(&effects, id), [""]);
    }
    assert_eq!(
        std::fs::read_to_string(root.path().join("launches"))
            .unwrap()
            .lines()
            .count(),
        3
    );
    assert_eq!(c.depth(), 0);
    c.stop(&b).await.unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}

#[tokio::test]
async fn dropped_caption_client_clears_pressure_for_surviving_background_client() {
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::new().unwrap();
    let mut c = TranslationClient::attach(&b, launch(root.path()), Configuration::default())
        .await
        .unwrap();
    ready(&mut b, &mut c).await;
    let background = b.attach(launch(root.path())).await.unwrap();
    submit(&b, &mut c, Uuid::new_v4(), "oldsource").await;
    drive(
        &mut b,
        &mut c,
        |e, _| matches!(e,Event::Partial{text,..} if text=="old"),
    )
    .await;
    let request = b
        .submit(
            background,
            crate::dna_broker::Request::turn("BACKGROUND"),
            Priority::PostSession,
        )
        .await
        .unwrap();
    drop(c);
    std::fs::write(root.path().join("release"), b"").unwrap();
    timeout(Duration::from_secs(5),async {loop {
        if matches!(b.next().await,Some(Event::Completed{request:r,text:Some(_),..}) if r==request){break;}
    }}).await.expect("dropped caption pressure must not strand background work");
    b.detach(background).await.unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}

#[tokio::test]
async fn malformed_turn_is_terminal_without_poisoning_the_resident_client() {
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::new().unwrap();
    let mut c = TranslationClient::attach(&b, launch(root.path()), Configuration::default())
        .await
        .unwrap();
    ready(&mut b, &mut c).await;
    let id = Uuid::new_v4();
    submit(&b, &mut c, id, "bad\0source").await;
    timeout(Duration::from_secs(5), async {
        loop {
            let event = b.next().await.unwrap();
            let update = c.handle(&b, &event).await;
            if update.fault.is_some() {
                assert_eq!(text(&update.events, id), [""]);
                break;
            }
        }
    })
    .await
    .unwrap();
    let valid = Uuid::new_v4();
    submit(&b, &mut c, valid, "안녕하세요").await;
    assert_eq!(
        text(&result(&mut b, &mut c, valid).await, valid),
        ["Hello."]
    );
    c.stop(&b).await.unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}

#[tokio::test]
async fn cancelled_attach_after_reply_was_queued_does_not_leave_a_resident_client() {
    use std::{future::Future, task::Poll};
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::new().unwrap();
    // Poll once to send Attach, then retain the future without polling its reply.
    let config = launch(root.path());
    let mut attaching = Box::pin(b.attach_caption(config));
    std::future::poll_fn(|cx| {
        assert!(attaching.as_mut().poll(cx).is_pending());
        Poll::Ready(())
    })
    .await;
    // attach_caption borrows b immutably, so observe the actual child through a
    // separate filesystem handshake while the future remains unpolled.
    timeout(Duration::from_secs(5), async {
        loop {
            if root.path().join("launches").exists() {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    drop(attaching);
    timeout(Duration::from_secs(5), async {
        loop {
            if matches!(
                b.next().await,
                Some(Event::Stopped {
                    reason: StopReason::Detached,
                    ..
                })
            ) {
                break;
            }
        }
    })
    .await
    .expect("cancelled attachment reply must release its client");
    b.shutdown();
    b.wait().await.unwrap();
}
