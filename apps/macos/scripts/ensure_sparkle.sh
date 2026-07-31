#!/usr/bin/env bash
# ensure_sparkle.sh — fetch the pinned Sparkle binary distribution for Madi's
# swiftc-only build and release scripts. Prints the vendor directory path.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VERSION="${SPARKLE_VERSION:-2.9.4}"
SHA256="${SPARKLE_ARCHIVE_SHA256:-ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9}"
URL="${SPARKLE_ARCHIVE_URL:-https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz}"
VENDOR_DIR="${SPARKLE_VENDOR_DIR:-$ROOT/build/vendor/sparkle-$VERSION}"

if [ -d "$VENDOR_DIR/Sparkle.framework" ] && [ -x "$VENDOR_DIR/bin/sign_update" ]; then
  printf '%s\n' "$VENDOR_DIR"
  exit 0
fi

command -v curl >/dev/null || { echo "❌ curl is required to fetch Sparkle" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/madi-sparkle.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

archive="$tmp/Sparkle-$VERSION.tar.xz"
curl --fail --location --retry 3 --silent --show-error "$URL" --output "$archive"
echo "$SHA256  $archive" | shasum -a 256 -c - >/dev/null

mkdir -p "$(dirname "$VENDOR_DIR")"
rm -rf "$VENDOR_DIR.tmp"
mkdir -p "$VENDOR_DIR.tmp"
tar -xJf "$archive" -C "$VENDOR_DIR.tmp"
rm -rf "$VENDOR_DIR"
mv "$VENDOR_DIR.tmp" "$VENDOR_DIR"

printf '%s\n' "$VENDOR_DIR"
