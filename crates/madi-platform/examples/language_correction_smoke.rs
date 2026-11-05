//! Explicit installed-model probe using only the pinned public JFK fixture.
use madi_core::capture_stream;
use madi_platform::{
    asr_config::Resources,
    capture_pipeline::{CapturePipeline, Event},
    language_correction::{Configuration, CorrectionTask},
};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    io::{self, Read},
    path::{Path, PathBuf},
    time::Instant,
};
fn digest(path: &Path) -> io::Result<String> {
    let mut f = std::fs::File::open(path)?;
    let mut hash = Sha256::new();
    let mut buf = [0u8; 65536];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
fn pcm(bytes: &[u8]) -> io::Result<Vec<i16>> {
    if bytes.get(..4) != Some(b"RIFF") || bytes.get(8..12) != Some(b"WAVE") {
        return Err(io::Error::other("expected public WAV"));
    }
    let mut at = 12;
    let mut format = false;
    while at + 8 <= bytes.len() {
        let size = u32::from_le_bytes(bytes[at + 4..at + 8].try_into().unwrap()) as usize;
        let start = at + 8;
        let chunk = bytes
            .get(start..start + size)
            .ok_or_else(|| io::Error::other("truncated WAV"))?;
        if &bytes[at..at + 4] == b"fmt " {
            format = chunk.len() >= 16
                && chunk[..4] == [1, 0, 1, 0]
                && chunk[4..8] == 16000u32.to_le_bytes()
                && chunk[14..16] == 16u16.to_le_bytes();
        }
        if &bytes[at..at + 4] == b"data" && format {
            let (pairs, tail) = chunk.as_chunks::<2>();
            if !tail.is_empty() {
                return Err(io::Error::other("odd PCM"));
            }
            return Ok(pairs.iter().map(|b| i16::from_le_bytes(*b)).collect());
        }
        at = start + size + size % 2;
    }
    Err(io::Error::other("missing mono PCM16"))
}
#[tokio::main(flavor = "current_thread")]
async fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 5 {
        return Err(io::Error::other(
            "usage: language_correction_smoke ENGINE MODEL ASSETS PUBLIC_JFK_WAV OUTPUT_DIR",
        ));
    }
    let engine = PathBuf::from(&args[0]).canonicalize()?;
    let model = PathBuf::from(&args[1]).canonicalize()?;
    let assets = PathBuf::from(&args[2]).canonicalize()?;
    let source = PathBuf::from(&args[3]).canonicalize()?;
    let out = PathBuf::from(&args[4]);
    std::fs::create_dir_all(&out)?;
    let original = std::fs::read(&source)?;
    let source_sha = format!("{:x}", Sha256::digest(&original));
    if source_sha != "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e" {
        return Err(io::Error::other("only pinned public JFK input admitted"));
    }
    let engine_sha = digest(&engine)?;
    let model_sha = digest(&model)?;
    let scratch = tempfile::tempdir()?;
    let mut capture = CapturePipeline::new(
        capture_stream::Configuration {
            segment_seconds: 30.,
            first_segment_seconds: 30.,
            preview_enabled: false,
            ..Default::default()
        },
        scratch.path(),
    )?;
    capture.start();
    capture.ingest(&pcm(&original)?, true);
    let wav = capture
        .stop()
        .into_iter()
        .find_map(|e| {
            if let Event::Segment { wav, .. } = e {
                Some(wav)
            } else {
                None
            }
        })
        .ok_or_else(|| io::Error::other("missing committed audio"))?;
    drop(capture);
    let before = std::fs::read(wav.path())?;
    std::fs::write(out.join("reference-segment.wav"), &before)?;
    let start = 2.;
    let end = 5.;
    let began = Instant::now();
    eprintln!("[language correction] running installed ASR on a 3.4-second padded JFK clip");
    let mut task = CorrectionTask::start(
        Configuration::new(
            Resources {
                executable: engine.clone(),
                model: model.clone(),
                bpe: assets.join("WHISPER_BPE.bin"),
                assets,
            },
            50259,
        ),
        wav.clone(),
        start,
        end,
    )?;
    let result = task.wait().await?;
    let elapsed = began.elapsed().as_secs_f64();
    let unchanged = std::fs::read(wav.path())? == before;
    let dir = wav.directory().to_owned();
    drop(wav);
    let cleanup = !dir.exists() && std::fs::read_dir(scratch.path())?.next().is_none();
    eprintln!("[language correction] inference complete; checking model/source/engine hashes");
    let hashes_unchanged = digest(&source)? == source_sha
        && digest(&model)? == model_sha
        && digest(&engine)? == engine_sha;
    let passed =
        result.as_ref().is_some_and(|s| !s.is_empty()) && unchanged && cleanup && hashes_unchanged;
    let report = json!({"status":if passed{"passed"}else{"failed"},"start":start,"end":end,"pad":0.2,"languageToken":50259,"text":result,"inferenceSeconds":elapsed,"sourceSHA256":source_sha,"engineSHA256":engine_sha,"modelSHA256":model_sha,"inputSegmentUnchanged":unchanged,"sourceModelEngineUnchanged":hashes_unchanged,"ownedAudioCleaned":cleanup,"devicesOpened":false,"scope":"Actual installed ASR with owned cropped public PCM and forced language; no transcript mutation, user audio, quality or UI acceptance."});
    std::fs::write(
        out.join("rust-report.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!("{}", serde_json::to_string_pretty(&report)?);
    if !passed {
        return Err(io::Error::other("installed correction probe failed"));
    }
    Ok(())
}
