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
APP_DIR="$(cd "$HERE/.." && pwd)"        # apps/macos
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
  "$APP_DIR"/Sovereign/Engine/EngineEvents.swift
  "$APP_DIR"/Sovereign/Engine/EngineProcess.swift
  "$APP_DIR"/Sovereign/Engine/PreviewEngine.swift
  "$APP_DIR"/Sovereign/Engine/DNAEngineBroker.swift
  "$APP_DIR"/Sovereign/Engine/TranslateStreamParser.swift
  "$APP_DIR"/Sovereign/Engine/TranslationTurnQueue.swift
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
  "$APP_DIR"/Sovereign/Transcript/SpeakerID.swift
  "$APP_DIR"/Sovereign/Transcript/WordMerger.swift
  "$APP_DIR"/Sovereign/Transcript/TranscriptStore.swift
  "$APP_DIR"/Sovereign/Transcript/EditorCuts.swift
  "$APP_DIR"/Sovereign/Transcript/Exporters.swift
  "$APP_DIR"/Sovereign/Transcript/TranscriptArchive.swift
  "$APP_DIR"/Sovereign/Transcript/WorkspaceAnalytics.swift
  "$APP_DIR"/Sovereign/Transcript/TranscriptFind.swift
  "$APP_DIR"/Sovereign/Transcript/EnergyArc.swift
  "$APP_DIR"/Sovereign/Transcript/MeetingMode.swift
  "$APP_DIR"/Sovereign/Transcript/LiveCoach.swift
  "$APP_DIR"/Sovereign/Transcript/TitleGenerator.swift
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
  "$APP_DIR"/Sovereign/Transcript/TranscriptReconciler.swift
  "$APP_DIR"/Sovereign/Transcript/FAQTranslationStore.swift
  "$APP_DIR"/Sovereign/Transcript/GistExtractor.swift
  "$APP_DIR"/Sovereign/Transcript/MeetingPrepBrief.swift
  "$APP_DIR"/Sovereign/Transcript/PrepBriefData.swift
  "$APP_DIR"/Sovereign/Transcript/ReviewController.swift
  "$APP_DIR"/Sovereign/Dictation/DictationFormatting.swift
  "$APP_DIR"/Sovereign/Dictation/DictationController.swift
  "$APP_DIR"/Sovereign/SessionController.swift
  "$APP_DIR"/Sovereign/CalendarBridge.swift
  "$APP_DIR"/Sovereign/AppInfo/AppVersion.swift
  "$APP_DIR"/Sovereign/AppInfo/BetaGate.swift
  "$APP_DIR"/Sovereign/AppInfo/UpdateChecker.swift
  "$APP_DIR"/Sovereign/SovereignApp.swift
  "$APP_DIR"/Sovereign/UI/ClinicDisplaySupport.swift
  "$APP_DIR"/Sovereign/UI/L10n.swift
  "$APP_DIR"/Sovereign/UI/L10nJa.swift
  "$APP_DIR"/Sovereign/UI/Theme.swift
  "$APP_DIR"/Sovereign/UI/Theme+Conf.swift
  "$APP_DIR"/Sovereign/UI/BrandLogo.swift
  "$APP_DIR"/Sovereign/UI/SVGIcon.swift
  "$APP_DIR"/Sovereign/UI/BlackToggle.swift
  "$APP_DIR"/Sovereign/UI/StatusLine.swift
  "$APP_DIR"/Sovereign/UI/OrbView.swift
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
  "$APP_DIR"/Sovereign/UI/WorkspaceStatsView.swift
  "$APP_DIR"/Sovereign/UI/LiveActionRailView.swift
  "$APP_DIR"/Sovereign/UI/LiveCoachView.swift
  "$APP_DIR"/Sovereign/UI/TranscriptView.swift
  "$APP_DIR"/Sovereign/UI/ModelGateView.swift
  "$APP_DIR"/Sovereign/UI/SettingsView.swift
  "$APP_DIR"/Sovereign/UI/DictationSettingsView.swift
  "$APP_DIR"/Sovereign/UI/BetaGateView.swift
  "$APP_DIR"/Sovereign/UI/InfoView.swift
  "$APP_DIR"/Sovereign/UI/UpdateView.swift
)
swiftc -O -parse-as-library -target arm64-apple-macosx14.0 \
  "${SRCS[@]}" -o "$OUT/Madi"

# ── 2. assemble bundle ──────────────────────────────────────────────────────
echo "[2/4] assemble $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/assets-small"
cp "$OUT/Madi" "$BUNDLE/Contents/MacOS/Madi"
cp "$APP_DIR/Sovereign/Info.plist" "$BUNDLE/Contents/Info.plist"

