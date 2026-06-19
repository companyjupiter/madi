# Sovereign Whisper (Metal) — current verified status

Single-snapshot reference for the `feature/metal-q8` branch. Chronological detail
lives in `PERF_LOG.md`; diarization study in `bench/*.md`. Re-measured 2026-06-09.

## Correctness gates (all green)
| gate | result |
|---|---|
| `test_encoder` (GPU vs CPU ref) | ✅ matches |
| `test_decoder` (GPU vs CPU ref) | ✅ matches |
| jfk transcription == golden | ✅ exact ("And so, my fellow Americans, …") |
| word timestamps monotonic & aligned | ✅ (0.64 And · 1.06 so · 1.48 my · …) |
| silence → no output / no spurious speakers | ✅ |
| diar embedding vs onnxruntime | ✅ cosine 1.000000 |

## Performance (jfk, M4 Pro) — remeasured 2026-06-19, current build
| metric | baseline | prev doc | now (measured) |
|---|---|---|---|
| conv front-end | ~95 ms | ~21 ms | **~15 ms** |
| encoder / chunk | 1390 ms | ~653 ms | **~568 ms** (1 chunk) · **~501 ms for a 4-chunk batch ≈125 ms/chunk** |
| decode | 134 tok/s | ~188 tok/s | **~402 tok/s** (jfk, 26 tok) · **~485–496 tok/s** steady (long chunks, 3-min conv) |
| **peak RSS** | 4.78 GB | 1.11 GB | **1.05 GB** (jfk) · 1.26 GB (3-min, batch-4 encode resident) |

> The ~188 tok/s figure predated persistent on-GPU decode + the batched-attention
> kernel; current decode is **2.1–2.6× faster** (jfk ~402, longer chunks ~490 tok/s).
> Method: `DIAR=0 ./out/transcribe model.q8.safetensors <wav> assets/WHISPER_BPE.bin`,
> reading the engine's own `[perf]` line; jfk 3-run stable (402.4/401.4/402.7).

RSS journey: 4.78 → 3.40 (Q8-1) → 3.13 (Q8-2) → 2.54 (Q8-3) → 1.02 (pread loader)
→ 1.11 (+ ResNet34 diar). ⚠️ A diar arena/threads leak briefly pushed this to
2.3 GB — caught & fixed (commit 5b4b7cb, free im2col cols immediately).

## Diarization (DER, md-eval collar 0.25)
| set | DER | note |
|---|---|---|
| VoxConverse dev (12-file subset, auto-K) | **9.67%** | tuned maxK=6/VAD=0.40; beats pyannote 3.1 SOTA ~11.2% |
| AMI ES2004a (4-spk far-field) | ~32.5% | harder domain; oracle ceiling 24% (1.5s segmentation) |
| demo4 (clean 4-spk TTS) | 24% | global speaker IDs consistent |
- Path: encoder feature (≈90% DER, speaker-invariant) → mel (67%) → **ResNet34 emb (this)**.
- Sovereign: ResNet34 hand-ported to Zig, verified bit-for-bit vs onnx; no runtime ML dep.

## Features
- Q8_0 weights (embed/decoder/encoder/cross-KV); pread streaming loader.
- Energy VAD (silence skip); Whisper language auto-detection (en/ko/… verified).
- Word timestamps (cross-attention argmax); speaker-attributed transcript.
- Diarization: ResNet34 embeddings + auto-K (silhouette). Env knobs: `DIAR_K`,
  `DIAR_MAXK`, `DIAR_SIL_TAU`, `DIAR_VAD`, `WHISPER_LANG_ID`.

## Tuning knobs (no rebuild)
`DIAR_K=N` fix speakers (0=auto) · `DIAR_MAXK` auto-K cap (default 6) ·
`DIAR_VAD` energy-VAD mult (0.40) · `DIAR_SIL_TAU` single-speaker thresh (0.10).

## Known limitations / next levers
- AMI far-field DER (32%) > VoxConverse (10%): different domain; defaults tuned
  for natural conversation. Override `DIAR_MAXK`/`DIAR_VAD` per run.
- Whisper repeat-loop hallucination on hard/quiet stretches ("Q. Q. Q.") — needs
  a compression-ratio / no-repeat guard (not yet implemented).
- diar embed ~11–28 ms/window (im2col bandwidth-bound); finer windows would cut
  boundary DER but raise cost.
