#!/usr/bin/env bash
# make_app.sh — build Sovereign.app entirely with swiftc (no Xcode project).
#
# Compiles the SwiftUI sources into an arm64 binary, assembles the .app bundle
# (Info.plist + engine binary + the 7 assets the engine actually opens via
# bpe_dir), and ad-hoc signs it for local development. Developer ID signing +
# notarization is a separate step (sign_notarize.sh).
#
# Usage:
#   make_app.sh [outdir]          # default ./build → ./build/Sovereign.app
#   SEED_MODEL=1 make_app.sh      # also symlink the repo model into App Support
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"        # app/
ROOT="$(cd "$APP_DIR/.." && pwd)"        # repo root
OUT="${1:-$APP_DIR/build}"
BUNDLE="$OUT/Sovereign.app"

# ── 0. engine must exist ────────────────────────────────────────────────────
if [ ! -x "$ROOT/metal/out/transcribe" ]; then
  echo "engine missing — building"; "$HERE/build_engine.sh"
fi

# ── 1. compile Swift sources ────────────────────────────────────────────────
echo "[1/4] swiftc release build"
mkdir -p "$OUT"
SRCS=(
  "$APP_DIR"/Sovereign/Engine/EnginePathPolicy.swift
  "$APP_DIR"/Sovereign/Engine/EngineProtocol.swift
  "$APP_DIR"/Sovereign/Engine/EngineProcess.swift
  "$APP_DIR"/Sovereign/Engine/PreviewEngine.swift
  "$APP_DIR"/Sovereign/Audio/WavWriter.swift
  "$APP_DIR"/Sovereign/Audio/Resampler.swift
  "$APP_DIR"/Sovereign/Audio/Segmenter.swift
  "$APP_DIR"/Sovereign/Audio/AudioCapture.swift
  "$APP_DIR"/Sovereign/Audio/AudioDevices.swift
  "$APP_DIR"/Sovereign/Audio/AudioDecode.swift
  "$APP_DIR"/Sovereign/Model/AssetManifest.swift
  "$APP_DIR"/Sovereign/Model/ModelDownloader.swift
  "$APP_DIR"/Sovereign/Model/TranslateModelDownloader.swift
  "$APP_DIR"/Sovereign/Transcript/WordMerger.swift
  "$APP_DIR"/Sovereign/Transcript/TranscriptStore.swift
  "$APP_DIR"/Sovereign/Transcript/EditorCuts.swift
  "$APP_DIR"/Sovereign/Transcript/Exporters.swift
  "$APP_DIR"/Sovereign/SessionController.swift
  "$APP_DIR"/Sovereign/SovereignApp.swift
  "$APP_DIR"/Sovereign/UI/Theme.swift
  "$APP_DIR"/Sovereign/UI/Theme+Conf.swift
  "$APP_DIR"/Sovereign/UI/ContentView.swift
  "$APP_DIR"/Sovereign/UI/TranscriptView.swift
  "$APP_DIR"/Sovereign/UI/ModelGateView.swift
  "$APP_DIR"/Sovereign/UI/SettingsView.swift
)
swiftc -O -parse-as-library -target arm64-apple-macosx14.0 \
  "${SRCS[@]}" -o "$OUT/Sovereign"

# ── 2. assemble bundle ──────────────────────────────────────────────────────
echo "[2/4] assemble $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/assets-small"
cp "$OUT/Sovereign" "$BUNDLE/Contents/MacOS/Sovereign"
cp "$APP_DIR/Sovereign/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/metal/out/transcribe" "$BUNDLE/Contents/MacOS/transcribe"
# engine @embedFile's the metallib; external copy is informational only —
# Resources/ so it's sealed by the bundle signature, not treated as code
cp "$ROOT/metal/whisper.metallib" "$BUNDLE/Contents/Resources/whisper.metallib"

# only what the engine opens via bpe_dir(bpe_path) — verified in transcribe.zig
ASSETS=( WHISPER_BPE.bin mel_filters.bin resnet34_diar.bin kaldi_melbank.bin
         silero_vad.bin pyannote_osd.bin suppress_tokens.bin )
for f in "${ASSETS[@]}"; do
  if [ -f "$ROOT/metal/assets/$f" ]; then
    cp "$ROOT/metal/assets/$f" "$BUNDLE/Contents/Resources/assets-small/$f"
  else
    echo "  ⚠ missing asset: $f (engine degrades or fails — check gen_diar_assets.sh)"
  fi
done

# ── 2b. optional: bundle the model INSIDE the .app (self-contained DMG) ──────
# Must happen BEFORE signing so the 867 MB model is sealed by the bundle
# signature. AssetManifest.modelURL then prefers this copy → no download.
MODEL_Q8="$ROOT/metal/bench/runs/model.q8.safetensors"
if [ "${BUNDLE_MODEL:-0}" = "1" ]; then
  if [ -f "$MODEL_Q8" ]; then
    echo "[2b] bundling model into app ($(du -h "$MODEL_Q8" | cut -f1)) — self-contained"
    cp "$MODEL_Q8" "$BUNDLE/Contents/Resources/model.q8.safetensors"
  else
    echo "[2b] ❌ BUNDLE_MODEL=1 but model missing ($MODEL_Q8) — run bench/quantize_q8.py"; exit 1
  fi
fi

# ── 3. ad-hoc sign for local development ────────────────────────────────────
echo "[3/4] ad-hoc codesign (local dev; Developer ID via sign_notarize.sh)"
codesign --force --sign - "$BUNDLE/Contents/MacOS/transcribe"
codesign --force --sign - --entitlements "$APP_DIR/Sovereign/Sovereign.entitlements" "$BUNDLE"

# ── 4. optional: seed the model so first run skips the (placeholder) download ─
# model name must match AssetManifest.model.name (the Q8 build). MODEL_Q8 set above.
if [ "${BUNDLE_MODEL:-0}" = "1" ]; then
  echo "[4/4] (model bundled in-app; no App Support seed needed)"
elif [ "${SEED_MODEL:-0}" = "1" ]; then
  SUP="$HOME/Library/Application Support/Sovereign"
  mkdir -p "$SUP"
  if [ -f "$MODEL_Q8" ]; then
    ln -sf "$MODEL_Q8" "$SUP/model.q8.safetensors"
    echo "[4/4] Q8 model seeded → $SUP/model.q8.safetensors (symlink)"
  else
    echo "[4/4] ⚠ Q8 model missing ($MODEL_Q8) — run bench/quantize_q8.py first"
  fi
else
  echo "[4/4] (no model seed; SEED_MODEL=1 to symlink the repo Q8 model)"
fi

du -sh "$BUNDLE"
echo "✅ open \"$BUNDLE\""
