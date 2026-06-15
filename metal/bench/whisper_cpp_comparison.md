# Sovereign Whisper (Metal) vs whisper.cpp — head-to-head

Honest, reproducible comparison on identical inputs. **whisper.cpp is the mature,
fast baseline and wins on raw speed.** Our value is elsewhere — see "Takeaways".

## Setup
- **HW**: Apple M4 Pro (Metal). **Model**: Whisper large-v3-turbo, **both Q8**
  (ours: Q8_0 mixed + pread streaming loader; whisper.cpp: `ggml-large-v3-turbo-q8_0.bin`).
- **Decoding**: greedy on both (whisper.cpp `-bs 1 -bo 1`; ours is greedy argmax)
  for a fair speed comparison. whisper.cpp's default is beam-5 (higher quality, slower).
- **Audio**: identical files (md5-verified). `jfk` = 11 s EN; `ko60` = first 60 s of
  a Korean dev-ops talk (16 kHz mono).
- Warm runs (model file in page cache; Metal shaders pre-compiled). n=1 indicative.

## Results

### jfk — 11 s, English
| metric | Sovereign (ours) | whisper.cpp | winner |
|---|---|---|---|
| end-to-end wall (incl load) | 2.49 s | **0.85 s** | whisper.cpp ~2.9× (load-dominated on an 11 s clip) |
| model load | ~1.5 s (streaming) | **0.20 s** | whisper.cpp |
| encoder | 551 ms | 550 ms | tie (re-measured 2026-06-15; was 634 ms) |
| decode (26 tok, startup-bound) | 420 tok/s | **682 tok/s** | whisper.cpp (too short for steady state — see ko60) |
| peak RSS | 1.11 GB | 1.09 GB | ~tie |
| transcript | *identical* | *identical* | tie |

### ko60 — 60 s, Korean  (RE-MEASURED 2026-06-15, both reproducible n=2)
| metric | Sovereign (ours) | whisper.cpp | winner |
|---|---|---|---|
| encoder / 30 s chunk | **494 ms** (enc_batch=2) | 540 ms | ours ~1.1× (batched) |
| encoder / chunk (single, live) | 551 ms | 550 ms | tie |
| **decode** (full, incl argmax/sample) | ~526 tok/s (557 ms/293 tok) | **~595 tok/s** (437 ms decode + 65 ms sample / 298 tok) | **whisper.cpp ~1.13×** |
| steady-state transcription (2 chunks, excl load) | **~1587 ms** | ~1596 ms | ~tie (ours <1% ahead) |
| real-time factor | ~38× | ~38× | tie |
| peak RSS | 1.19 GB | 1.13 GB | ~tie |
| transcript (chars) | 1057 | 1065 | ~identical |

