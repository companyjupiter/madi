#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
PRUNE="${PRUNE_SCRIPT:-$ROOT/apps/macos/scripts/prune_s3_releases.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_BIN="$WORK/bin"
MOCK_S3_ROOT="$WORK/s3"
MOCK_AWS_LOG="$WORK/aws.log"
mkdir -p "$FAKE_BIN" "$MOCK_S3_ROOT"
: > "$MOCK_AWS_LOG"
export MOCK_S3_ROOT MOCK_AWS_LOG

cat > "$FAKE_BIN/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail

s3_path() {
  local uri="${1#s3://}"
  printf '%s/%s' "$MOCK_S3_ROOT" "$uri"
}

printf '%s\n' "$*" >> "$MOCK_AWS_LOG"

case "${1:-} ${2:-}" in
  "s3 cp")
    source="$3"
    destination="$4"
    if [[ "$source" == s3://* ]]; then
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
    exit 0
    ;;
  "s3 rm")
    uri="$3"
    shift 3
    recursive=0
    for arg in "$@"; do
      [ "$arg" = --recursive ] && recursive=1
    done
    path="$(s3_path "$uri")"
    if [ "$recursive" = 1 ]; then
      rm -rf "$path"
    else
      rm -f "$path"
    fi
    exit 0
    ;;
  "s3api list-objects-v2")
    shift 2
    bucket=""
    prefix=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --bucket) bucket="$2"; shift 2 ;;
        --prefix) prefix="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    dir="$MOCK_S3_ROOT/$bucket/$prefix"
    if [ -d "$dir" ]; then
      find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
        | sort | sed "s|^|$prefix|; s|\$|/|" | jq -R . | jq -s .
    else
      echo null
    fi
    exit 0
    ;;
  "cloudfront list-distributions")
    printf '%s\n' "${MOCK_CF_DISTRIBUTION:-None}"
    exit 0
    ;;
  "cloudfront create-invalidation")
    if [ "${MOCK_CF_FAIL:-0}" = 1 ]; then
      echo "An error occurred (AccessDenied) when calling the CreateInvalidation operation" >&2
      exit 255
    fi
    printf 'I%s\n' "${MOCK_CF_INVALIDATION_ID:-TEST}"
    exit 0
    ;;
esac

echo "unsupported fake aws invocation: $*" >&2
exit 2
AWS
chmod +x "$FAKE_BIN/aws"

BUCKET_DIR="$MOCK_S3_ROOT/downloads.example/madi"
INDEX="$BUCKET_DIR/releases/index.json"
LATEST="$BUCKET_DIR/channels/stable/latest.json"

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

seed_version() {
  local version="$1"
  mkdir -p "$BUCKET_DIR/releases/$version"
  printf 'dmg-%s\n' "$version" > "$BUCKET_DIR/releases/$version/madi-$version-arm64.dmg"
  printf '{"version":"%s"}\n' "$version" > "$BUCKET_DIR/releases/$version/release.json"
}

write_index() {
  local channels_json="$1"
  shift
  mkdir -p "$(dirname "$INDEX")"
  jq -n --argjson channels "$channels_json" --args '
    {
      channels: $channels,
      releases: [$ARGS.positional[] | {
        version: .,
        platform: "macos-arm64",
        objectKey: ("madi/releases/" + . + "/madi-" + . + "-arm64.dmg"),
        sha256: "0000000000000000000000000000000000000000000000000000000000000000",
        size: 1,
        publishedAt: "2026-01-01T00:00:00Z"
      }]
    }
  ' "$@" > "$INDEX"
}

run_prune() {
  local keep="$1" apply="$2"
  rm -rf "$WORK/out"
  PATH="$FAKE_BIN:$PATH" "$PRUNE" "$WORK/out" downloads.example https://downloads.example.test madi "$keep" "$apply"
}

reset_log() {
  : > "$MOCK_AWS_LOG"
}

# ── missing index: nothing to prune against ─────────────────────────────────
rm -rf "$MOCK_S3_ROOT/downloads.example"
if run_prune 1.1.0 true >/dev/null 2>&1; then
  die "prune must fail when the release index is missing"
fi

