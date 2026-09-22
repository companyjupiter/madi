#!/usr/bin/env bash
# Upload versioned DMGs/checksums to S3, then advance public release metadata.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
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
CHANNEL_ROOT="$BASE_URL/channels/$CHANNEL"

STANDARD=""
for path in "$DIST"/*.dmg; do
  [ -f "$path" ] || continue
  case "$(basename "$path")" in *offline*) continue ;; esac
  STANDARD="$path"; break
done
[ -n "$STANDARD" ] || { echo "❌ standard DMG not found in $DIST" >&2; exit 1; }

STANDARD_NAME="$(basename "$STANDARD")"
STANDARD_SHA="$(shasum -a 256 "$STANDARD" | awk '{print $1}')"
STANDARD_SIZE="$(wc -c < "$STANDARD" | tr -d '[:space:]')"
STANDARD_URL="$HTTP_ROOT/$STANDARD_NAME"

jq -n \
  --arg version "$VERSION" --arg tag "v$VERSION" --arg channel "$CHANNEL" \
  --arg dmg_url "$STANDARD_URL" --arg sha256 "$STANDARD_SHA" \
  --argjson dmg_size "$STANDARD_SIZE" \
  '{schema:1, version:$version, tag:$tag, channel:$channel, dmg_url:$dmg_url, dmg_size:$dmg_size, sha256:$sha256}' \
  > "$DIST/release.json"

sparkle_signature_attributes() {
  [ "${SPARKLE_APPCAST_SIGN:-1}" = "1" ] || return 0
  local sparkle_dir output status
  sparkle_dir="$("$HERE/ensure_sparkle.sh" 2>/dev/null || true)"
  if [ -z "$sparkle_dir" ] || [ ! -x "$sparkle_dir/bin/sign_update" ]; then
    echo "  ⚠ Sparkle sign_update not available — appcast will not contain edSignature" >&2
    return 0
  fi
  set +e
  if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    output="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_dir/bin/sign_update" --ed-key-file - "$STANDARD" 2>&1)"
    status=$?
  elif [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
    output="$("$sparkle_dir/bin/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$STANDARD" 2>&1)"
    status=$?
  else
    output="$("$sparkle_dir/bin/sign_update" "$STANDARD" 2>&1)"
    status=$?
  fi
  set -e
  if [ "$status" -ne 0 ]; then
    if [ "${SPARKLE_REQUIRE_SIGNATURE:-0}" = "1" ] \
      || { [ "$PUBLISH" = true ] && [ "${SPARKLE_ALLOW_UNSIGNED_APPCAST:-0}" != "1" ]; }; then
      echo "$output" >&2
      echo "❌ Sparkle update signing failed" >&2
      exit 1
    fi
    echo "  ⚠ Sparkle update signing skipped: $output" >&2
    return 0
  fi
  output="$(printf '%s' "$output" | sed -E 's/(^| )length="[^"]*"//g; s/  +/ /g; s/^ //; s/ $//')"
  printf '%s' "$output"
}

write_appcast() {
  local appcast="$DIST/appcast.xml"
  local signature_attrs
  command -v python3 >/dev/null || { echo "❌ python3 is required to write Sparkle appcast" >&2; exit 1; }
  signature_attrs="$(sparkle_signature_attributes)"
  env \
    APPCAST_PATH="$appcast" \
    APPCAST_TITLE="Madi Updates ($CHANNEL)" \
    APPCAST_LINK="$CHANNEL_ROOT/appcast.xml" \
    APPCAST_RELEASE_TITLE="Madi $VERSION" \
    APPCAST_VERSION="${MADI_BUILD:-1}" \
    APPCAST_SHORT_VERSION="$VERSION" \
    APPCAST_DMG_URL="$STANDARD_URL" \
    APPCAST_DMG_SIZE="$STANDARD_SIZE" \
    APPCAST_SIGNATURE_ATTRS="$signature_attrs" \
    python3 - <<'PY'
import email.utils
import html
import os
from pathlib import Path

def x(value: str) -> str:
    return html.escape(value, quote=True)

path = Path(os.environ["APPCAST_PATH"])
signature_attrs = os.environ.get("APPCAST_SIGNATURE_ATTRS", "").strip()
if signature_attrs:
    signature_attrs = " " + signature_attrs

path.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>{x(os.environ["APPCAST_TITLE"])}</title>
    <link>{x(os.environ["APPCAST_LINK"])}</link>
    <description>Madi macOS update feed</description>
    <item>
      <title>{x(os.environ["APPCAST_RELEASE_TITLE"])}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <enclosure
        url="{x(os.environ["APPCAST_DMG_URL"])}"
        sparkle:version="{x(os.environ["APPCAST_VERSION"])}"
        sparkle:shortVersionString="{x(os.environ["APPCAST_SHORT_VERSION"])}"
        length="{x(os.environ["APPCAST_DMG_SIZE"])}"
        type="application/octet-stream"{signature_attrs} />
    </item>
  </channel>
</rss>
''', encoding="utf-8")
PY
}

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

update_release_index() {
  local key="$PREFIX/releases/index.json"
  local current="$DIST/release-index.current.json"
  local next="$DIST/release-index.json"
  local download_error="$DIST/release-index.download-error.txt"
  local object_key="$PREFIX/releases/$VERSION/$STANDARD_NAME"
  local published_at

  if aws s3 cp "s3://$BUCKET/$key" "$current" --only-show-errors 2>"$download_error"; then
    rm -f "$download_error"
  elif grep -Eq '(^|[^0-9])404([^0-9]|$)|NoSuchKey|Not Found|does not exist' "$download_error"; then
    if [ "$CHANNEL" != stable ]; then
      echo "❌ cannot publish $CHANNEL release before the first stable release index exists" >&2
      return 1
    fi
    jq -n --arg stable "$VERSION" '{channels:{stable:$stable},releases:[]}' > "$current"
    rm -f "$download_error"
  else
    echo "❌ unable to read s3://$BUCKET/$key" >&2
    cat "$download_error" >&2
    return 1
  fi

  jq -e '
    type == "object"
    and (.channels | type == "object")
    and (.releases | type == "array")
  ' "$current" >/dev/null || {
    echo "❌ existing release index is invalid" >&2
    return 1
  }

  published_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq \
    --arg version "$VERSION" \
    --arg channel "$CHANNEL" \
    --arg object_key "$object_key" \
    --arg sha256 "$STANDARD_SHA" \
    --arg published_at "$published_at" \
    --argjson size "$STANDARD_SIZE" \
    '
      ([.releases[]
        | select(.version == $version and .platform == "macos-arm64")
        | .publishedAt][0] // $published_at) as $release_date
      | .releases = (
          [{
            version: $version,
            platform: "macos-arm64",
            objectKey: $object_key,
            sha256: $sha256,
            size: $size,
            publishedAt: $release_date
          }]
          + [.releases[]
            | select(.version != $version or .platform != "macos-arm64")]
        )
      | if $channel == "stable" then .channels.stable = $version else . end
      | . as $index
      | if (
          (.channels.stable | type) == "string"
          and any(.releases[];
            .version == $index.channels.stable and .platform == "macos-arm64")
        ) then .
        else error("stable channel must reference a macos-arm64 release")
        end
    ' "$current" > "$next"

  aws s3 cp "$next" "s3://$BUCKET/$key" \
    --content-type application/json \
    --cache-control 'no-cache, no-store, must-revalidate' \
    --only-show-errors
}

for path in "$DIST"/*.dmg "$DIST"/*.spdx.json "$DIST/SHA256SUMS.txt"; do
  [ -f "$path" ] || continue
  content_type=application/octet-stream
  case "$path" in
    *.dmg) content_type=application/x-apple-diskimage ;;
    *.spdx.json) content_type=application/spdx+json ;;
    *.txt) content_type=text/plain ;;
  esac
  upload_immutable "$path" "$content_type" "$PREFIX/releases/$VERSION/$(basename "$path")"
done
upload_immutable "$DIST/release.json" application/json "$PREFIX/releases/$VERSION/release.json"
write_appcast

if [ "$PUBLISH" = true ]; then
  update_release_index
  aws s3 cp "$DIST/release.json" "s3://$BUCKET/$PREFIX/channels/$CHANNEL/latest.json" \
    --content-type application/json --cache-control 'no-cache, no-store, must-revalidate' --only-show-errors
  aws s3 cp "$DIST/appcast.xml" "s3://$BUCKET/$PREFIX/channels/$CHANNEL/appcast.xml" \
    --content-type application/rss+xml --cache-control 'no-cache, no-store, must-revalidate' --only-show-errors
fi

{
  echo "## Downloads"
  echo
  for path in "$DIST"/*.dmg; do
    [ -f "$path" ] || continue
    echo "- [$(basename "$path")]($HTTP_ROOT/$(basename "$path"))"
  done
  for path in "$DIST"/*.spdx.json; do
    [ -f "$path" ] || continue
    echo "- [$(basename "$path")]($HTTP_ROOT/$(basename "$path"))"
  done
  echo "- [SHA256SUMS.txt]($HTTP_ROOT/SHA256SUMS.txt)"
  echo "- [Sparkle appcast]($CHANNEL_ROOT/appcast.xml)"
} > "$DIST/release-notes.md"

echo "✅ uploaded immutable release to $S3_ROOT"
if [ "$PUBLISH" = true ]; then
  echo "✅ advanced $CHANNEL channel feed and release index"
fi
