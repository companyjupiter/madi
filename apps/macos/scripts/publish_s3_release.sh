#!/usr/bin/env bash
# Upload versioned DMGs/checksums to S3, then atomically advance a channel feed.
set -euo pipefail

DIST="${1:?usage: publish_s3_release.sh <dist> <bucket> <base-url> <prefix> <version> <channel> <publish>}"
BUCKET="${2:?missing bucket}"
BASE_URL="${3:?missing public download base URL}"
PREFIX="${4:-madi}"
VERSION="${5:?missing version}"
CHANNEL="${6:?missing channel}"
PUBLISH="${7:-false}"

command -v aws >/dev/null || { echo "❌ aws CLI is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "❌ jq is required" >&2; exit 1; }
BASE_URL="${BASE_URL%/}"
PREFIX="${PREFIX#/}"; PREFIX="${PREFIX%/}"
S3_ROOT="s3://$BUCKET/$PREFIX/releases/$VERSION"
# CloudFront maps the public domain root to PREFIX via its Origin path.
HTTP_ROOT="$BASE_URL/releases/$VERSION"

STANDARD=""
for path in "$DIST"/*.dmg; do
  [ -f "$path" ] || continue
  case "$(basename "$path")" in *offline*) continue ;; esac
  STANDARD="$path"; break
done
[ -n "$STANDARD" ] || { echo "❌ standard DMG not found in $DIST" >&2; exit 1; }

STANDARD_NAME="$(basename "$STANDARD")"
STANDARD_SHA="$(shasum -a 256 "$STANDARD" | awk '{print $1}')"
STANDARD_SIZE="$(stat -f '%z' "$STANDARD")"
STANDARD_URL="$HTTP_ROOT/$STANDARD_NAME"

jq -n \
  --arg version "$VERSION" --arg tag "v$VERSION" --arg channel "$CHANNEL" \
  --arg dmg_url "$STANDARD_URL" --arg sha256 "$STANDARD_SHA" \
  --argjson dmg_size "$STANDARD_SIZE" \
  '{schema:1, version:$version, tag:$tag, channel:$channel, dmg_url:$dmg_url, dmg_size:$dmg_size, sha256:$sha256}' \
  > "$DIST/release.json"

upload_immutable() {
  local path="$1" content_type="$2" key="$3" digest existing
  digest="$(shasum -a 256 "$path" | awk '{print $1}')"
  existing="$(aws s3api head-object --bucket "$BUCKET" --key "$key" \
    --query 'Metadata.sha256' --output text 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != None ]; then
    [ "$existing" = "$digest" ] || { echo "❌ refusing to overwrite $key with different bytes" >&2; exit 1; }
    echo "  already uploaded: $key"
    return
  fi
  aws s3 cp "$path" "s3://$BUCKET/$key" --content-type "$content_type" \
    --cache-control 'public,max-age=31536000,immutable' --metadata "sha256=$digest" --only-show-errors
}

for path in "$DIST"/*.dmg "$DIST/SHA256SUMS.txt"; do
  [ -f "$path" ] || continue
  content_type=application/octet-stream
  case "$path" in *.dmg) content_type=application/x-apple-diskimage ;; *.txt) content_type=text/plain ;; esac
  upload_immutable "$path" "$content_type" "$PREFIX/releases/$VERSION/$(basename "$path")"
done
upload_immutable "$DIST/release.json" application/json "$PREFIX/releases/$VERSION/release.json"

if [ "$PUBLISH" = true ]; then
  aws s3 cp "$DIST/release.json" "s3://$BUCKET/$PREFIX/channels/$CHANNEL/latest.json" \
    --content-type application/json --cache-control 'no-cache, no-store, must-revalidate' --only-show-errors
fi

{
  echo "## Downloads"
  echo
  for path in "$DIST"/*.dmg; do
    [ -f "$path" ] || continue
    echo "- [$(basename "$path")]($HTTP_ROOT/$(basename "$path"))"
  done
  echo "- [SHA256SUMS.txt]($HTTP_ROOT/SHA256SUMS.txt)"
} > "$DIST/release-notes.md"

echo "✅ uploaded immutable release to $S3_ROOT"
[ "$PUBLISH" = true ] && echo "✅ advanced $CHANNEL channel feed"
