#!/usr/bin/env bash
# fetch_runtime_assets.sh — download the seven small runtime assets a source build
# needs (tokenizer BPE, mel filters, diarization / VAD / overlap weights, …) and
# install them into engine/metal/assets after verifying the pinned SHA-256.
#
# The archive URL and digest are the release pipeline's own defaults, read from
# madi_release.sh so the two can never drift. Override both together with
# MADI_RELEASE_ASSETS_URL + MADI_RELEASE_ASSETS_SHA256.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

default_of() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$HERE/madi_release.sh" | head -1; }
if [ -n "${MADI_RELEASE_ASSETS_URL:-}" ] || [ -n "${MADI_RELEASE_ASSETS_SHA256:-}" ]; then
  [ -n "${MADI_RELEASE_ASSETS_URL:-}" ] && [ -n "${MADI_RELEASE_ASSETS_SHA256:-}" ] \
    || { echo "❌ set MADI_RELEASE_ASSETS_URL and MADI_RELEASE_ASSETS_SHA256 together" >&2; exit 1; }
fi
URL="${MADI_RELEASE_ASSETS_URL:-$(default_of DEFAULT_ASSETS_URL)}"
SHA="${MADI_RELEASE_ASSETS_SHA256:-$(default_of DEFAULT_ASSETS_SHA256)}"
[ -n "$URL" ] && [ -n "$SHA" ] || { echo "❌ could not resolve the asset archive URL/digest" >&2; exit 1; }

ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/madi-runtime-assets.XXXXXX")"
trap 'rm -f "$ARCHIVE"' EXIT
echo "downloading $URL"
curl --fail --location --retry 3 --silent --show-error "$URL" --output "$ARCHIVE"
"$HERE/prepare_release_assets.sh" "$ARCHIVE" "$SHA"
