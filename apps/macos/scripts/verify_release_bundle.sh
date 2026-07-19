#!/usr/bin/env bash
# Fail-fast structural checks before an app is signed and notarized.
set -euo pipefail

APP="${1:?usage: verify_release_bundle.sh <Madi.app> <full-version>}"
EXPECTED_VERSION="${2:?usage: verify_release_bundle.sh <Madi.app> <full-version>}"
PLIST="$APP/Contents/Info.plist"

required=(
  "$APP/Contents/MacOS/Madi"
  "$APP/Contents/MacOS/transcribe"
  "$APP/Contents/Resources/manual/index.html"
  "$APP/Contents/Resources/assets-small/WHISPER_BPE.bin"
  "$APP/Contents/Resources/assets-small/mel_filters.bin"
  "$APP/Contents/Resources/assets-small/resnet34_diar.bin"
  "$APP/Contents/Resources/assets-small/kaldi_melbank.bin"
  "$APP/Contents/Resources/assets-small/silero_vad.bin"
  "$APP/Contents/Resources/assets-small/pyannote_osd.bin"
  "$APP/Contents/Resources/assets-small/suppress_tokens.bin"
  "$PLIST"
)
for path in "${required[@]}"; do
  [ -s "$path" ] || { echo "❌ missing or empty: $path" >&2; exit 1; }
done

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :MADIFullVersion' "$PLIST")"
[ "$ACTUAL_VERSION" = "$EXPECTED_VERSION" ] || {
  echo "❌ bundle version is $ACTUAL_VERSION, expected $EXPECTED_VERSION" >&2
  exit 1
}
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"

executables=(
  "$APP/Contents/MacOS/Madi"
  "$APP/Contents/MacOS/transcribe"
)
[ ! -e "$APP/Contents/MacOS/translate-engine" ] \
  || executables+=("$APP/Contents/MacOS/translate-engine")

for executable in "${executables[@]}"; do
  file "$executable" | grep -q 'arm64' || {
    echo "❌ release executable is not arm64: $executable" >&2; exit 1;
  }
  ACTUAL_MINIMUM="$(xcrun vtool -show-build "$executable" | awk '$1 == "minos" { print $2; exit }')"
  [ "$ACTUAL_MINIMUM" = "$MINIMUM_OS" ] || {
    echo "❌ $(basename "$executable") targets macOS $ACTUAL_MINIMUM, bundle declares $MINIMUM_OS" >&2
    exit 1
  }
done

echo "✅ release bundle structure verified ($ACTUAL_VERSION, arm64, macOS $MINIMUM_OS+)"
