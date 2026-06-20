#!/usr/bin/env bash
# assemble_bundle.sh — copy the engine binary, metallib, and curated small
# assets into a built Sovereign.app bundle (post-xcodebuild). Excludes dev-only
# assets (jfk*.wav, enc_input.bin, *.py, README) per DESIGN.md §4.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${1:?usage: assemble_bundle.sh <path/to/Sovereign.app>}"

MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources/assets-small"
mkdir -p "$MACOS" "$RES"

# engine + metallib
cp "$ROOT/metal/out/transcribe" "$MACOS/transcribe"
cp "$ROOT/metal/whisper.metallib" "$MACOS/whisper.metallib"
chmod +x "$MACOS/transcribe"

# curated small assets (model.safetensors is downloaded on first run, NOT bundled)
SMALL=(
  WHISPER_BPE.bin mel_filters.bin kaldi_melbank.bin
  conv1_w.bin conv1_b.bin conv2_w.bin conv2_b.bin pos_emb.bin
  suppress_tokens.bin silero_vad.bin pyannote_osd.bin resnet34_diar.bin
  tokenizer.json tokenizer_config.json vocab.json merges.txt
  special_tokens_map.json added_tokens.json config.json
  generation_config.json preprocessor_config.json
)
for f in "${SMALL[@]}"; do
  if [ -f "$ROOT/metal/assets/$f" ]; then cp "$ROOT/metal/assets/$f" "$RES/$f"
  else echo "  ⚠ missing asset: $f"; fi
done

echo "✅ assembled bundle: $APP"
du -sh "$APP"
