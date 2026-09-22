#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
PUBLISH="$ROOT/apps/macos/scripts/publish_s3_release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_BIN="$WORK/bin"
MOCK_S3_ROOT="$WORK/s3"
mkdir -p "$FAKE_BIN" "$MOCK_S3_ROOT"
export MOCK_S3_ROOT

cat > "$FAKE_BIN/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail

s3_path() {
  local uri="${1#s3://}"
  printf '%s/%s' "$MOCK_S3_ROOT" "$uri"
}

if [ "${1:-}" = s3api ] && [ "${2:-}" = head-object ]; then
  shift 2
  bucket=""
  key=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bucket) bucket="$2"; shift 2 ;;
      --key) key="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  path="$MOCK_S3_ROOT/$bucket/$key"
  [ -f "$path" ] || exit 255
  if [ -f "$path.sha256" ]; then
    cat "$path.sha256"
  else
    echo None
  fi
  exit 0
fi

if [ "${1:-}" = s3 ] && [ "${2:-}" = cp ]; then
  source="$3"
  destination="$4"
  shift 4
  metadata=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --metadata) metadata="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ "$source" == s3://* ]]; then
    if [ "${MOCK_DENY_INDEX_READ:-}" = 1 ] && [[ "$source" == */releases/index.json ]]; then
      echo "An error occurred (AccessDenied) when calling the GetObject operation" >&2
      exit 255
    fi
    path="$(s3_path "$source")"
    if [ ! -f "$path" ]; then
      echo "An error occurred (NoSuchKey) when calling the GetObject operation" >&2
      exit 255
    fi
    mkdir -p "$(dirname "$destination")"
    cp "$path" "$destination"
    exit 0
  fi

  path="$(s3_path "$destination")"
  mkdir -p "$(dirname "$path")"
  cp "$source" "$path"
  case "$metadata" in
    sha256=*) printf '%s\n' "${metadata#sha256=}" > "$path.sha256" ;;
  esac
  exit 0
fi

echo "unsupported fake aws invocation: $*" >&2
exit 2
AWS
chmod +x "$FAKE_BIN/aws"

publish_release() {
  local version="$1" channel="$2" publish="$3" dist="$WORK/dist"
  rm -rf "$dist"
  mkdir -p "$dist"
  printf 'dmg-%s\n' "$version" > "$dist/madi-$version-arm64.dmg"
  printf '{"spdxVersion":"SPDX-2.3","name":"madi-%s"}\n' "$version" > "$dist/madi-$version-arm64.spdx.json"
  (
    cd "$dist"
    shasum -a 256 "madi-$version-arm64.dmg" "madi-$version-arm64.spdx.json" > SHA256SUMS.txt
  )
  SPARKLE_APPCAST_SIGN=0 SPARKLE_ALLOW_UNSIGNED_APPCAST=1 PATH="$FAKE_BIN:$PATH" "$PUBLISH" "$dist" downloads.example \
    https://downloads.example.test madi "$version" "$channel" "$publish"
}

INDEX="$MOCK_S3_ROOT/downloads.example/madi/releases/index.json"
STABLE_APPCAST="$MOCK_S3_ROOT/downloads.example/madi/channels/stable/appcast.xml"
BETA_APPCAST="$MOCK_S3_ROOT/downloads.example/madi/channels/beta/appcast.xml"

publish_release 0.9.0 stable true
[ -s "$MOCK_S3_ROOT/downloads.example/madi/releases/0.9.0/madi-0.9.0-arm64.spdx.json" ]
grep -Fq 'madi-0.9.0-arm64.spdx.json' "$WORK/dist/release-notes.md"
jq -e '
  .channels.stable == "0.9.0"
  and (.releases | length == 1)
  and .releases[0].version == "0.9.0"
  and .releases[0].platform == "macos-arm64"
  and .releases[0].objectKey == "madi/releases/0.9.0/madi-0.9.0-arm64.dmg"
  and (.releases[0].sha256 | test("^[0-9a-f]{64}$"))
  and (.releases[0].size > 0)
  and (.releases[0].publishedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
' "$INDEX" >/dev/null
grep -Fq 'sparkle:shortVersionString="0.9.0"' "$STABLE_APPCAST"
grep -Fq 'url="https://downloads.example.test/releases/0.9.0/madi-0.9.0-arm64.dmg"' "$STABLE_APPCAST"

publish_release 0.10.0-beta.1 beta true
jq -e '
  .channels.stable == "0.9.0"
  and (.releases | length == 2)
  and .releases[0].version == "0.10.0-beta.1"
' "$INDEX" >/dev/null
grep -Fq 'sparkle:shortVersionString="0.10.0-beta.1"' "$BETA_APPCAST"
grep -Fq 'url="https://downloads.example.test/releases/0.10.0-beta.1/madi-0.10.0-beta.1-arm64.dmg"' "$BETA_APPCAST"

publish_release 0.10.0-beta.1 beta true
jq -e '[.releases[] | select(.version == "0.10.0-beta.1")] | length == 1' "$INDEX" >/dev/null

index_sha="$(shasum -a 256 "$INDEX" | awk '{print $1}')"
if MOCK_DENY_INDEX_READ=1 publish_release 0.10.1 stable true >/dev/null 2>&1; then
  echo "release unexpectedly succeeded when index reads were denied" >&2
  exit 1
fi
[ "$(shasum -a 256 "$INDEX" | awk '{print $1}')" = "$index_sha" ]

publish_release 0.11.0 stable false
jq -e '
  .channels.stable == "0.9.0"
  and ([.releases[] | select(.version == "0.11.0")] | length == 0)
' "$INDEX" >/dev/null

echo "release index publication tests passed"
