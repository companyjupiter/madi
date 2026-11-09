use super::*;
use std::{path::Path, time::Duration};
use tokio::time::{sleep, timeout};

const ENGINE: &str = r#"
import os,sys,pathlib,time,json
root=pathlib.Path(sys.argv[1])
with (root/'launches').open('a',encoding='utf-8') as f:f.write(str(os.getpid())+'\n')
os.write(1,b'READY\n')
for raw in sys.stdin.buffer:
 line=raw.decode('utf-8').rstrip('\n')
 with (root/'commands').open('a',encoding='utf-8') as f:f.write(json.dumps(line)+'\n')
 os.write(1,b'[perf] prefill: 1 tok\n')
 if 'HOLD' in line or 'EXIT' in line:
  (root/'active').write_text(line,encoding='utf-8')
  while not (root/'release').exists():time.sleep(0.005)
 if 'EXIT' in line:sys.exit(7)
 if 'CAPTION' in line:answer='caption'
 elif 'FIRST' in line:answer='MERGE 3 1\nRELABEL 1 2'
 elif 'SECOND' in line:answer='OK'
 elif 'THIRD' in line:answer='LANG 3 ja'
 else:answer=''
 os.write(1,answer.encode('utf-8')+b'\n[perf] generation: 1 tok\n> ')
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
fn numbered(prefix: &str) -> String {
    format!(
        "1 [S1] {prefix} FIRST {}\n2 [S2] SECOND {}\n3 [S3] THIRD {}",
        "x".repeat(780),
        "y".repeat(780),
        "z".repeat(780)
    )
}
fn commands(root: &Path) -> Vec<String> {
    std::fs::read_to_string(root.join("commands"))
        .unwrap_or_default()
        .lines()
        .map(|s| serde_json::from_str(s).unwrap())
        .collect()
}
async fn next(b: &mut DnaBroker) -> Event {
    timeout(Duration::from_secs(15), b.next())
        .await
        .expect("broker deadline")
        .expect("broker closed")
}
async fn drive(
    b: &mut DnaBroker,
    c: &mut ReconcileClient,
    mut done: impl FnMut(&Event, &Update) -> bool,
) -> (Event, Update) {
    timeout(Duration::from_secs(15), async {
        loop {
            let e = b.next().await.expect("broker closed");
            let u = c.handle(&e);
            if done(&e, &u) {
                return (e, u);
            }
        }
    })
    .await
    .expect("reconcile event deadline")
}
async fn ready(b: &mut DnaBroker, c: &mut ReconcileClient) {
    let id = c.id();
    drive(
        b,
        c,
        |e, _| matches!(e,Event::Ready{client,..} if *client==id),
    )
    .await;
}
async fn file_ready(path: &Path) {
    timeout(Duration::from_secs(5), async {
        while !path.exists() {
            sleep(Duration::from_millis(5)).await
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn shared_process_respects_caption_pressure_and_preserves_ordered_multiline_parts() {
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::new().unwrap();
    let l = launch(root.path());
    let caption = b.attach(l.clone()).await.unwrap();
    let mut c = ReconcileClient::attach(&b, l).await.unwrap();
    ready(&mut b, &mut c).await;
    b.report_caption_pressure(1).unwrap();
    assert!(!c.reconcile(&b, &numbered("")).await.unwrap().completed);
    assert_eq!(c.pending(), 3);
    assert_eq!(
        c.reconcile(&b, "other").await.unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
    let request = b
        .submit(
            caption,
            Request::turn("CAPTION"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    drive(
        &mut b,
        &mut c,
        |e, _| matches!(e,Event::Completed{request:id,..} if *id==request),
    )
    .await;
    assert_eq!(commands(root.path()), ["CAPTION"]);
    // Releasing an AI lease must not clear another client's caption pressure.
    let extra = ReconcileClient::attach(&b, launch(root.path()))
        .await
        .unwrap();
    drop(extra);
    let barrier = b
        .submit(
            caption,
            Request::turn("CAPTION"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    drive(
        &mut b,
        &mut c,
        |e, _| matches!(e,Event::Completed{request:id,..} if *id==barrier),
    )
    .await;
    assert_eq!(commands(root.path()), ["CAPTION", "CAPTION"]);
    b.report_caption_pressure(0).unwrap();
    let (last, result) = drive(&mut b, &mut c, |_, u| u.completed).await;
    assert_eq!(
        result.text.as_deref(),
        Some("MERGE 3 1\nRELABEL 1 2\nLANG 3 ja")
    );
    assert_eq!(c.pending(), 0);
    assert!(!c.handle(&last).completed);
    let all = commands(root.path());
    assert_eq!(all.len(), 5);
    for (text, marker) in all[2..].iter().zip(["FIRST", "SECOND", "THIRD"]) {
        assert!(text.starts_with(reconcile::INSTRUCTION));
        assert!(text.contains(marker));
        assert!(!text.contains('\n'));
    }
    assert_eq!(
        std::fs::read_to_string(root.path().join("launches"))
            .unwrap()
            .lines()
            .count(),
        1
    );
    c.stop().await.unwrap();
    let request = b
        .submit(
            caption,
            Request::turn("CAPTION"),
            Priority::CommittedCaption,
        )
        .await
        .unwrap();
    drive(
        &mut b,
        &mut c,
        |e, _| matches!(e,Event::Completed{request:id,..} if *id==request),
    )
    .await;
    b.detach(caption).await.unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}

#[tokio::test]
async fn cancellation_drains_queued_parts_and_retired_results_cannot_finish_a_new_client() {
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::new().unwrap();
    let l = launch(root.path());
    let caption = b.attach(l.clone()).await.unwrap();
    let mut c = ReconcileClient::attach(&b, l.clone()).await.unwrap();
    ready(&mut b, &mut c).await;
    c.reconcile(&b, &numbered("HOLD")).await.unwrap();
    file_ready(&root.path().join("active")).await;
    c.cancel_pending(&b).await.unwrap();
    let mut retired = Vec::new();
    while c.pending() > 1 {
        let e = next(&mut b).await;
        let u = c.handle(&e);
        assert!(!u.completed);
        retired.push(e);
    }
    std::fs::write(root.path().join("release"), b"release").unwrap();
    let (last, result) = drive(&mut b, &mut c, |_, u| u.completed).await;
    retired.push(last);
    assert_eq!(result.text.as_deref(), Some("MERGE 3 1\nRELABEL 1 2"));
    assert_eq!(commands(root.path()).len(), 1);
    c.stop().await.unwrap();
    assert_eq!(
        c.reconcile(&b, "x").await.unwrap_err().kind(),
        io::ErrorKind::BrokenPipe
    );
    let mut replacement = ReconcileClient::attach(&b, l).await.unwrap();
    assert_ne!(replacement.id(), c.id());
    replacement.reconcile(&b, "1 [S1] EMPTY").await.unwrap();
    for event in retired {
        assert!(!replacement.handle(&event).completed);
        assert_eq!(replacement.pending(), 1);
    }
    let (_, result) = drive(&mut b, &mut replacement, |_, u| u.completed).await;
    assert_eq!(result.text.as_deref(), Some("OK"));
    let empty = replacement.reconcile(&b, "").await.unwrap();
    assert!(empty.completed);
    assert!(empty.text.is_none());
    replacement.stop().await.unwrap();
    b.detach(caption).await.unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}

#[tokio::test]
async fn crashed_model_drains_all_parts_once_without_inventing_corrections() {
    let root = tempfile::tempdir().unwrap();
    let mut b = DnaBroker::new().unwrap();
    let mut c = ReconcileClient::attach(&b, launch(root.path()))
        .await
        .unwrap();
    ready(&mut b, &mut c).await;
    c.reconcile(&b, &numbered("EXIT")).await.unwrap();
    file_ready(&root.path().join("active")).await;
    std::fs::write(root.path().join("release"), b"release").unwrap();
    let (last, result) = drive(&mut b, &mut c, |_, u| u.completed).await;
    assert_eq!(result.text.as_deref(), Some("OK"));
    assert_eq!(c.pending(), 0);
    assert!(!c.handle(&last).completed);
    assert_eq!(commands(root.path()).len(), 1);
    c.stop().await.unwrap();
    b.shutdown();
    b.wait().await.unwrap();
}
