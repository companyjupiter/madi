#!/usr/bin/env bash
# assemble_bundle.sh — copy the engine binary, metallib, and curated small
# assets into a built Sovereign.app bundle (post-xcodebuild). Excludes dev-only
# assets (jfk*.wav, enc_input.bin, *.py, README) per DESIGN.md §4.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # apps/macos/scripts → repo root
APP="${1:?usage: assemble_bundle.sh <path/to/Sovereign.app>}"

MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources/assets-small"
mkdir -p "$MACOS" "$RES"

# engine + metallib
cp "$ROOT/engine/metal/out/transcribe" "$MACOS/transcribe"
cp "$ROOT/engine/metal/whisper.metallib" "$MACOS/whisper.metallib"
chmod +x "$MACOS/transcribe"

# curated small assets — ONLY what the engine opens via bpe_dir(bpe_path),
# kept in sync with make_app.sh's canonical ASSETS[] (verified in transcribe.zig).
# conv/pos_emb weights + tokenizer JSON are @embedFile'd into the engine binary,
# so they are NOT bundled here. model.safetensors is downloaded on first run.
SMALL=(
  WHISPER_BPE.bin mel_filters.bin resnet34_diar.bin kaldi_melbank.bin
  silero_vad.bin pyannote_osd.bin suppress_tokens.bin
)
for f in "${SMALL[@]}"; do
  if [ -f "$ROOT/engine/metal/assets/$f" ]; then cp "$ROOT/engine/metal/assets/$f" "$RES/$f"
  else echo "  ⚠ missing asset: $f"; fi
done

# Madi's own license (AGPL-3.0) and the third-party notices for the bundled
# weights (MIT / Apache-2.0 / CC BY 4.0) ship inside the app
for f in LICENSE NOTICE THIRD_PARTY_LICENSES.md; do
  if [ -f "$ROOT/$f" ]; then cp "$ROOT/$f" "$APP/Contents/Resources/$f"
  else echo "  ⚠ missing notice: $f"; fi
done

echo "✅ assembled bundle: $APP"
du -sh "$APP"
