# Madi — Apple Silicon (Metal)

Self-contained Whisper **large-v3-turbo** speech-to-text for Apple Silicon, with
**word timestamps**, **speaker diarization** (who-said-what), **language
auto-detection**, long-audio chunking, and a **near-real-time live meeting mode**
(mic → streaming speaker-attributed transcript, `.md`/`.srt` export). Pure Zig +
Metal/MSL + Apple system frameworks (Metal, MPS, Accelerate) — **no
Python/PyTorch/onnxruntime at runtime**. Korean guide: [README_KR.md](README_KR.md).

> Highlights: peak RSS **1.05 GB** (Q8 + streaming loader), Whisper decode
> **~402 tok/s** (jfk) / **~485–496 tok/s** steady, diarization **9.67% DER** on
> VoxConverse dev (beats pyannote 3.1 SOTA ~11.2%).
> Full status: [`engine/metal/STATUS.md`](engine/metal/STATUS.md).

## The primary flow: a local-first macOS app

Madi's wedge is a **native on-device meeting engine** — not another configurable
AI-provider wrapper. The whole core path runs on your Mac with **no account, no
API key, no cloud**:

1. **Install** `Madi.app` (build locally with `apps/macos/scripts/make_app.sh`, or
   ship a signed DMG — see [docs/RELEASE.md](docs/RELEASE.md)).
2. **Model ready** — on first launch the ~830 MB speech model downloads once into
   Application Support, SHA-256 verified. A setup gate blocks recording until it's
   ready (progress / cancel / retry / re-download all recoverable).
3. **Record or replay** a meeting → a **live, speaker-attributed transcript** with
   word timestamps.
4. **Export** to Markdown (speaker labels + timecodes) or `.srt` subtitles.
5. **Optionally** enable on-device **translation / summaries / Q&A / titles** — a
   separate ~2.6 GB local LLM, downloaded on demand from Settings. Transcription
   never depends on it; only those features are gated until it's installed.

See [docs/DEMO.md](docs/DEMO.md) for a reproducible transcript/export proof from a
clean checkout. Differentiators: speaker diarization, word timestamps, voiceprints,
dictation, and fully local translation/summary/Q&A.

The rest of this README documents the underlying **Zig + Metal engine** (built and
run from `engine/metal/`), which the app embeds. Cross-platform (Windows/Linux)
support is tracked but **not** part of the current wedge — see
[docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md).

