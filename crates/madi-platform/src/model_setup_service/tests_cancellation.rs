use super::*;

#[tokio::test]
async fn cancelled_command_and_shutdown_futures_retain_workers_until_joined() {
    let root = tempfile::tempdir().unwrap();
    let (service, _) = service(root.path(), false);
    let (url, release, first_server) = server(b"abc", true);
    configure(&service, url, "http://127.0.0.1:1/unused".into()).await;
    service
        .command(ModelSetupCommand::Start(
            ModelSetupChoice::TranscriptionOnly,
        ))
        .await
        .unwrap();
    until(&service, |s| receiving(&s.state.required)).await;
    // Current-thread runtime: poll the command through its first pending join,
    // then drop only that waiting future before the transfer can run cleanup.
    tokio::select! {
        biased;
        _ = service.command(ModelSetupCommand::Cancel) => panic!("cancel unexpectedly completed before its worker ran"),
        _ = std::future::ready(()) => (),
    }
    {
        let inner = service.inner.lock().await;
        assert!(inner.jobs[0].is_some(), "cancel must retain the worker");
        assert_eq!(inner.state.required, DownloadState::Cancelled);
    }
    let (url, release_retry, retry_server) = server(b"abc", true);
    configure(&service, url, "http://127.0.0.1:1/unused".into()).await;
    service.command(ModelSetupCommand::Retry).await.unwrap();
    until(&service, |s| receiving(&s.state.required)).await;
    release.send(()).unwrap();
    first_server.join().unwrap();
    tokio::select! {
        biased;
        _ = service.shutdown() => panic!("shutdown unexpectedly completed before its worker ran"),
        _ = std::future::ready(()) => (),
    }
    {
        let inner = service.inner.lock().await;
        assert!(inner.closing);
        assert!(inner.jobs[0].is_some(), "shutdown must retain the worker");
    }
    service.shutdown().await.unwrap();
    assert!(service.inner.lock().await.jobs[0].is_none());
    no_partial(root.path());
    assert!(!root.path().join("Madi").join(TRANSCRIPTION.name).exists());
    release_retry.send(()).unwrap();
    retry_server.join().unwrap();
}
