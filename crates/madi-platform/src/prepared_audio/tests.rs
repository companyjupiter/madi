use super::*;
use std::time::Duration;
use tokio::time::timeout;

fn wav(rate: u32, channels: u16, frames: usize, sample: i16) -> Vec<u8> {
    let bytes = (frames * usize::from(channels) * 2) as u32;
    let mut data = Vec::new();
    data.extend_from_slice(b"RIFF");
    data.extend_from_slice(&(36 + bytes).to_le_bytes());
    data.extend_from_slice(b"WAVEfmt ");
    data.extend_from_slice(&16_u32.to_le_bytes());
    data.extend_from_slice(&1_u16.to_le_bytes());
    data.extend_from_slice(&channels.to_le_bytes());
    data.extend_from_slice(&rate.to_le_bytes());
    data.extend_from_slice(&(rate * u32::from(channels) * 2).to_le_bytes());
    data.extend_from_slice(&(channels * 2).to_le_bytes());
    data.extend_from_slice(&16_u16.to_le_bytes());
    data.extend_from_slice(b"data");
    data.extend_from_slice(&bytes.to_le_bytes());
    for _ in 0..frames * usize::from(channels) {
        data.extend_from_slice(&sample.to_le_bytes());
    }
    data
}

#[tokio::test]
async fn concurrent_native_decodes_are_non_silent_isolated_and_preserve_originals() {
    let root = tempfile::tempdir().unwrap();
    let a = root.path().join("첫 번째 stereo.wav");
    let b = root.path().join("second.wav");
    let source_a = wav(48_000, 2, 48_000, 1000);
    let source_b = wav(16_000, 1, 8000, -2000);
    std::fs::write(&a, &source_a).unwrap();
    std::fs::write(&b, &source_b).unwrap();
    let mut task_a = DecodeTask::start(development_helper(), &a, root.path()).unwrap();
    let mut task_b = DecodeTask::start(development_helper(), &b, root.path()).unwrap();
    let (decoded_a, decoded_b) = timeout(Duration::from_secs(20), async {
        tokio::join!(task_a.wait(), task_b.wait())
    })
    .await
    .unwrap();
    let decoded_a = decoded_a.unwrap();
    let decoded_b = decoded_b.unwrap();
    assert_ne!(decoded_a.path(), decoded_b.path());
    let output = std::fs::read(decoded_a.path()).unwrap();
    assert!(output.len() > 44 + 15_000 * 2 && output.len() < 44 + 17_000 * 2);
    assert!(
        output[44..]
            .as_chunks::<2>()
            .0
            .iter()
            .any(|v| i16::from_le_bytes(*v).abs() > 100)
    );
    assert_ne!(output, std::fs::read(decoded_b.path()).unwrap());
    let mut registry = PreparedRegistry::default();
    let path_a = registry.insert(decoded_a);
    let path_b = registry.insert(decoded_b);
    assert!(!registry.release(&a).unwrap());
    assert!(registry.release(&path_a).unwrap());
    assert!(!path_a.exists() && path_b.exists());
    assert!(!registry.release(&path_a).unwrap());
    drop(registry);
    assert!(!path_b.exists());
    assert_eq!(std::fs::read(a).unwrap(), source_a);
    assert_eq!(std::fs::read(b).unwrap(), source_b);
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 2);
}

#[tokio::test]
async fn empty_import_reports_native_failure_without_leaving_partial_output() {
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("empty.wav");
    let original = wav(16_000, 1, 0, 0);
    std::fs::write(&input, &original).unwrap();
    let mut task = DecodeTask::start(development_helper(), &input, root.path()).unwrap();
    assert!(matches!(
        timeout(Duration::from_secs(20), task.wait()).await.unwrap(),
        Err(DecodeError::Native { .. })
    ));
    assert_eq!(std::fs::read(input).unwrap(), original);
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
}

#[tokio::test]
async fn cancelled_native_import_reaps_helper_before_removing_owned_output() {
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("input.wav");
    std::fs::write(&input, wav(48_000, 2, 48_000, 1000)).unwrap();
    let mut task = DecodeTask::start(development_helper(), &input, root.path()).unwrap();
    task.cancel();
    assert!(matches!(
        timeout(Duration::from_secs(20), task.wait()).await.unwrap(),
        Err(DecodeError::Cancelled)
    ));
    assert!(input.exists());
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
}

#[tokio::test]
async fn dropping_import_owner_still_finishes_cleanup() {
    let root = tempfile::tempdir().unwrap();
    let input = root.path().join("input.wav");
    std::fs::write(&input, wav(48_000, 2, 48_000, 1000)).unwrap();
    let mut task = DecodeTask::start(development_helper(), &input, root.path()).unwrap();
    let completion = task.task.take().unwrap();
    drop(task);
    // Completion can race cancellation; either result still has owned cleanup.
    let result = timeout(Duration::from_secs(20), completion)
        .await
        .unwrap()
        .unwrap();
    drop(result);
    assert!(input.exists());
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
}

#[test]
fn foreign_or_symlinked_output_is_rejected_without_deleting_the_original() {
    let root = tempfile::tempdir().unwrap();
    let original = root.path().join("original.wav");
    let bytes = wav(16_000, 1, 10, 200);
    std::fs::write(&original, &bytes).unwrap();
    let own = tempfile::tempdir_in(root.path()).unwrap();
    let link = own.path().join("escape.wav");
    std::os::unix::fs::symlink(&original, &link).unwrap();
    assert!(matches!(
        validate_owned_wav(own, &link),
        Err(DecodeError::InvalidOutput(_))
    ));
    assert_eq!(std::fs::read(&original).unwrap(), bytes);
    assert!(validate_owned_wav(tempfile::tempdir_in(root.path()).unwrap(), &original).is_err());
    assert!(original.exists());
}
