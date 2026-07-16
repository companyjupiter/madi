#!/usr/bin/env bash
# Install the seven non-source runtime assets from a versioned release archive.
# The archive may contain the files at any directory depth; duplicate names are
# rejected. CI downloads the archive from controlled storage and passes its
# pinned SHA-256 as the second argument.
set -euo pipefail

ARCHIVE="${1:?usage: prepare_release_assets.sh <assets.tar.gz> <sha256>}"
EXPECTED_SHA="${2:?usage: prepare_release_assets.sh <assets.tar.gz> <sha256>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$(cd "$HERE/../../../engine/metal/assets" && pwd)"

ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "❌ release assets SHA-256 mismatch" >&2
  echo "expected: $EXPECTED_SHA" >&2
  echo "actual:   $ACTUAL_SHA" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if tar -tzf "$ARCHIVE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  echo "❌ release assets archive contains an unsafe path" >&2
  exit 1
fi
tar -xzf "$ARCHIVE" -C "$TMP"

ASSETS=(
  WHISPER_BPE.bin mel_filters.bin resnet34_diar.bin kaldi_melbank.bin
  silero_vad.bin pyannote_osd.bin suppress_tokens.bin
)
for name in "${ASSETS[@]}"; do
  mapfile=()
  while IFS= read -r path; do mapfile+=("$path"); done < <(find "$TMP" -type f -name "$name")
  if [ "${#mapfile[@]}" -ne 1 ]; then
    echo "❌ expected exactly one $name in archive, found ${#mapfile[@]}" >&2
    exit 1
  fi
  cp "${mapfile[0]}" "$DEST/$name"
done

echo "✅ installed ${#ASSETS[@]} verified runtime assets"
