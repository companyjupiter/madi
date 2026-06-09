# Sovereign Whisper — Apple Silicon (Metal)

Self-contained Whisper **large-v3-turbo** speech-to-text for Apple Silicon, with
**word timestamps**, **speaker diarization** (who-said-what), **language
auto-detection**, and long-audio chunking. Pure Zig + Metal/MSL + Apple system
frameworks (Metal, MPS, Accelerate) — **no Python/PyTorch/onnxruntime at
runtime**. Korean guide: [README_KR.md](README_KR.md).

> Highlights: peak RSS **1.1 GB** (Q8 + streaming loader), decode **~188 tok/s**,
> diarization **9.67% DER** on VoxConverse dev (beats pyannote 3.1 SOTA ~11.2%).
> Full status: [`metal/STATUS.md`](metal/STATUS.md).

## Requirements
- Apple Silicon (M1 or newer), macOS with the Xcode command-line tools (`xcrun metal`).
- [Zig](https://ziglang.org) 0.14.x.
- `ffmpeg` (to convert audio to 16 kHz mono WAV).
- Python 3 (only for one-time **asset generation**, not for inference).

## Setup
All commands run from `metal/`.

1. **Model + tokenizer assets** (`metal/assets/`): you need
   `model.safetensors` (Whisper large-v3-turbo) plus the HF tokenizer/config
   files (`tokenizer.json`, `generation_config.json`, `added_tokens.json`, …).
   Then generate the binaries:
   ```bash
   cd metal/assets && python3 gen_assets.py   # → mel_filters.bin, WHISPER_BPE.bin, suppress_tokens.bin
   ```
2. **Diarization model** (Apache-2.0 wespeaker ResNet34, ~25 MB):
   ```bash
   cd metal && bash bench/gen_diar_assets.sh  # → assets/resnet34_diar.bin, assets/kaldi_melbank.bin
   ```

## Build
```bash
cd metal && bash build.sh transcribe.zig     # → out/transcribe
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

## Performance (jfk, M4 Pro)
| | baseline | now |
|---|---|---|
| encoder/chunk | 1390 ms | ~653 ms |
| decode | 134 tok/s | ~188 tok/s |
| peak RSS | 4.78 GB | **1.11 GB** |

## Project layout
- `metal/transcribe.zig` — full pipeline (mel → conv → encoder → decoder → BPE, timestamps, diarization).
- `metal/encoder.zig`, `decoder.zig`, `mel.zig`, `diar_resnet.zig` — modules.
- `metal/kernels/*.metal` — Metal kernels. `metal/metal_backend.{m,h}` — ObjC bridge.
- `metal/bench/` — DER benchmark harness + diarization study docs.
- Docs: `metal/STATUS.md` (current state), `metal/PERF_LOG.md` (history),
  `metal/PORT.md` (CUDA→Metal port notes), `metal/bench/*.md`.

## License / provenance
Inference code: this project. Diarization weights: wespeaker ResNet34 (Apache-2.0,
trained on VoxCeleb — verify dataset terms for commercial use). Whisper weights
per OpenAI's terms.