# ── fixture: three indexed versions, one orphan directory, one non-semver dir ─
seed_version 0.8.0
seed_version 0.9.0
seed_version 1.0.0
seed_version 1.1.0
mkdir -p "$BUCKET_DIR/releases/latest"
printf 'not a version\n' > "$BUCKET_DIR/releases/latest/README.txt"
write_index '{"stable":"1.1.0"}' 1.1.0 1.0.0 0.9.0
mkdir -p "$(dirname "$LATEST")"
printf '{"version":"1.1.0"}\n' > "$LATEST"
index_sha="$(shasum -a 256 "$INDEX" | awk '{print $1}')"

# ── keeper must be the live stable pointer ──────────────────────────────────
reset_log
if run_prune 1.0.0 true >/dev/null 2>&1; then
  die "prune must refuse a keep version that is not channels.stable"
fi
[ "$(shasum -a 256 "$INDEX" | awk '{print $1}')" = "$index_sha" ] || die "refused prune must not touch the index"
[ -d "$BUCKET_DIR/releases/1.0.0" ] || die "refused prune must not delete objects"
if grep -q '^s3 rm ' "$MOCK_AWS_LOG"; then
  die "refused prune must not issue deletes"
fi

# ── dry run: reports, changes nothing ───────────────────────────────────────
reset_log
run_prune 1.1.0 false > "$WORK/dry.json"
jq -e '
  .applied == false
  and .keepVersion == "1.1.0"
  and .kept == ["1.1.0"]
  and .deleted == ["0.8.0", "0.9.0", "1.0.0"]
  and .skipped == ["latest"]
  and .index.releasesBefore == 3
  and .index.releasesAfter == 1
  and .cdn.invalidationId == null
' "$WORK/dry.json" >/dev/null || { cat "$WORK/dry.json" >&2; die "dry run JSON is wrong"; }
[ "$(shasum -a 256 "$INDEX" | awk '{print $1}')" = "$index_sha" ] || die "dry run must not rewrite the index"
for version in 0.8.0 0.9.0 1.0.0 1.1.0; do
  [ -f "$BUCKET_DIR/releases/$version/madi-$version-arm64.dmg" ] || die "dry run must keep $version"
done
if grep -Eq '^(s3 rm |cloudfront create-invalidation)' "$MOCK_AWS_LOG"; then
  die "dry run must not delete or invalidate"
fi
jq -e '.releases | length == 1 and .[0].version == "1.1.0"' "$WORK/out/release-index.after.json" >/dev/null \
  || die "dry run should still write the rewritten index preview to the work dir"

# ── apply: index first, then deletes, then one invalidation ────────────────
reset_log
MOCK_CF_DISTRIBUTION=EABCDEF run_prune 1.1.0 true > "$WORK/apply.json"
jq -e '
  .applied == true
  and .deleted == ["0.8.0", "0.9.0", "1.0.0"]
  and .skipped == ["latest"]
  and .cdn.distributionId == "EABCDEF"
  and .cdn.invalidationId == "ITEST"
  and .cdn.note == null
' "$WORK/apply.json" >/dev/null || { cat "$WORK/apply.json" >&2; die "apply JSON is wrong"; }
jq -e '.channels.stable == "1.1.0" and (.releases | length == 1) and .releases[0].version == "1.1.0"' "$INDEX" >/dev/null \
  || die "apply must leave only the keeper in the index"
for version in 0.8.0 0.9.0 1.0.0; do
  [ ! -e "$BUCKET_DIR/releases/$version" ] || die "apply must delete releases/$version/"
done
[ -f "$BUCKET_DIR/releases/1.1.0/madi-1.1.0-arm64.dmg" ] || die "apply must keep the keeper's objects"
[ -f "$BUCKET_DIR/releases/latest/README.txt" ] || die "apply must not touch non-semver directories"
[ "$(cat "$LATEST")" = '{"version":"1.1.0"}' ] || die "apply must not touch the channel feed"
index_line="$(grep -n 'madi/releases/index.json' "$MOCK_AWS_LOG" | grep ' cp ' | tail -1 | cut -d: -f1)"
first_rm_line="$(grep -n '^s3 rm ' "$MOCK_AWS_LOG" | head -1 | cut -d: -f1)"
[ -n "$index_line" ] && [ -n "$first_rm_line" ] && [ "$index_line" -lt "$first_rm_line" ] \
  || die "the index must be rewritten before the first delete"
grep -q '^s3 rm s3://downloads.example/madi/releases/0.9.0/ --recursive' "$MOCK_AWS_LOG" \
  || die "deletes must be recursive per version prefix"
