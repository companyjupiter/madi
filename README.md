# Madi — Apple Silicon (Metal)

Self-contained Whisper **large-v3-turbo** speech-to-text for Apple Silicon, with
**word timestamps**, **speaker diarization** (who-said-what), **language
auto-detection**, long-audio chunking, and a **near-real-time live meeting mode**
(mic → streaming speaker-attributed transcript, `.md`/`.srt` export). Pure Zig +
Metal/MSL + Apple system frameworks (Metal, MPS, Accelerate) — **no
Python/PyTorch/onnxruntime at runtime**. Korean guide: [README_KR.md](README_KR.md).

> Highlights: peak RSS **1.1 GB** (Q8 + streaming loader), decode **~188 tok/s**,
> diarization **9.67% DER** on VoxConverse dev (beats pyannote 3.1 SOTA ~11.2%).
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

## Performance (jfk, M4 Pro)
| | baseline | now |
|---|---|---|
| encoder/chunk | 1390 ms | ~653 ms |
| decode | 134 tok/s | ~188 tok/s |
| peak RSS | 4.78 GB | **1.11 GB** |
| live (153 s KO+EN, resident) | — | **~35 s (≈4× real-time)** |

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
