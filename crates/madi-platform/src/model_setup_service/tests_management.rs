use super::*;

fn sparse_model(path: &Path, size: u64) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::File::create(path).unwrap().set_len(size).unwrap();
}

#[tokio::test]
async fn settings_refresh_and_locations_follow_files_without_starting_a_download() {
    let root = tempfile::tempdir().unwrap();
    let (service, _) = service(root.path(), true);
    let paths = service.locations().await;
    assert!(!paths.transcription_installed && !paths.translation_installed);
    assert_eq!(
        paths.transcription,
        root.path().join("Madi").join(TRANSCRIPTION.name)
    );
    assert_eq!(paths.translation_disk_gb, "2.8");
    sparse_model(&paths.transcription, TRANSCRIPTION.size_bytes);
    sparse_model(
        &paths.translation,
        TranslationVariant::Quality4B.asset().size_bytes,
    );
    let ready = service
        .manage(ManagementCommand::RefreshTranslation)
        .await
        .unwrap();
    assert_eq!(ready.state.translation, DownloadState::Ready);
    assert_eq!(
        ready.state.required,
        DownloadState::Idle,
        "refresh is translation-only"
    );
    assert_eq!(ready.state.choice, None);
    let paths = service.locations().await;
    assert!(paths.transcription_installed && paths.translation_installed);
    std::fs::remove_file(&paths.translation).unwrap();
    assert_eq!(
        service
            .manage(ManagementCommand::RefreshTranslation)
            .await
            .unwrap()
            .state
            .translation,
        DownloadState::Idle
    );
    {
        let mut inner = service.inner.lock().await;
        inner.state.translation = DownloadState::Downloading(0.3);
    }
    assert_eq!(
        service
            .manage(ManagementCommand::RefreshTranslation)
            .await
            .unwrap()
            .state
            .translation,
        DownloadState::Downloading(0.3)
    );
    assert!(service.inner.lock().await.downloader.is_none());
    service.shutdown().await.unwrap();
    assert!(
        service
            .manage(ManagementCommand::RefreshTranslation)
            .await
            .is_err()
    );
}

#[tokio::test]
async fn settings_redownload_runs_after_ready_and_failure_preserves_the_previous_model() {
    let root = tempfile::tempdir().unwrap();
    let (service, _) = service(root.path(), false);
    let (url, _, first) = server(b"abc", false);
    configure(&service, url, "http://127.0.0.1:1/unused".into()).await;
    service
        .manage(ManagementCommand::Download(ModelKind::Transcription))
        .await
        .unwrap();
    until(&service, |state| {
        state.state.required == DownloadState::Ready
    })
    .await;
    first.join().unwrap();
    let path = root.path().join("Madi").join(TRANSCRIPTION.name);
    assert_eq!(std::fs::read(&path).unwrap(), b"abc");
    // Re-download must not silently return after joining the completed Ready job.
    let (url, _, second) = server(b"bad", false);
    configure(&service, url, "http://127.0.0.1:1/unused".into()).await;
    service
        .manage(ManagementCommand::Download(ModelKind::Transcription))
        .await
        .unwrap();
    until(&service, |state| {
        matches!(state.state.required, DownloadState::Failed(_))
    })
    .await;
    second.join().unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), b"abc");
    assert_eq!(
        service.snapshot().await.state.choice,
        None,
        "Settings never makes a first-run choice"
    );
    assert!(
        service
            .manage(ManagementCommand::Download(ModelKind::Translation))
            .await
            .is_err()
    );
    let (url, _, third) = server(b"abc", false);
    configure(&service, url, "http://127.0.0.1:1/unused".into()).await;
    service
        .manage(ManagementCommand::Download(ModelKind::Transcription))
        .await
        .unwrap();
    until(&service, |state| {
        state.state.required == DownloadState::Ready
    })
    .await;
    third.join().unwrap();
    service.shutdown().await.unwrap();
    no_partial(root.path());
}

#[tokio::test]
async fn settings_translation_cancel_is_independent_and_owns_cleanup_after_caller_drop() {
    let root = tempfile::tempdir().unwrap();
    let (service, _) = service(root.path(), true);
    let (required_url, required_release, required_server) = server(b"abc", true);
    let (translation_url, translation_release, translation_server) = server(b"abc", true);
    configure(&service, required_url, translation_url).await;
    service
        .command(ModelSetupCommand::Start(ModelSetupChoice::Recommended))
        .await
        .unwrap();
    until(&service, |s| {
        receiving(&s.state.required) && receiving(&s.state.translation)
    })
    .await;
    // Repeated Settings clicks retain the same transfer instead of contending
    // for its staging file. This is an ownership guard, not new UI semantics.
    let generation = service.inner.lock().await.generations[1];
    service
        .manage(ManagementCommand::Download(ModelKind::Translation))
        .await
        .unwrap();
    assert_eq!(service.inner.lock().await.generations[1], generation);
    tokio::select! {
        biased;
        _ = service.manage(ManagementCommand::CancelTranslation) => panic!("cancel completed before worker cleanup"),
        _ = std::future::ready(()) => (),
    }
    {
        let inner = service.inner.lock().await;
        assert!(inner.jobs[1].as_ref().unwrap().cancelling);
        assert!(!inner.jobs[0].as_ref().unwrap().cancelling);
        assert!(receiving(&inner.state.required));
        assert_eq!(inner.state.translation, DownloadState::Idle);
    }
    service
        .manage(ManagementCommand::CancelTranslation)
        .await
        .unwrap();
    assert!(service.inner.lock().await.jobs[1].is_none());
    assert!(receiving(&service.snapshot().await.state.required));
    required_release.send(()).unwrap();
    translation_release.send(()).unwrap();
    required_server.join().unwrap();
    translation_server.join().unwrap();
    let done = until(&service, |s| s.state.required == DownloadState::Ready).await;
    assert_eq!(done.state.translation, DownloadState::Idle);
    assert_eq!(done.state.choice, Some(ModelSetupChoice::Recommended));
    service.shutdown().await.unwrap();
    no_partial(root.path());
}