[ "$(grep -c '^cloudfront create-invalidation' "$MOCK_AWS_LOG")" = 1 ] || die "apply must issue exactly one invalidation"
grep -q '^cloudfront create-invalidation --distribution-id EABCDEF --paths /releases/0.8.0/\* /releases/0.9.0/\* /releases/1.0.0/\*' "$MOCK_AWS_LOG" \
  || { cat "$MOCK_AWS_LOG" >&2; die "invalidation must cover every deleted version path"; }

# ── idempotent: a second apply deletes and invalidates nothing ─────────────
reset_log
MOCK_CF_DISTRIBUTION=EABCDEF run_prune 1.1.0 true > "$WORK/again.json"
jq -e '.applied == true and .deleted == [] and .cdn.invalidationId == null' "$WORK/again.json" >/dev/null \
  || { cat "$WORK/again.json" >&2; die "second apply should be a no-op"; }
if grep -Eq '^(s3 rm |cloudfront create-invalidation)' "$MOCK_AWS_LOG"; then
  die "second apply must not delete or invalidate"
fi

# ── every channel pointer survives, not only stable ─────────────────────────
seed_version 1.0.0
seed_version 1.2.0-beta.1
write_index '{"stable":"1.1.0","beta":"1.2.0-beta.1"}' 1.2.0-beta.1 1.1.0 1.0.0
reset_log
run_prune 1.1.0 true > "$WORK/beta.json"
jq -e '.kept == ["1.1.0", "1.2.0-beta.1"] and .deleted == ["1.0.0"]' "$WORK/beta.json" >/dev/null \
  || { cat "$WORK/beta.json" >&2; die "beta channel pointer must be kept"; }
[ -d "$BUCKET_DIR/releases/1.2.0-beta.1" ] || die "beta pointer's objects must survive"
[ ! -e "$BUCKET_DIR/releases/1.0.0" ] || die "unreferenced version must be deleted"
jq -e '(.releases | map(.version)) == ["1.2.0-beta.1", "1.1.0"] and .channels.beta == "1.2.0-beta.1"' "$INDEX" >/dev/null \
  || die "index must keep both channel pointers"

# ── CDN problems never undo a completed prune ───────────────────────────────
rm -rf "$BUCKET_DIR/releases/1.2.0-beta.1"
seed_version 1.0.0
write_index '{"stable":"1.1.0"}' 1.1.0 1.0.0
reset_log
MOCK_CF_DISTRIBUTION=EABCDEF MOCK_CF_FAIL=1 run_prune 1.1.0 true > "$WORK/cdnfail.json"
jq -e '.applied == true and .deleted == ["1.0.0"] and .cdn.invalidationId == null and (.cdn.note | test("create-invalidation failed"))' \
  "$WORK/cdnfail.json" >/dev/null || { cat "$WORK/cdnfail.json" >&2; die "invalidation failure must be reported, not fatal"; }
[ ! -e "$BUCKET_DIR/releases/1.0.0" ] || die "objects must still be deleted when invalidation fails"

seed_version 1.0.0
write_index '{"stable":"1.1.0"}' 1.1.0 1.0.0
reset_log
run_prune 1.1.0 true > "$WORK/nocdn.json"
jq -e '.applied == true and .deleted == ["1.0.0"] and .cdn.distributionId == null and (.cdn.note | test("no CloudFront distribution"))' \
  "$WORK/nocdn.json" >/dev/null || { cat "$WORK/nocdn.json" >&2; die "missing distribution must be reported"; }
if grep -q '^cloudfront create-invalidation' "$MOCK_AWS_LOG"; then
  die "no invalidation without a distribution"
fi

# ── a pinned distribution id skips discovery ────────────────────────────────
seed_version 1.0.0
write_index '{"stable":"1.1.0"}' 1.1.0 1.0.0
reset_log
MADI_CLOUDFRONT_DISTRIBUTION_ID=EPINNED run_prune 1.1.0 true > "$WORK/pinned.json"
jq -e '.cdn.distributionId == "EPINNED" and .cdn.invalidationId == "ITEST"' "$WORK/pinned.json" >/dev/null \
  || { cat "$WORK/pinned.json" >&2; die "pinned distribution id must be used"; }
if grep -q '^cloudfront list-distributions' "$MOCK_AWS_LOG"; then
  die "pinned distribution id must skip discovery"
fi

echo "release prune tests passed"
