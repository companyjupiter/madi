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
> Everything the project has built so far, with where it lives and how it was measured: [Assets](#assets--what-exists-where-it-lives-how-it-is-verified).

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
| | *unreleased* | *3.20 G* | *5.23 G* | *unchanged* | *68.5 tok/s* |
| **2B** (8 GB) | 0.1.4 | 2.6 G | 3.54 G | 59.6 ms | 125.3 tok/s |
| | **0.1.5** | **1.5 G** | **2.52 G** | **31.5 ms** | **124.1 tok/s** |
| | *unreleased* | *1.54 G* | *2.49 G* | *unchanged* | *130.8 tok/s* |

The *unreleased* rows are on `main` and not in any published build. Two engine changes
since 0.1.5, both byte-identical in output:

1. **Per-layer V/W2 Q6_K packed** to 6.5-bit `ql`/`qh` with the raw GGUF blocks dropped —
   decode **+3.4%** (4B) / **+2.4%** (2B), RSS −150 MB / −65 MB.
2. **Fused-FFN exec split (r2)** on the **4B only** — a further **+0.88%**, no memory
   change. It measured as *not* a win on the 2B (+0.34% at t=0.43, with double the
   run-to-run spread), so the 2B deliberately keeps the old split.

Each model was measured on itself; neither result was carried over from the other. The
r2 figures come from cooled, order-alternating pairs — on this hardware an uncooled or
fixed-order run moves a 1% effect by more than the effect itself.

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

## Assets — what exists, where it lives, how it is verified

Everything below is in this repository (or in the sibling `sovereignLLM` repo for the
translate engines) and was **kept only after a measurement** — the rule of the project.
Refuted levers are recorded in the same ledgers as the wins. Canon documents are named
per row; when a row and a canon disagree, the canon wins.

### Runtime engines (shipped in `Madi.app`)

| asset | what it is | where | verified by |
|---|---|---|---|
| **Sovereign Whisper** `transcribe` | Whisper large-v3-turbo, Q8, pure Zig + Metal; file mode and resident **STREAM** mode (5 s windows + overlap, word timestamps, `PREVIEW` lane, `%%FP` forced prefix, `EVENTS_FILE` JSONL contract) | `engine/metal/transcribe.zig`, `encoder.zig`, `decoder.zig`, `mel.zig`, `kernels/` | LibriSpeech 2.17 / 4.19 % WER, FLEURS-ko 4.05 % CER, jfk decode ~402 tok/s, peak RSS 1.05 GB — [`engine/metal/STATUS.md`](engine/metal/STATUS.md) |
| **Speaker diarization** | WeSpeaker ResNet34 embeddings + online clustering with periodic re-cluster (`DIAR_RECLUSTER`), overlap detection (pyannote seg-3.0), Silero VAD gate, fixed-K + Unknown bucket, ON/OFF toggle | `diar_resnet.zig`, `online_diar.zig`, `osd_pyannote.zig` | 9.67 % DER VoxConverse dev; live DER/UX gates in `engine/metal/bench/` — [`docs/DIAR_EVAL.md`](docs/DIAR_EVAL.md) |
| **DNA3.0-4B / 2B translate engines** | GGUF Q4_K_M runners for the on-device LLM (translation, summary, Q&A, titles). Turn REPL: `%%TRN` (turn + example pair), `%%PFX` (registered prefix slots), ` %%FP ` (forced prefix), ` %%MAX n` (per-turn cap); embedding-window-only weight mapping (RSS 5.4 → 2.5 GB, 4B) | `sovereignLLM/apps/metal-dna3-{4b,2b}-q4km/main.zig` (canon `PERF_MATRIX.md` there) | prefill B=14 69.8 ms / decode 64.7 tok/s (4B); memory budget for the 8/16 GB tiers ≈ 4.05 GB with Whisper — PERF_LOG M1 |
| DNA3.0-9B tier (24 GB+) | Engine side complete (turn protocol 6/6, mmap release, 8192 context +233 MB); app wiring and GGUF hosting **on hold since 2026-09-07** | `sovereignLLM/apps/metal-dna3-9b-q4km/` | — |

Engine levers that ship (each has a PERF_LOG entry with the measurement): decoder
sequence prefill of the glossary seed (S1, −155 ms/pass) · preview forced prefix (S2,
preview decode −38 %) · interim forced prefix (T1, −23 %) · previous (source ⇒
translation) pair as the prompt example (T5) · glossary → decoder bias, gated to the
languages it was measured on (S4, P6) · partial-freeze against run-on hallucinations
(`PARTIAL_MAX_TOK`) · batched encoder (`ENC_BATCH`), F16 encoder cache, `AUDIO_CTX=auto`
(first text ~1.8 s) · leak-free preview lane (M2 +23 MB/min and M3 +2.3 MB/min fixed;
`LEAK_CHECK` DebugAllocator build for regressions).
Refuted and recorded: previous-text conditioning (S3), decode-occupancy levers (S5),
int8 prefill, engine-side speaker-id cap (D1), fine-tuned third-party weights as a
drop-in, madvise on the weight mapping, an engine centroid merge is still a candidate.

### macOS app (`apps/macos/Sovereign`, SwiftUI; headless core in `Package.swift`)

| asset | what it does | canon |
|---|---|---|
| Live pipeline: `WordMerger` → `TranscriptStore` → `TranscriptView` | Overlap dedup + held-word holdback with the **view applying the same seam rules** (X1), seam-duplicate and window-tail-stub guards (L2, X2); **decided-once boundary ledger** (P15) recorded only between settled words, same-speaker neighbour joins after a label fix (L1), one-word turn heads adopt the next speaker (X4); rows = sentences, detailed view groups a speaker's consecutive rows into turns (U1) | [`PERF_LOG.md`](PERF_LOG.md) P15 · L1 · L2 · X1 |
| Speaker display | Numbers only after 10 s of speech per id, `화자분리중…` before (S1); stable numbering across re-clusters; voiceprint auto-naming; AI speaker/language reconcile at stop | PERF_LOG S1 · [`docs/DIAR_EVAL.md`](docs/DIAR_EVAL.md) |
| Translation lane: `TranslateEngine`, `TranslationTurnQueue`, `DNAEngineBroker` | Committed-first priority queue, fragment coalescing, secondary-target shedding with stop-time backfill, stale-keep display, runaway bound (T7: engine `%%MAX` + app truncation + example-poisoning guard), echo stripper that never cuts a revision's shared prefix (T8), no token streaming to the panel (T9), per-turn watchdog with terminate + relaunch | [`docs/LIVE_TRANSLATE.md`](docs/LIVE_TRANSLATE.md) · [`docs/TRANSLATE_DISPLAY_STABILITY.md`](docs/TRANSLATE_DISPLAY_STABILITY.md) (NE < 0.2 stable-prefix policy; live panel NE 0.24–0.27) |
| Meeting intelligence | Summary templates (meeting / lecture / interview, one spine), rolling live summary (built, currently unwired), Q&A, titles, action items | [`docs/MEETING_INTELLIGENCE.md`](docs/MEETING_INTELLIGENCE.md) · [`docs/SUMMARY_TEMPLATES.md`](docs/SUMMARY_TEMPLATES.md) · [`docs/LIVE_SUMMARY.md`](docs/LIVE_SUMMARY.md) |
| Capture | Mic (device picker), **system audio** via ScreenCaptureKit (Teams / Zoom / YouTube), both; countdown gated on capture readiness; silence warning | [`docs/SYSTEM_AUDIO.md`](docs/SYSTEM_AUDIO.md) · [`apps/macos/VERIFY_CAPTURE.md`](apps/macos/VERIFY_CAPTURE.md) |
| Debug mode (D1) | Settings → 진단, or `MADI_DEBUG=1`: one bundle per session under `~/Library/Application Support/Madi/debug/<stamp>/` — exact engine bytes (`env.txt`, `stdin.log`, `wav/`, `stdout.log`, events copy), `store.jsonl` (boundary / merge / join / ledger-flip / spk), `translate.jsonl` (turn / result / shed / wedge / relaunch), `watchdog.jsonl`, `mem.jsonl`, `session.json` | [`docs/DEBUG_MODE.md`](docs/DEBUG_MODE.md) |
| Product surfaces | KO / EN / JA UI, 4-language manual (`docs/manual/`), dictation, editor & reader features, `.md` / `.srt` / JSON export, first-run model onboarding (SHA-256 verified), Sparkle self-update from the S3 channel, beta expiry latch, design tokens synced from Figma | [`apps/macos/DESIGN.md`](apps/macos/DESIGN.md) · [`docs/EDITOR_FEATURES.md`](docs/EDITOR_FEATURES.md) · [`design/README.md`](design/README.md) |

### Measurement and verification tooling

| tool | purpose | run |
|---|---|---|
| `swift test` (SovereignCore) | 649 headless tests over the merger, store ledger, translation queue, shedding, runaway, stale-keep, numbering, debug log | `cd apps/macos && swift test` |
| Capture replay gate | Replays a session's `stdout.log` byte-for-byte through the real Decoder → TranscriptStore and prints lines / unexplained breaks / seam-dup rows / dup words / overlap rows / turn-head rows / numbering, with each lever off and on | `MADI_CAPTURE_STDOUT=<bundle>/stdout.log swift test --filter CaptureFragmentationGateTests` |
| Events gate | Same over the engine's `EVENTS_FILE` JSONL (`MADI_EVENTS_JSONL=…`); note it cannot see view-state defects such as X1 | same test class |
| `bench/live_capture/` | `tee_transcribe.py` records the real app → engine stream; `replay_capture.py` / `replay_faithful.py` replay it offline (works on a debug bundle) | [`engine/metal/bench/live_capture/README.md`](engine/metal/bench/live_capture/README.md) |
| `longwatch.sh` | 10 s collector: CPU / RSS / threads per process, GPU utilisation, compressor, plus a main-thread `sample` every 5 min; the source of every live CPU/memory number in PERF_LOG | `engine/metal/bench/wer_runs/prof/longwatch.sh` (`LW_OUT`, `LW_MT`) |
| `t1_harness.py` | Drives a translate engine through the turn protocol from recorded turns (a bundle's `translate.jsonl` is a valid input) | `engine/metal/bench/wer_runs/t1_harness.py` (`ENGINE`, `MODEL`) |
| Quality benches | `wer_bench.py` (LibriSpeech / FLEURS, official normaliser + jiwer), DER harness (AMI, VoxConverse), `ko_diar_gate.py`, `live_ux_gate.py`, `preview_lane_gate.py`, VAD campaigns, engine A/B ([`docs/ENGINE_EVAL.md`](docs/ENGINE_EVAL.md): Qwen3-ASR-1.7B 4.60 % vs Whisper turbo 5.63 % CER on FLEURS-ko, not adopted on the 8 GB tier) | `engine/metal/bench/` ([README](engine/metal/bench/README.md)) |
| Leak variant | `transcribe` built with the DebugAllocator (`LEAK_CHECK`, ReleaseSafe/Debug) reports leaks at exit; synthetic preview/seg streams for long-run checks | `engine/metal/build.sh transcribe.zig`, see PERF_LOG M2/M3 |
| Quark trees | Symbol-level topology of the engine and the app for AI navigation and post-commit freshness (`sovereign_metal_whisper`, `sovereign_whisper_app`, `sovereign_metal_dna3_{2b,4b,9b}`) | `~/antigravity/quark/q.sh regen configs/<cfg>.mjs` |
| Ledgers | [`PERF_LOG.md`](PERF_LOG.md) — 42 dated entries (2026-07-05 → 2026-09-07) with the numbers, wins and refutations; [`engine/metal/PERF_LOG.md`](engine/metal/PERF_LOG.md) — engine history; [`docs/BACKLOG.md`](docs/BACKLOG.md) — considered, not started | — |

### Release pipeline

`apps/macos/scripts/madi_release.sh build|upload|publish <version>` is the single entry
(the `skills/madi-release` skill drives it): `make_app.sh` (explicit source list) →
`verify_release_bundle.sh` → DMG → Developer ID sign + notarize + staple when the
identity is present (ad-hoc otherwise) → immutable S3 upload → channel publish. The
updater reads `channels/<channel>/latest.json` and `appcast.xml` through CloudFront and
verifies size + SHA-256 + URL; `releases/index.json` is the published-version canon.
[`docs/RELEASE.md`](docs/RELEASE.md) holds the smoke checklist and the tag rule.

### Companion utilities

`tools/` (captions, minutes, SRT broadcast over the events contract —
[`docs/EVENTS.md`](docs/EVENTS.md)), `web/` (events dashboard + bridge server, fixtures),
`design/` (Figma ↔ app token sync).

## Version history

Released builds are published to the S3 `stable` channel and served through
CloudFront; the in-app updater reads `channels/stable/latest.json`. Release
mechanics and the git-tag rule are in [docs/RELEASE.md](docs/RELEASE.md).

Published versions (S3 `releases/index.json`): 0.1.0 → 0.1.5 below, then **0.1.6**
(2026-07-31, Sparkle self-update), **0.1.7** (2026-08-05, translation display stability:
NE-measured stable-prefix policy), **0.1.8** (2026-08-10, sentence hand-off without
erasure + stability ledger file), **0.1.9** (2026-08-11, surface-correction rebind),
**0.2.0** (2026-08-30, decided-once boundary ledger — mid-session re-clusters no longer
collapse live rows), **0.3.0** (2026-08-31, summary templates + live summary tab),
**0.3.1** (2026-09-02, engine headroom batch: seed prefill, forced-prefix preview and
interim, context example), **0.3.7** (2026-09-03, live profiling rounds P0–P4: main-thread
saturation, translation backlog, line-count-proportional CPU, STT loop guard) — the
current `stable`. 0.3.8 → 0.3.19 are local verification builds (ad-hoc signed, one
per PERF_LOG round: language gate P5/P6, memory M1–M3, line joins L1/L2, translation
bounds T7–T9, debug mode D1, deferred speaker numbers S1, turn grouping U1, seam view
rules X1/X2/X4); publishing them is a separate decision.

| version | published | tag | highlights |
|---|---|---|---|
| **0.1.5** | 2026-07-26 | `v0.1.5` | Stable speaker numbers — the main speaker keeps *Speaker 1* instead of drifting as the clusterer renumbers; `화자분리중…` while a label is undecided, with a 300 s commit timeout (#229). DNA3 translate engine 0.1.5: footprint −40%, prefill −54% at B=14. Corrected translate tier memory constants (#228). Per-turn DNA watchdog + engine relaunch (#227). Side-panel redesign (#220), input-picker drop-up fix (#217). |
| **0.1.4** | 2026-07-22 | `v0.1.4` | Korean diarization robustness (#226), countdown start-admission fix (#225), first-run model onboarding (#224), system-audio permission UX (#223). |
| 0.1.3 | 2026-07-22 | — | Same source as 0.1.4 (`450e527`), rebuilt and republished the same day. No separate tag: `v0.1.4` already marks that tree, so a second tag would only make `git describe` ambiguous. |
| **0.1.2** | 2026-07-20 | `v0.1.2` | M1 / 8 GB live translation on the DNA3-2B tier (#221) and its 8 GB guide (#222); reproducible local S3 releases across operators (#219). |
| **0.1.1** | 2026-07-20 | `v0.1.1` | Live-diarization silence-birth fix (#218); updates made independent of GitHub delivery (#215). |
| **0.1.0** | 2026-07-19 | `v0.1.0` | First official stable release. Diarization on/off toggle (#216), S3 release channel. |

## Project layout
- `apps/macos/` — the native macOS app (SwiftUI). `Sovereign/{Audio,Engine,Transcript,UI,Model,Dictation,AppInfo}`;
  the pure-logic core is the `SovereignCore` target of `Package.swift`, covered by `swift test` (`Tests/SovereignCoreTests`);
  packaging and release scripts in `scripts/`; product design in `DESIGN.md`.
- `engine/metal/transcribe.zig` — full pipeline (mel → conv → encoder → decoder → BPE, timestamps, diarization) + resident STREAM mode for live use.
- `engine/metal/encoder.zig`, `decoder.zig`, `mel.zig`, `diar_resnet.zig`, `online_diar.zig`, `osd_pyannote.zig` — modules.
- `engine/metal/live_transcribe.sh` — near-real-time meeting runner (mic capture, overlap, resident pipeline, colour/`.md`/`.srt`).
- `engine/metal/merge_seg.awk` — merges word timestamps with speaker labels (overlap dedup, speaker carry-over).
- `engine/metal/kernels/*.metal` — Metal kernels. `engine/metal/metal_backend.{m,h}` — ObjC bridge.
- `engine/metal/bench/` — WER/CER and DER harnesses, live UX gates, VAD campaigns, `live_capture/` replay, `wer_runs/prof/` collectors and harnesses. `engine/metal/testdata/` — live-pipeline regression fixture.
- `docs/` — canon documents (listed in the asset tables above); `docs/manual/` — the 4-language user manual.
- `tools/`, `web/`, `design/`, `skills/` — companion utilities, events dashboard, Figma token sync, the release skill.
- Ledgers: `PERF_LOG.md` (app + engine rounds since 2026-07), `engine/metal/STATUS.md` (current engine state), `engine/metal/PERF_LOG.md` (engine history), `engine/metal/PORT.md` (CUDA→Metal port notes).

## License / provenance
Inference code is original work of this project. It reuses five third-party models,
whose notices are retained as required and reproduced in full:

- **OpenAI Whisper** large-v3-turbo — **MIT License**, © 2022 OpenAI
  (transcription). MIT requires keeping the copyright + permission notice.
- **WeSpeaker** ResNet34 — toolkit and architecture **Apache License 2.0**;
  the VoxCeleb-trained **weights are CC BY 4.0**, since WeSpeaker states a
  pretrained model follows its dataset's license. © the WeSpeaker authors
  (diarization). Both permit commercial use; both require attribution and a
  statement of changes, and Apache-2.0 also requires shipping the NOTICE.
- **Silero VAD** — **MIT License**, © 2020-present Silero Team (speech gating).
- **pyannote** segmentation-3.0 — **MIT License**, © 2020 CNRS (overlap detection).
- **DNA3.0-2B / 4B** — **Apache License 2.0**, © Dnotitia Inc.; base model
  Qwen3.5 © Alibaba Cloud (translation, summary, Q&A — downloaded on demand,
  not bundled).

See [`NOTICE`](NOTICE) and [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md)
for the attributions and full license texts; source headers in
`engine/metal/transcribe.zig` and `engine/metal/diar_resnet.zig` carry the same notices.
