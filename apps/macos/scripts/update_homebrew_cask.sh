#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: update_homebrew_cask.sh <cask-file> <version> <sha256>" >&2
  exit 2
fi

CASK="$1"
VERSION="$2"
SHA256="$3"

[ -f "$CASK" ] || { echo "cask not found: $CASK" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "stable SemVer required: $VERSION" >&2; exit 1; }
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "lowercase SHA-256 required" >&2; exit 1; }

TMP="$(mktemp "${TMPDIR:-/tmp}/madi-cask.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

awk -v version="$VERSION" -v sha256="$SHA256" '
  /^  version "[^"]+"$/ { print "  version \"" version "\""; versions++; next }
  /^  sha256 "[0-9a-f]+"$/ { print "  sha256 \"" sha256 "\""; hashes++; next }
  { print }
  END { if (versions != 1 || hashes != 1) exit 1 }
' "$CASK" > "$TMP" || { echo "expected exactly one version and sha256 stanza" >&2; exit 1; }

mv "$TMP" "$CASK"
trap - EXIT
