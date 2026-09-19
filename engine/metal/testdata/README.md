# Live-transcription test fixtures

Real-world fixtures for the live meeting-transcription pipeline
(`engine/metal/live_transcribe.sh` + resident `transcribe` STREAM mode).

## `wife_conv_3min.wav`
- **~153 s**, 16 kHz mono, two speakers, **Korean with English tech terms**
  (온디바이스 AI, SLM, speculative decoding, architecture, inference, GEMMA, …).
- A natural conversation about on-device AI / small language models — a good
  stress test for: code-switching (KO+EN), multi-speaker diarization, long-form
  chunking, and the hallucination guard.
- **Local-only** (personal recording — git-ignored, not committed).

### Generate a transcript / subtitles
```bash
cd engine/metal
./live_transcribe.sh --replay testdata/wife_conv_3min.wav -m ko-meeting \
  --md /tmp/conv_3min.md --srt /tmp/conv_3min.srt
```
Resident pipeline processes the 153 s clip in ~35 s (≈4× real-time).

The transcript and subtitles of this recording are **not part of the tree**: it is
a private conversation, so its outputs stay local like the WAV (`.gitignore`
refuses `*.srt` and `*_conv_*.md` here). Reference copies were committed until
2026-09-19 and were removed ahead of the public release; older revisions keep
them in git history.

### Known transcription quirks (model-level, expected)
- Code-switched English is mostly correct (`Exactly`, `inference`, `accept`,
  `architecture`) but some terms slip (`제너레이션`→`데너레이션`, `Claude`→`글로드`,
  `breakthrough`→`브래크스롯`).
- A few **timestamp inversions** (e.g. 01:56 before 01:39): Whisper occasionally
  hallucinates an out-of-window word time. The `segend` dedup guard prevents
  content *loss* from this, but the displayed line time can still be off.
- Brief speaker mis-attribution at turn boundaries (a stray `Speaker 2`).

## Regression check
```bash
cd engine/metal
bash testdata/check.sh
```
Runs the pipeline on the fixture (if present) and asserts key properties
(expected KO+EN keywords, ≥2 speakers, transcript length). Skips cleanly when
the local-only WAV is absent.