## Requirements
- Apple Silicon (M1 or newer), macOS with the Xcode command-line tools (`xcrun metal`).
- [Zig](https://ziglang.org) 0.14.x.
- `ffmpeg` (to convert audio to 16 kHz mono WAV).
- Python 3 (only for one-time **asset generation**, not for inference).

## Setup
All commands run from `engine/metal/`.

1. **Model + tokenizer assets** (`engine/metal/assets/`): you need
   `model.safetensors` (Whisper large-v3-turbo) plus the HF tokenizer/config
   files (`tokenizer.json`, `generation_config.json`, `added_tokens.json`, …).
   Then generate the binaries:
   ```bash
   cd engine/metal/assets && python3 gen_assets.py   # → mel_filters.bin, WHISPER_BPE.bin, suppress_tokens.bin
   ```
2. **Diarization model** (Apache-2.0 wespeaker ResNet34, ~25 MB):
   ```bash
   cd engine/metal && bash bench/gen_diar_assets.sh  # → assets/resnet34_diar.bin, assets/kaldi_melbank.bin
   ```

## Build
```bash
cd engine/metal && bash build.sh transcribe.zig     # → out/transcribe
```

## Run
```bash
# audio must be 16 kHz mono WAV:
ffmpeg -y -i input.m4a -ar 16000 -ac 1 meeting.wav

./out/transcribe <model.safetensors> <audio.wav> <WHISPER_BPE.bin> [out.rttm] [num_speakers]
```
- `out.rttm` (optional): write the speaker timeline as RTTM (for DER scoring).
- `num_speakers` (optional): `0`/absent → **auto-detect** the count; `N` → force N speakers.

Examples:
```bash
./out/transcribe assets/model.safetensors meeting.wav assets/WHISPER_BPE.bin          # auto everything
./out/transcribe assets/model.safetensors meeting.wav assets/WHISPER_BPE.bin out.rttm 4  # force 4 speakers + RTTM
```

### Output sections
`[perf]` timing · per-chunk text · `=== TRANSCRIPTION ===` (full text) ·
`=== WORD TIMESTAMPS ===` · `=== SPEAKER TIMELINE ===` ·
`=== SPEAKER-ATTRIBUTED TRANSCRIPT ===` ("[t] Speaker N: …").

### Tuning knobs (environment variables, no rebuild)
| var | default | meaning |
|---|---|---|
| `DIAR_K` | 0 (auto) | force speaker count |
| `DIAR_MAXK` | 6 | max clusters for auto-K |
| `DIAR_SIL_TAU` | 0.10 | below this silhouette → single speaker |
| `DIAR_VAD` | 0.40 | energy-VAD threshold (× median RMS) |
| `WHISPER_LANG_ID` | auto | force language token (e.g. 50259 en, 50264 ko) |
| `ENC_BATCH` | 4 (file) / 1 (live) | encode N 30s chunks in one batched forward — amortizes weight reads + dequant (~8% faster encoder on long files, byte-identical output) |
| `DIAR_RECLUSTER` | 16 | live mode: re-cluster all speaker embeddings every N windows (batch k-means + stable id remap; 0 = old online-only) |

## Live meeting transcription (near-real-time)

`engine/metal/live_transcribe.sh` turns the file-based `transcribe` into a streaming,
**timestamped, speaker-attributed** meeting transcriber. It captures the mic (any
avfoundation device) into rolling N-second segments and transcribes each one the
moment it closes. Latency trails live audio by roughly **N + overlap + decode (~3s)**.

One command is all you need:
```bash
cd engine/metal
./live_transcribe.sh --mode ko-meeting                       # Korean multi-speaker meeting
./live_transcribe.sh -m en-meeting --md notes.md --srt notes.srt   # English + save transcript & subtitles
./live_transcribe.sh --replay meeting.m4a -m ko              # transcribe a recording (no mic)
./live_transcribe.sh --help                                  # full option list
./live_transcribe.sh --list-devices                          # find your mic index
```

What it does beyond naive chunking:
1. **Sliding-window overlap** — each segment carries `--overlap` seconds of
   left-context and holds back its trailing word, so words split across a
   boundary are recovered, not mangled ("country", not "company").
2. **Consistent speaker IDs** — an online clusterer keeps the **same id for the
   same voice** across the whole session (not reset per segment).
3. **Resident, single-process pipeline** — the 1.6 GB model + diarization run in
   **one resident process** (STREAM mode over a FIFO); no per-segment reload, no
   external diarization processes. ~20% faster; language is detected once then
   fixed (no per-segment language flapping). `--no-resident` falls back.
4. **Hallucination guard** — drops invented words in near-silent stretches
   (loud speech is always kept). Tune with env `HALLU_RMS` (0.020) / `HALLU_GUARD=0`.
5. **Output** — colourized console (`--color auto|always|never`), live Markdown
   (`--md`) and SRT subtitles (`--srt`).

### Modes (`--mode`) — preset bundles; any flag overrides a preset
| mode | preset |
|---|---|
| `ko` / `en` | Korean/English forced, speakers on, 8 s |
| `meeting` | multi-speaker, 10 s, auto language |
| `ko-meeting` / `en-meeting` | meeting + Korean/English forced |
| `dictation` | single speaker (no diarization), text only |
| `fast` | lowest latency (5 s, 2 s overlap, no diarization) |
| `auto` | plain defaults (default) |

### Options
| flag | default | meaning |
|---|---|---|
| `-m, --mode <name>` | auto | scenario preset (table above) |
| `-d, --device <n>` | 2 | avfoundation audio device index |
| `-s, --seg <sec>` | 10 | segment length; longer = better diarization |
| `-o, --overlap <sec>` | 3 | left-context; 0 disables boundary recovery |
| `-l, --lang <id>` | auto | `ko`/`en`/`ja`/`zh`/`auto` or a raw token id |
| `--diar <0\|1>` / `--no-diar` | 1 | consistent speaker attribution |
| `--sim <f>` / `--maxk <n>` | 0.40 / 8 | new-speaker cosine threshold / max speakers |
| `--duration <sec>` | — | stop after N seconds (else Ctrl-C) |
| `--replay <wav>` | — | transcribe a recorded file instead of the mic |
| `--md <file>` / `--srt <file>` | — | also write a Markdown transcript / SRT subtitles |
| `--color <when>` / `--no-color` | auto | colourize speakers (auto = TTY only) |
| `--speakers <map>` | — | name speakers, e.g. `"0=Alice,1=Bob"` (console + .md + .srt) |
| `--voiceprints <dir>` | — | voice enrollment: speakers you name are enrolled at session end; in later sessions enrolled voices are **auto-named by voice alone** (`VP_SIM` tunes the match, default 0.40) |
| `--no-resident` | (resident on) | one process per segment (debug) |
| `--keep` | off | keep temp WAVs + state on exit |
| `--list-devices` / `-h, --help` / `--version` | | list devices / help / version |

Every flag also reads its same-named env var (flags win). `--lang` uses a
dedicated var, so it never collides with the shell locale `$LANG`.

> **Mic permission**: on first run macOS asks the GUI app hosting this shell
> (Terminal / iTerm) for Microphone access — grant it in System Settings →
> Privacy & Security → Microphone, then re-run.
>
> **Limits**: short segments crossing a speaker turn can flip mid-sentence
> (use 8–10 s); Whisper may still mis-time/hallucinate words on noisy audio.
> For the most accurate final copy, run the whole WAV through `transcribe` once
> after the meeting. See `testdata/` for a KO+EN regression fixture.

## Performance

All figures are wall-clock or `vmmap -summary` measurements on the same **M4 Pro**,
not projections. Two engines ship in the app and are measured separately.

### Transcription — `transcribe` (Sovereign Whisper)

jfk fixture, remeasured 2026-06-19. Canonical copy:
[`engine/metal/STATUS.md`](engine/metal/STATUS.md); history in
[`engine/metal/PERF_LOG.md`](engine/metal/PERF_LOG.md).

| metric | baseline | now |
|---|---|---|
| conv front-end | ~95 ms | **~15 ms** |
| encoder / 30 s chunk | 1390 ms | **~568 ms** · **~125 ms/chunk** at batch-4 |
| encoder, live (`AUDIO_CTX=auto`) | — | **~250–300 ms/segment** |
| decode | 134 tok/s | **~402 tok/s** (jfk, 26 tok) · **~485–496 tok/s** steady |
| peak RSS | 4.78 GB | **1.05 GB** (jfk) · 1.26 GB (3-min, batch-4 resident) |
| live (153 s KO+EN, resident) | — | **~35 s (≈4× real-time)** |
| accuracy | — | LibriSpeech **2.17%** clean / **4.19%** other WER · FLEURS-ko CER **4.05%** |

Accuracy is `PERF_LOG` W-1/W-2b: 2620 + 2939 utterances, official Whisper normaliser
+ jiwer; the Korean CER is the product path with zero empty hypotheses. Reference
large-v3 publishes clean 2.0 / other 3.9 — so Q8 quantisation and a hand-written
Metal pipeline land at reference-grade quality.

The encoder is at the Metal-4 tensor-op ceiling (beats MPS 1.18×) and Whisper decode
is occupancy-bound rather than bandwidth-bound — both closed by measurement, so
bandwidth-style optimisations do not apply there.

### Live translation — `translate-engine-{2b,4b}` (DNA3)

Optional feature, measured 0.1.4 → 0.1.5. `B` is a turn's prefill token count;
B ≈ 14–33 is the live-caption band. **Footprint** is GPU weights, **RSS** whole
process. Canonical copy: `sovereignLLM/apps/metal-dna3-4b-q4km/PERF_MATRIX.md`.

| tier | | footprint | RSS | prefill B=14 | decode |
|---|---|---:|---:|---:|---:|
| **4B** (16 GB+) | 0.1.4 | 5.5 G | 7.53 G | 153.4 ms | 62.4 tok/s |
| | **0.1.5** | **3.3 G** | **5.34 G** | **69.8 ms** | **64.7 tok/s** |
| **2B** (8 GB) | 0.1.4 | 2.6 G | 3.54 G | 59.6 ms | 125.3 tok/s |
| | **0.1.5** | **1.5 G** | **2.52 G** | **31.5 ms** | **124.1 tok/s** |

0.1.4 → 0.1.5: footprint **−40%** (4B) / **−42%** (2B), RSS −29%, prefill at B=14
**−54%** / **−47%**. Decode is essentially flat — the wins are time-to-first-token
and memory, which is what a live caption feels.

One caption turn end-to-end (B=14 source, ~30 output tokens): 4B **634 → 534 ms**,
2B **300 → 274 ms**. With 3 target languages the prefill saving triples.

Session budget (translate + whisper), which is what decides the 8 GB tier:

| machine | 0.1.4 | 0.1.5 | headroom gained |
|---|---|---|---|
| 8 GB (2B) | 3.9 G | **2.8 G** | +1.1 G |
| 16 GB (4B) | 6.8 G | **4.6 G** | +2.2 G |

Transcription did not change in that cycle; those rows are the baseline, not a result.

## Version history

Released builds are published to the S3 `stable` channel and served through
CloudFront; the in-app updater reads `channels/stable/latest.json`. Release
mechanics and the git-tag rule are in [docs/RELEASE.md](docs/RELEASE.md).

| version | published | tag | highlights |
|---|---|---|---|
| **0.1.5** | 2026-07-26 | `v0.1.5` | Stable speaker numbers — the main speaker keeps *Speaker 1* instead of drifting as the clusterer renumbers; `화자분리중…` while a label is undecided, with a 300 s commit timeout (#229). DNA3 translate engine 0.1.5: footprint −40%, prefill −54% at B=14. Corrected translate tier memory constants (#228). Per-turn DNA watchdog + engine relaunch (#227). Side-panel redesign (#220), input-picker drop-up fix (#217). |
| **0.1.4** | 2026-07-22 | `v0.1.4` | Korean diarization robustness (#226), countdown start-admission fix (#225), first-run model onboarding (#224), system-audio permission UX (#223). |
| 0.1.3 | 2026-07-22 | — | Same source as 0.1.4 (`450e527`), rebuilt and republished the same day. No separate tag: `v0.1.4` already marks that tree, so a second tag would only make `git describe` ambiguous. |
| **0.1.2** | 2026-07-20 | `v0.1.2` | M1 / 8 GB live translation on the DNA3-2B tier (#221) and its 8 GB guide (#222); reproducible local S3 releases across operators (#219). |
| **0.1.1** | 2026-07-20 | `v0.1.1` | Live-diarization silence-birth fix (#218); updates made independent of GitHub delivery (#215). |
| **0.1.0** | 2026-07-19 | `v0.1.0` | First official stable release. Diarization on/off toggle (#216), S3 release channel. |

## Project layout
- `apps/macos/` — the native macOS app (SwiftUI). Pure-logic core is covered by `swift test` (`cd apps/macos && swift test`); packaging scripts live in `apps/macos/scripts/`.
- `engine/metal/transcribe.zig` — full pipeline (mel → conv → encoder → decoder → BPE, timestamps, diarization) + resident STREAM mode for live use.
- `engine/metal/encoder.zig`, `decoder.zig`, `mel.zig`, `diar_resnet.zig` — modules.
- `engine/metal/live_transcribe.sh` — near-real-time meeting runner (mic capture, overlap, resident pipeline, colour/`.md`/`.srt`).
- `engine/metal/merge_seg.awk` — merges word timestamps with speaker labels (overlap dedup, speaker carry-over).
- `engine/metal/online_diar.zig`, `diar_embed_wav.zig` — standalone diar tools (used by the `--no-resident` fallback).
- `engine/metal/kernels/*.metal` — Metal kernels. `engine/metal/metal_backend.{m,h}` — ObjC bridge.
- `engine/metal/bench/` — DER benchmark harness + diarization study docs. `engine/metal/testdata/` — live-pipeline regression fixture.
- Docs: `engine/metal/STATUS.md` (current state), `engine/metal/PERF_LOG.md` (history),
  `engine/metal/PORT.md` (CUDA→Metal port notes), `engine/metal/bench/*.md`.

## License / provenance
Inference code is original work of this project. It reuses two third-party models,
whose notices are retained as required and reproduced in full:

- **OpenAI Whisper** large-v3-turbo — **MIT License**, © 2022 OpenAI
  (transcription). MIT requires keeping the copyright + permission notice.
- **WeSpeaker** ResNet34 — **Apache License 2.0**, © the WeSpeaker authors
  (diarization; VoxCeleb-trained — verify dataset terms for commercial use).
  Apache-2.0 requires keeping the NOTICE + license and stating changes.

See [`NOTICE`](NOTICE) and [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)
for the attributions and full license texts; source headers in
`engine/metal/transcribe.zig` and `engine/metal/diar_resnet.zig` carry the same notices.