# Release metadata can be injected by CI without modifying tracked sources.
# MADI_VERSION is the full SemVer (for example 0.9.1-beta.2); the numeric core
# remains CFBundleShortVersionString as required by macOS.
if [ -n "${MADI_VERSION:-}" ]; then
  if ! [[ "$MADI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    echo "❌ invalid MADI_VERSION: $MADI_VERSION"; exit 1
  fi
  MARKETING="${MADI_VERSION%%[-+]*}"
  CHANNEL="${MADI_CHANNEL:-stable}"
  case "$MADI_VERSION" in
    *-beta.*) CHANNEL="${MADI_CHANNEL:-beta}" ;;
    *-rc.*)   CHANNEL="${MADI_CHANNEL:-rc}" ;;
  esac
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING" "$BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${MADI_BUILD:-1}" "$BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :MADIFullVersion $MADI_VERSION" "$BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :MADIChannel $CHANNEL" "$BUNDLE/Contents/Info.plist"
fi
if [ -n "${MADI_BETA_EXPIRY:-}" ]; then
  # Add-or-set: the stable source plist omits MADIBetaExpiry, so a beta release
  # build (which passes this env) must be able to inject the key when absent.
  /usr/libexec/PlistBuddy -c "Set :MADIBetaExpiry $MADI_BETA_EXPIRY" "$BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :MADIBetaExpiry string $MADI_BETA_EXPIRY" "$BUNDLE/Contents/Info.plist"
fi
cp "$APP_DIR/Sovereign/Resources/logo_madi.png" "$BUNDLE/Contents/Resources/logo_madi.png"
cp "$APP_DIR/Sovereign/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
cp "$APP_DIR"/Sovereign/Resources/*.svg "$BUNDLE/Contents/Resources/"
cp "$ROOT/engine/metal/out/transcribe" "$BUNDLE/Contents/MacOS/transcribe"
# engine @embedFile's the metallib; external copy is informational only —
# Resources/ so it's sealed by the bundle signature, not treated as code
cp "$ROOT/engine/metal/whisper.metallib" "$BUNDLE/Contents/Resources/whisper.metallib"

# only what the engine opens via bpe_dir(bpe_path) — verified in transcribe.zig
ASSETS=( WHISPER_BPE.bin mel_filters.bin resnet34_diar.bin kaldi_melbank.bin
         silero_vad.bin pyannote_osd.bin suppress_tokens.bin )
MISSING_ASSETS=0
for f in "${ASSETS[@]}"; do
  if [ -f "$ROOT/engine/metal/assets/$f" ]; then
    cp "$ROOT/engine/metal/assets/$f" "$BUNDLE/Contents/Resources/assets-small/$f"
  else
    echo "  ⚠ missing asset: $f (engine degrades or fails — check gen_diar_assets.sh)"
    MISSING_ASSETS=1
  fi
done
if [ "$MISSING_ASSETS" = "1" ] && [ "${STRICT_ASSETS:-0}" = "1" ]; then
  echo "❌ required runtime assets are missing (STRICT_ASSETS=1)"; exit 1
fi

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

# ── 2c. model-specific translate engines (embedded metallib, ~1.1 MB each)
# Both binaries are tiny; the selected 1.3/2.8 GB GGUF remains on-demand. The
# legacy TRANSLATE_ENGINE override maps to 4B for release-pipeline compatibility.
TRANSLATE_ENGINE_4B="${TRANSLATE_ENGINE_4B:-${TRANSLATE_ENGINE:-$ROOT/../sovereignLLM/out/metal-dna3-4b-q4km/sovereign-metal-dna3-4b-q4km}}"
TRANSLATE_ENGINE_2B="${TRANSLATE_ENGINE_2B:-$ROOT/../sovereignLLM/out/metal-dna3-2b-q4km/sovereign-metal-dna3-2b-q4km}"
BUNDLED_TRANSLATE_4B=0
BUNDLED_TRANSLATE_2B=0
if [ -x "$TRANSLATE_ENGINE_4B" ]; then
  echo "[2c] bundling DNA3.0-4B engine ($(du -h "$TRANSLATE_ENGINE_4B" | cut -f1))"
  cp "$TRANSLATE_ENGINE_4B" "$BUNDLE/Contents/MacOS/translate-engine-4b"
  BUNDLED_TRANSLATE_4B=1
else
  echo "[2c] (4B translate engine not found at $TRANSLATE_ENGINE_4B)"
fi
if [ -x "$TRANSLATE_ENGINE_2B" ]; then
  echo "[2c] bundling DNA3.0-2B engine ($(du -h "$TRANSLATE_ENGINE_2B" | cut -f1))"
  cp "$TRANSLATE_ENGINE_2B" "$BUNDLE/Contents/MacOS/translate-engine-2b"
  BUNDLED_TRANSLATE_2B=1
else
  echo "[2c] (2B translate engine not found at $TRANSLATE_ENGINE_2B)"
fi
if [ "${REQUIRE_TRANSLATE_ENGINE:-0}" = "1" ] && { [ "$BUNDLED_TRANSLATE_4B" != "1" ] || [ "$BUNDLED_TRANSLATE_2B" != "1" ]; }; then
  echo "❌ both 4B and 2B translate engines are required for this build"; exit 1
fi

# ── 3. ad-hoc sign for local development ────────────────────────────────────
echo "[3/4] ad-hoc codesign (local dev; Developer ID via sign_notarize.sh)"
codesign --force --sign - "$BUNDLE/Contents/MacOS/transcribe"
[ "$BUNDLED_TRANSLATE_4B" = "1" ] && codesign --force --sign - "$BUNDLE/Contents/MacOS/translate-engine-4b"
[ "$BUNDLED_TRANSLATE_2B" = "1" ] && codesign --force --sign - "$BUNDLE/Contents/MacOS/translate-engine-2b"
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
