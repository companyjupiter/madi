#!/usr/bin/env bash
# make_app.sh — build Madi.app entirely with swiftc (no Xcode project).
#
# Compiles the SwiftUI sources into an arm64 binary, assembles the .app bundle
# (Info.plist + engine binary + the 7 assets the engine actually opens via
# bpe_dir), and ad-hoc signs it for local development. Developer ID signing +
# notarization is a separate step (sign_notarize.sh).
#
# Usage:
#   make_app.sh [outdir]          # default ./build → ./build/Madi.app
#   SEED_MODEL=1 make_app.sh      # also symlink the repo model into App Support
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"        # app/
ROOT="$(cd "$APP_DIR/../.." && pwd)"     # repo root (apps/macos → ..)
OUT="${1:-$APP_DIR/build}"
BUNDLE="$OUT/Madi.app"

# ── 0. engine must exist ────────────────────────────────────────────────────
if [ ! -x "$ROOT/engine/metal/out/transcribe" ]; then
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
  "$APP_DIR"/Sovereign/Engine/TranslateStreamParser.swift
  "$APP_DIR"/Sovereign/Engine/TranslateEngine.swift
  "$APP_DIR"/Sovereign/Engine/SummaryEngine.swift
  "$APP_DIR"/Sovereign/Audio/WavWriter.swift
  "$APP_DIR"/Sovereign/Audio/SystemAudioCapture.swift
  "$APP_DIR"/Sovereign/Audio/Resampler.swift
  "$APP_DIR"/Sovereign/Audio/Segmenter.swift
  "$APP_DIR"/Sovereign/Audio/AudioCapture.swift
  "$APP_DIR"/Sovereign/Audio/AudioDevices.swift
  "$APP_DIR"/Sovereign/Audio/AudioDecode.swift
  "$APP_DIR"/Sovereign/Audio/LinePlayer.swift
  "$APP_DIR"/Sovereign/Model/AssetManifest.swift
  "$APP_DIR"/Sovereign/Model/ModelDownloader.swift
  "$APP_DIR"/Sovereign/Model/TranslateModelDownloader.swift
  "$APP_DIR"/Sovereign/Model/WorkspaceTree.swift
  "$APP_DIR"/Sovereign/Transcript/WordMerger.swift
  "$APP_DIR"/Sovereign/Transcript/TranscriptStore.swift
  "$APP_DIR"/Sovereign/Transcript/EditorCuts.swift
  "$APP_DIR"/Sovereign/Transcript/Exporters.swift
  "$APP_DIR"/Sovereign/Transcript/TranscriptArchive.swift
  "$APP_DIR"/Sovereign/Transcript/EnergyArc.swift
  "$APP_DIR"/Sovereign/Transcript/MeetingMode.swift
  "$APP_DIR"/Sovereign/Transcript/LiveCoach.swift
  "$APP_DIR"/Sovereign/Transcript/TitleGenerator.swift
  "$APP_DIR"/Sovereign/Transcript/PIIRedactor.swift
  "$APP_DIR"/Sovereign/Transcript/WorkspaceRetrieval.swift
  "$APP_DIR"/Sovereign/Transcript/PeopleAnalytics.swift
  "$APP_DIR"/Sovereign/Transcript/PendingEnrollmentStore.swift
  "$APP_DIR"/Sovereign/Transcript/VoiceprintStore.swift
  "$APP_DIR"/Sovereign/Transcript/LiveActionRail.swift
  "$APP_DIR"/Sovereign/Transcript/Retrieval.swift
  "$APP_DIR"/Sovereign/Transcript/SummaryDeck.swift
  "$APP_DIR"/Sovereign/Transcript/OpenLoopsAggregator.swift
  "$APP_DIR"/Sovereign/Transcript/GlossaryStore.swift
  "$APP_DIR"/Sovereign/Transcript/PersonalVocabulary.swift
  "$APP_DIR"/Sovereign/Transcript/InterimTranslationCache.swift
  "$APP_DIR"/Sovereign/Transcript/GistExtractor.swift
  "$APP_DIR"/Sovereign/Transcript/MeetingPrepBrief.swift
  "$APP_DIR"/Sovereign/Transcript/PrepBriefData.swift
  "$APP_DIR"/Sovereign/Transcript/ReviewController.swift
  "$APP_DIR"/Sovereign/Dictation/DictationFormatting.swift
  "$APP_DIR"/Sovereign/Dictation/DictationController.swift
  "$APP_DIR"/Sovereign/SessionController.swift
  "$APP_DIR"/Sovereign/CalendarBridge.swift
  "$APP_DIR"/Sovereign/SovereignApp.swift
  "$APP_DIR"/Sovereign/UI/Theme.swift
  "$APP_DIR"/Sovereign/UI/Theme+Conf.swift
  "$APP_DIR"/Sovereign/UI/ContentView.swift
  "$APP_DIR"/Sovereign/UI/WorkspaceExplorer.swift
  "$APP_DIR"/Sovereign/UI/VoiceprintManagementView.swift
  "$APP_DIR"/Sovereign/UI/OpenLoopsView.swift
  "$APP_DIR"/Sovereign/UI/GistView.swift
  "$APP_DIR"/Sovereign/UI/PrepBriefView.swift
  "$APP_DIR"/Sovereign/UI/ReviewControlView.swift
  "$APP_DIR"/Sovereign/UI/GlossarySettingsView.swift
  "$APP_DIR"/Sovereign/UI/RecapCardView.swift
  "$APP_DIR"/Sovereign/UI/TimelineScrubberView.swift
  "$APP_DIR"/Sovereign/UI/EnergyArcView.swift
  "$APP_DIR"/Sovereign/UI/CommandPalette.swift
  "$APP_DIR"/Sovereign/UI/CaptionOverlay.swift
  "$APP_DIR"/Sovereign/UI/PeopleDashboard.swift
  "$APP_DIR"/Sovereign/UI/LiveActionRailView.swift
  "$APP_DIR"/Sovereign/UI/LiveCoachView.swift
  "$APP_DIR"/Sovereign/UI/TranscriptView.swift
  "$APP_DIR"/Sovereign/UI/ModelGateView.swift
  "$APP_DIR"/Sovereign/UI/SettingsView.swift
  "$APP_DIR"/Sovereign/UI/DictationSettingsView.swift
)
swiftc -O -parse-as-library -target arm64-apple-macosx14.0 \
  "${SRCS[@]}" -o "$OUT/Madi"

