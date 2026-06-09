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
| end-to-end wall (incl load) | 2.49 s | **0.85 s** | whisper.cpp ~2.9× |
| model load | ~1.5 s (streaming) | **0.20 s** | whisper.cpp |
| encoder | 634 ms | **540 ms** | whisper.cpp ~1.2× |
| peak RSS | 1.11 GB | 1.09 GB | ~tie |
| transcript | *identical* | *identical* | tie |

### ko60 — 60 s, Korean
| metric | Sovereign (ours) | whisper.cpp | winner |
|---|---|---|---|
| encoder / 30 s chunk | ~660 ms | **571 ms** | whisper.cpp ~1.15× |
| **decode** | **~420 tok/s (740 ms/2ch)** | ~848 ms/2ch | **ours ~1.15×** |
| steady-state transcription (2 chunks) | ~2099 ms | **~1990 ms** | ~tie (wcpp +5%) |
| peak RSS | 1.19 GB | 1.13 GB | ~tie |
| transcript (chars) | 1057 | 1065 | ~identical |

> **Decode optimization journey** (quark-/profile-guided, all bit-exact):
> 233 → 420 tok/s (+80%). The big win was parallelizing the cross-attention
> output phase (`flash_cross_attn_f16kv`), which a per-kernel GPU profile flagged
> as ~half of long-sequence decode — it had used 64 of 256 threads. After this,
> **decode is now faster than whisper.cpp**; the remaining ~5% steady-state gap
> is the encoder (mostly MPS GEMM, already near-optimal). Load (one-time,
> pre-meeting) is excluded — it doesn't recur during a live session.

### Diarization — VoxConverse dev (DER, md-eval collar 0.25)
| metric | Sovereign (ours) | whisper.cpp |
|---|---|---|
| general multi-speaker DER | **9.67%** | **N/A** — not supported |

> whisper.cpp diarization = `tinydiarize` only: a special `small.en-tdrz` model,
> English, 2-speaker *turn* detection. No general speaker-embedding diarization.
> The fair comparison for our diarizer is **pyannote 3.1** (the tool whisper.cpp
> users bolt on), whose VoxConverse SOTA ~11.2% we already beat (9.67%).

## Why whisper.cpp is faster
1. **Load**: ggml mmap (~0.2 s) vs our pread *streaming* loader (~1.5 s). Our loader
   deliberately trades load time for low steady-state RSS. **In live/resident mode
   this cost is paid once**, so it disappears for streaming meeting use.
2. **Decode**: years of Metal kernel tuning + flash-attention + batched sampling.
   Ours is a from-scratch greedy decoder (~237 tok/s) — competitive but not tuned to that level.
3. **Encoder**: within ~1.2× — our from-scratch Zig+Metal encoder is close.

## Takeaways (honest)
- **Speed**: whisper.cpp wins (~2.7–2.9× end-to-end). Don't claim otherwise.
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