> **CORRECTION (2026-06-15):** an earlier revision of this file claimed *decode
> ~1.3× faster than whisper.cpp*. A fresh reproducible re-measure (same HW, same
> Q8 model, greedy) shows the **opposite**: whisper.cpp decode is ~1.13× faster
> (595 vs 526 tok/s, like-for-like incl sampling). The encoder, however, now
> **edges ahead with enc_batch** (494 vs 540 ms/chunk; tied at batch 1). **Net:
> end-to-end transcription is a dead heat (~38× RT both, excl one-time load).**
> The old claim is retracted — likely whisper.cpp's decode got faster since, or
> the prior whisper.cpp number was mismeasured.
>
> **Decode optimization journey** (quark-/profile-guided, all bit-exact):
> 233 → ~526 tok/s. Per-kernel GPU profiling redirected the attack to the real
> bottleneck — the cross-attention kernels. Wins: parallelize the cross/self-attn
> output phase (64→256 threads), vectorize QK dots (cache q + half4). This closed
> a ~1.4× decode gap to ~1.13×.
>
> **Multichunk batched decode (BATCHDEC, measured 2026-06-15, M1 in-engine).**
> The batched cross-attn kernel (PR #52) enabled an in-engine batched multichunk
> decode (gated `BATCHDEC=1`, shadow). Measured head-to-head on devops_ko, **same
> binary, same run** (batched runs alongside per-slot):
>
> | batch | batched tok/s | per-slot tok/s | verdict |
> |---|---|---|---|
> | B=4 (default `ENC_BATCH=4`) | ~530 | ~520 | **tied** (+2%) |
> | B=8, 2 uniform batches (7.7 min) | ~660 | ~500 | 1.34× (cherry-picked) |
> | **B=8, 15 batches at scale (62 min)** | **~592** (480–686) | ~513 | **~1.15×** |
>
> Text-equivalence re-confirmed (B=4 batched `529 tok` == per-slot 149+144+113+123
> = 529, exact; BPE text identical). **CORRECTION (de-risk measure on a 62 min /
> 124-chunk file):** the initial 1.34× was two *uniform* batches; **across 15 real
> batches the average is ~1.15×**, because **ragged EOT** (8 slots finishing at
> very different token counts — e.g. 10 tok vs 149 tok in one batch — run until the
> longest) erodes batching efficiency on real content. **End-to-end on long files
> (62 min production wall 113 s = 33× RT):** encoder is **50%** of wall, decode
> 23%; B=8 saves ~4.8 s = **~4.3%** end-to-end (2 hr → ~10 s, same ~4%). **Net: a
> ~4% polish, not the projected overtake.** Production integration (word timestamps
> via batched alignment capture + rescue/seek retire-to-sequential) **deferred** —
> ~4% for a high-risk transcript-path rewrite isn't justified; the editor win is
> the absolute (33× RT, local, private, word-ts). Live (B=1) never batches.

### Diarization — VoxConverse dev (DER, md-eval collar 0.25)
| metric | Sovereign (ours) | whisper.cpp |
|---|---|---|
| general multi-speaker DER | **9.67%** | **N/A** — not supported |

> whisper.cpp diarization = `tinydiarize` only: a special `small.en-tdrz` model,
> English, 2-speaker *turn* detection. No general speaker-embedding diarization.
> The fair comparison for our diarizer is **pyannote 3.1** (the tool whisper.cpp
> users bolt on), whose VoxConverse SOTA ~11.2% we already beat (9.67%).

### devops_ko — 462 s (7.7 min), Korean — full-file END-TO-END (2026-06-15)
The 60 s table sums GPU [perf] components; the true wall on a long file exposed a
hidden CPU bottleneck. Measured end-to-end wall (warm, n=3):

| | Sovereign (ours) | whisper.cpp |
|---|---|---|
| **before mel fix** | 33.0 s | 14.5 s |
| **after mel fix** | **~16 s** | 14.5 s |

> **Root-cause story (the [perf] number lied):** ours 33 s but [perf] (encoder
> 7.9 s + decode 3.9 s) summed to ~12.5 s — ~20 s was *outside* [perf]. Tracing
> `[enc]` showed a +7.3 s gap per 4-chunk batch while the encoder forward was only
> 2 s → the rest was the **mel spectrogram**. `mel.zig`'s `rfft` was a naive O(N²)
> DFT recomputing `@cos`/`@sin` ~482M times **per 30 s chunk** (~1.3 s/chunk;
> whisper.cpp's mel is 3.6 ms). Fix: precompute twiddle factors (f64 table, once)
> + multithread the independent frame loop → **wall 33 → ~16 s (~2×), bit-identical
> output** (jfk unchanged, deterministic). **Encode and decode were tied all along;
> the entire end-to-end gap was the mel front-end.** Now neck-and-neck with
> whisper.cpp; the residual (~1.5 s) is model load (mmap vs streaming, one-time).

## Why whisper.cpp WAS faster (mostly closed 2026-06-15)
1. **Load**: ggml mmap (~0.2 s) vs our pread *streaming* loader (~1.5 s). Our loader
   deliberately trades load time for low steady-state RSS. **In live/resident mode
   this cost is paid once**, so it disappears for streaming meeting use.
2. **Decode**: years of Metal kernel tuning + flash-attention + batched sampling.
   Ours is a from-scratch greedy decoder (~237 tok/s) — competitive but not tuned to that level.
3. **Encoder**: within ~1.2× — our from-scratch Zig+Metal encoder is close.

## Takeaways (honest, 2026-06-15 re-measure)
- **Speed**: a **dead heat on transcription** — steady-state (ko60, excl load) is
  ~tied (~38× RT both); encoder ours ~1.1× ahead with enc_batch, decode whisper.cpp
  ~1.13× ahead. The only real whisper.cpp win is **model load** (mmap 0.25 s vs our
  streaming 1.5 s), which on a short 11 s clip dominates end-to-end (~2.9×) but is a
  **one-time, pre-meeting cost** in resident/live use. Claim parity, not a win.
- **Memory / Quality / Timestamps**: parity — RSS ~tied, transcripts identical/near-identical
  (same weights), and both now use DTW word alignment (monotonic).
- **Where we are differentiated, not faster**:
  - **Integrated, general, language-agnostic diarization** (DER 9.67%) — whisper.cpp can't.
  - **Sovereign**: pure Zig + Metal, **zero runtime deps**, reads `model.safetensors` directly.
  - **Single-binary live meeting product**: streaming, speaker-attributed, overlap
    recovery, hallucination guard, `.md`/`.srt` — one resident process. whisper.cpp
    is an engine you assemble a pipeline around.

## Reproduce
```bash
# whisper.cpp (built with -DGGML_METAL=ON, model: large-v3-turbo-q8_0)
/usr/bin/time -l whisper-cli -m ggml-large-v3-turbo-q8_0.bin -f jfk.wav -bs 1 -bo 1 -nt
# ours
/usr/bin/time -l ./out/transcribe assets/model.safetensors jfk.wav assets/WHISPER_BPE.bin
```