# ── 2. assemble bundle ──────────────────────────────────────────────────────
echo "[2/4] assemble $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/assets-small"
cp "$OUT/Madi" "$BUNDLE/Contents/MacOS/Madi"
cp "$APP_DIR/Sovereign/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/engine/metal/out/transcribe" "$BUNDLE/Contents/MacOS/transcribe"
# engine @embedFile's the metallib; external copy is informational only —
# Resources/ so it's sealed by the bundle signature, not treated as code
cp "$ROOT/engine/metal/whisper.metallib" "$BUNDLE/Contents/Resources/whisper.metallib"

# only what the engine opens via bpe_dir(bpe_path) — verified in transcribe.zig
ASSETS=( WHISPER_BPE.bin mel_filters.bin resnet34_diar.bin kaldi_melbank.bin
         silero_vad.bin pyannote_osd.bin suppress_tokens.bin )
for f in "${ASSETS[@]}"; do
  if [ -f "$ROOT/engine/metal/assets/$f" ]; then
    cp "$ROOT/engine/metal/assets/$f" "$BUNDLE/Contents/Resources/assets-small/$f"
  else
    echo "  ⚠ missing asset: $f (engine degrades or fails — check gen_diar_assets.sh)"
  fi
done

# ── 2a. bundle the user manual (self-contained index.html) ──────────────────
# Regenerate from the .md sources if node is available (best-effort), then seal
# a copy into Resources/manual/ so Help → "Madi 사용자 매뉴얼" opens it offline.
if command -v node >/dev/null 2>&1 && [ -f "$ROOT/docs/manual/build_index.mjs" ]; then
  node "$ROOT/docs/manual/build_index.mjs" >/dev/null 2>&1 || true
fi
if [ -f "$ROOT/docs/manual/index.html" ]; then
  mkdir -p "$BUNDLE/Contents/Resources/manual"
  cp "$ROOT/docs/manual/index.html" "$BUNDLE/Contents/Resources/manual/index.html"
else
  echo "  ⚠ docs/manual/index.html missing — Help → 사용자 매뉴얼 will be unavailable"
fi

# ── 2b. optional: bundle the model INSIDE the .app (self-contained DMG) ──────
# Must happen BEFORE signing so the 867 MB model is sealed by the bundle
# signature. AssetManifest.modelURL then prefers this copy → no download.
MODEL_Q8="$ROOT/engine/metal/bench/runs/model.q8.safetensors"
if [ "${BUNDLE_MODEL:-0}" = "1" ]; then
  if [ -f "$MODEL_Q8" ]; then
    echo "[2b] bundling model into app ($(du -h "$MODEL_Q8" | cut -f1)) — self-contained"
    cp "$MODEL_Q8" "$BUNDLE/Contents/Resources/model.q8.safetensors"
  else
    echo "[2b] ❌ BUNDLE_MODEL=1 but model missing ($MODEL_Q8) — run bench/quantize_q8.py"; exit 1
  fi
fi

# ── 2c. translate engine binary (DNA3.0-4B Metal) — ~1.1 MB, self-contained
# (embedded metallib, system frameworks only). ALWAYS bundled when present (tiny);
# the 2.6 GB translate MODEL is downloaded on demand, NOT bundled. Override path
# with TRANSLATE_ENGINE; skipped (translation unavailable) if absent so the base
# build never breaks.
TRANSLATE_ENGINE="${TRANSLATE_ENGINE:-$ROOT/../sovereignLLM/out/metal-dna3-4b-q4km/sovereign-metal-dna3-4b-q4km}"
BUNDLED_TRANSLATE=0
if [ -x "$TRANSLATE_ENGINE" ]; then
  echo "[2c] bundling translate engine ($(du -h "$TRANSLATE_ENGINE" | cut -f1))"
  cp "$TRANSLATE_ENGINE" "$BUNDLE/Contents/MacOS/translate-engine"
  BUNDLED_TRANSLATE=1
else
  echo "[2c] (translate engine not found at $TRANSLATE_ENGINE — translation off; set TRANSLATE_ENGINE)"
fi

# ── 3. ad-hoc sign for local development ────────────────────────────────────
echo "[3/4] ad-hoc codesign (local dev; Developer ID via sign_notarize.sh)"
codesign --force --sign - "$BUNDLE/Contents/MacOS/transcribe"
[ "$BUNDLED_TRANSLATE" = "1" ] && codesign --force --sign - "$BUNDLE/Contents/MacOS/translate-engine"
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
