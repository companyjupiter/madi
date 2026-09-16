#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
CLI="$ROOT/apps/macos/scripts/madi_release.sh"
WRAPPER="$ROOT/apps/macos/scripts/release_local_free.sh"
WORK="$(mktemp -d)"
TEST_RELEASE_VERSION="99.99.99-localpublish.$$.$RANDOM"
TEST_RELEASE_ROOT="$ROOT/build/local-release/$TEST_RELEASE_VERSION"
TEST_RETIRED_VERSION="0.0.1-retired.$$.$RANDOM"
TEST_RETIRED_ROOT="$ROOT/build/local-release/$TEST_RETIRED_VERSION"

cleanup() {
  rm -rf "$WORK"
  case "$TEST_RELEASE_ROOT" in
    "$ROOT"/build/local-release/"$TEST_RELEASE_VERSION")
      rm -rf "$TEST_RELEASE_ROOT"
      ;;
  esac
  case "$TEST_RETIRED_ROOT" in
    "$ROOT"/build/local-release/"$TEST_RETIRED_VERSION")
      rm -rf "$TEST_RETIRED_ROOT"
      ;;
  esac
}
trap cleanup EXIT

pass_count=0
skip_count=0

pass() {
  pass_count=$((pass_count + 1))
}

skip() {
  printf 'SKIP: %s\n' "$1"
  skip_count=$((skip_count + 1))
}

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expect_ok() {
  local label="$1"
  shift
  local stdout_file="$WORK/stdout"
  local stderr_file="$WORK/stderr"
  if "$@" >"$stdout_file" 2>"$stderr_file"; then
    pass
    return 0
  fi
  cat "$stderr_file" >&2 || true
  die "$label"
}

expect_fail() {
  local label="$1"
  shift
  local stdout_file="$WORK/stdout"
  local stderr_file="$WORK/stderr"
  if "$@" >"$stdout_file" 2>"$stderr_file"; then
    cat "$stdout_file" >&2 || true
    die "$label"
  fi
  pass
  return 0
}

json_field() {
  local file="$1" field="$2"
  jq -r "$field" "$file"
}

if [ ! -f "$CLI" ]; then
  skip "apps/macos/scripts/madi_release.sh is not present yet"
  printf 'madi_release tests skipped (%d), passed (%d)\n' "$skip_count" "$pass_count"
  exit 0
fi

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
MOCK_AWS_LOG="$WORK/aws.log"

cat > "$FAKE_BIN/uname" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then
  printf 'arm64\n'
else
  /usr/bin/uname "$@"
fi
SH

cat > "$FAKE_BIN/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-C" ]; then
  shift 2
fi
case "${1:-}" in
  rev-parse)
    exit 1
    ;;
  rev-list)
    printf '42\n'
    ;;
  ls-files)
    if [ "${2:-}" = "--error-unmatch" ]; then
      exit 0
    fi
    exit 0
    ;;
  *)
    printf 'unsupported fake git invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH

cat > "$FAKE_BIN/aws" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mock_s3_path() {
  local uri="${1#s3://}"
  printf '%s/%s' "$MOCK_S3_ROOT" "$uri"
}
if [ "${1:-}" = "sts" ] && [ "${2:-}" = "get-caller-identity" ]; then
  printf '{"Account":"123456789012"}\n'
  exit 0
fi
if [ "${1:-}" = "s3api" ] && [ "${2:-}" = "head-object" ]; then
  shift 2
  bucket=""
  key=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bucket) bucket="$2"; shift 2 ;;
      --key) key="$2"; shift 2 ;;
      --query|--output) shift 2 ;;
      *) shift ;;
    esac
  done
  path="$MOCK_S3_ROOT/$bucket/$key"
  [ -f "$path" ] || exit 255
  if [ -f "$path.sha256" ]; then
    cat "$path.sha256"
  else
    printf 'None\n'
  fi
  exit 0
fi
if [ "${1:-}" = "s3" ] && [ "${2:-}" = "cp" ]; then
  source="$3"
  destination="$4"
  shift 4
  metadata=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --metadata) metadata="$2"; shift 2 ;;
      --content-type|--cache-control) shift 2 ;;
      --only-show-errors) shift ;;
      *) shift ;;
    esac
  done
  printf '%s -> %s\n' "$source" "$destination" >> "$MOCK_AWS_LOG"
  if [[ "$source" == s3://* ]]; then
    path="$(mock_s3_path "$source")"
    [ -f "$path" ] || {
      echo "An error occurred (NoSuchKey) when calling the GetObject operation" >&2
      exit 255
    }
    mkdir -p "$(dirname "$destination")"
    cp "$path" "$destination"
    exit 0
  fi
  path="$(mock_s3_path "$destination")"
  mkdir -p "$(dirname "$path")"
  cp "$source" "$path"
  case "$metadata" in
    sha256=*) printf '%s\n' "${metadata#sha256=}" > "$path.sha256" ;;
  esac
  exit 0
fi
if [ "${1:-}" = "s3" ] && [ "${2:-}" = "rm" ]; then
  uri="$3"
  shift 3
  recursive=0
  for arg in "$@"; do
    if [ "$arg" = --recursive ]; then
      recursive=1
    fi
  done
  printf 'rm %s\n' "$uri" >> "$MOCK_AWS_LOG"
  path="$(mock_s3_path "$uri")"
  if [ "$recursive" = 1 ]; then
    rm -rf "$path"
  else
    rm -f "$path"
  fi
  exit 0
fi
if [ "${1:-}" = "s3api" ] && [ "${2:-}" = "list-objects-v2" ]; then
  shift 2
  bucket=""
  prefix=""
  delimited=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bucket) bucket="$2"; shift 2 ;;
      --prefix) prefix="$2"; shift 2 ;;
      --delimiter) delimited=1; shift 2 ;;
      *) shift ;;
    esac
  done
  dir="$MOCK_S3_ROOT/$bucket/$prefix"
  if [ ! -d "$dir" ]; then
    printf 'null\n'
  elif [ "$delimited" = 1 ]; then
    find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
      | sort | sed "s|^|$prefix|; s|\$|/|" | jq -R . | jq -s .
  else
    find "$dir" -type f ! -name '*.sha256' | sort | sed "s|^$MOCK_S3_ROOT/$bucket/||" | jq -R . | jq -s .
  fi
  exit 0
fi
if [ "${1:-}" = "cloudfront" ] && [ "${2:-}" = "list-distributions" ]; then
  printf 'None\n'
  exit 0
fi
if [ "${1:-}" = "cloudfront" ] && [ "${2:-}" = "create-invalidation" ]; then
  printf 'invalidation %s\n' "$*" >> "$MOCK_AWS_LOG"
  printf 'ITEST\n'
  exit 0
fi
printf 'unsupported fake aws invocation: %s\n' "$*" >&2
exit 2
SH

cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  auth)
    exit 0
    ;;
  release)
    case "${2:-}" in
      view)
        case " $* " in
          *" --json assets "*"@tsv"*)
            printf '%s\tsha256:%s\n' "$MOCK_GH_ASSET_NAME" "$MOCK_GH_ASSET_SHA256"
            ;;
          *" --json assets "*)
            printf '%s\n' "$MOCK_GH_ASSET_NAME"
            ;;
          *" --json body "*)
            printf 'Existing release notes\n'
            ;;
        esac
        exit 0
        ;;
      edit)
        exit 0
        ;;
      download)
        printf 'unexpected GitHub download; local digest should match\n' >&2
        exit 2
        ;;
    esac
    ;;
esac
printf 'unsupported fake gh invocation: %s\n' "$*" >&2
exit 2
SH

cat > "$FAKE_BIN/swift" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$output" ] && : > "$output"
SH

cat > "$FAKE_BIN/shasum" <<'SH'
#!/usr/bin/env bash
/usr/bin/shasum "$@"
SH

chmod +x "$FAKE_BIN"/*

run_cli() {
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  MADI_SIGNING="${MADI_SIGNING_OVERRIDE:-adhoc}" \
  MADI_BUILD=42 \
  MADI_RELEASE_BUCKET=test-bucket \
  MADI_RELEASE_PREFIX=madi \
  MADI_DOWNLOAD_BASE_URL=https://downloads.example.test \
  SPARKLE_APPCAST_SIGN=0 \
  SPARKLE_ALLOW_UNSIGNED_APPCAST=1 \
  MOCK_S3_ROOT="$WORK/s3" \
  MOCK_AWS_LOG="$MOCK_AWS_LOG" \
  MADI_CLOUDFRONT_DISTRIBUTION_ID=EMOCK \
  MOCK_GH_ASSET_NAME="${MOCK_GH_ASSET_NAME:-madi-1.2.3-arm64.dmg}" \
  MOCK_GH_ASSET_SHA256="${MOCK_GH_ASSET_SHA256:-0000000000000000000000000000000000000000000000000000000000000000}" \
  "$CLI" "$@"
}

run_wrapper() {
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  MADI_SIGNING="${MADI_SIGNING_OVERRIDE:-adhoc}" \
  MADI_BUILD=42 \
  MADI_RELEASE_BUCKET=test-bucket \
  MADI_RELEASE_PREFIX=madi \
  MADI_DOWNLOAD_BASE_URL=https://downloads.example.test \
  SPARKLE_APPCAST_SIGN=0 \
  SPARKLE_ALLOW_UNSIGNED_APPCAST=1 \
  MOCK_S3_ROOT="$WORK/s3" \
  MOCK_AWS_LOG="$MOCK_AWS_LOG" \
  MOCK_GH_ASSET_NAME="${MOCK_GH_ASSET_NAME:-madi-1.2.3-arm64.dmg}" \
  MOCK_GH_ASSET_SHA256="${MOCK_GH_ASSET_SHA256:-0000000000000000000000000000000000000000000000000000000000000000}" \
  "$WRAPPER" "$@"
}

run_wrapper_with_github_asset() {
  local asset_name="$1" asset_sha256="$2"
  shift 2
  MOCK_GH_ASSET_NAME="$asset_name" \
  MOCK_GH_ASSET_SHA256="$asset_sha256" \
    run_wrapper "$@"
}

expect_ok "plan stable semver should succeed" run_cli plan 1.2.3 --json
jq -e '.version == "1.2.3" and .channel == "stable"' "$WORK/stdout" >/dev/null \
  || die "plan JSON should include stable version/channel"
[ -s "$WORK/stderr" ] && die "plan --json should keep stderr empty on success"
pass

expect_ok "plan beta semver should map channel=beta" run_cli plan 1.2.3-beta.1 --json
[ "$(json_field "$WORK/stdout" '.channel')" = "beta" ] || die "beta prerelease should map to beta channel"
pass

expect_ok "plan rc semver should map channel=rc" run_cli plan 1.2.3-rc.1 --json
[ "$(json_field "$WORK/stdout" '.channel')" = "rc" ] || die "rc prerelease should map to rc channel"
pass

# ── signing resolution ──────────────────────────────────────────────────────
expect_ok "plan should report the resolved signing mode" run_cli plan 1.2.3 --json
jq -e '.signing.mode == "adhoc" and (.signing.reason | type == "string")' "$WORK/stdout" >/dev/null \
  || die "plan JSON should expose signing.mode=adhoc with a reason when forced ad-hoc"

expect_fail "--require-notarized must fail a build when signing is unavailable" \
  run_cli build 1.2.3 --require-notarized --skip-tests --json

expect_ok "--require-notarized is advisory-only for plan" \
  run_cli plan 1.2.3 --require-notarized --json

# MADI_SIGNING=developer-id must refuse to fall back when credentials are
# absent. Notary env vars are explicitly blanked so this stays deterministic on
# machines that DO have credentials in the calling shell (a keychain identity
# alone is not enough — notary credentials are also required).
if MADI_SIGNING_OVERRIDE=developer-id NOTARY_PROFILE= NOTARY_KEY= NOTARY_KEY_ID= NOTARY_ISSUER= APPLE_ID= TEAM_ID= APP_PW= \
  run_cli plan 1.2.3 --json >"$WORK/stdout" 2>"$WORK/stderr"; then
  die "MADI_SIGNING=developer-id without credentials should be rejected"
fi
pass

if MADI_SIGNING_OVERRIDE=bogus run_cli plan 1.2.3 --json >"$WORK/stdout" 2>"$WORK/stderr"; then
  die "MADI_SIGNING=bogus should be rejected"
fi
pass

expect_fail "invalid semver should be rejected" run_cli plan 1.2 --json
expect_fail "unknown subcommand should be rejected" run_cli nonsense 1.2.3 --json
expect_fail "invalid beta expiry should be rejected" run_cli plan 1.2.3 --beta-expiry tomorrow --json
expect_fail "promote-github must reject offline flag" run_cli promote-github 1.2.3 --offline --json

rm -rf "$TEST_RELEASE_ROOT"
mkdir -p "$TEST_RELEASE_ROOT"
printf 'seed-dmg-%s\n' "$TEST_RELEASE_VERSION" > "$TEST_RELEASE_ROOT/madi-$TEST_RELEASE_VERSION-arm64.dmg"
(
  cd "$TEST_RELEASE_ROOT"
  /usr/bin/shasum -a 256 "madi-$TEST_RELEASE_VERSION-arm64.dmg" > SHA256SUMS.txt
)
jq -n \
  --arg version "$TEST_RELEASE_VERSION" \
  --arg assets_url "https://madi.devart.tv/runtime-assets/v1/madi-runtime-assets-v1.tar.gz" \
  --arg assets_sha256 "f6dc4bb3d3402aaf95a36ce7c1a86d6fd7483a320c6312004d83133d1cf017e5" \
  '
    {
      version: $version,
      gitSha: "unknown",
      gitDirty: false,
      source: "local-build",
      channel: "stable",
      buildNumber: "42",
      assetsUrl: $assets_url,
      assetsSha256: $assets_sha256,
      betaExpiry: "2026-12-01",
      includeOffline: false,
      signing: "adhoc",
      artifacts: [
        {name: ("madi-" + $version + "-arm64.dmg")}
      ]
    }
  ' > "$TEST_RELEASE_ROOT/manifest.json"

expect_ok "publish should reuse verified local artifact and emit final manifest JSON" \
  run_cli publish "$TEST_RELEASE_VERSION" --skip-tests --json
jq -s -e \
  --arg version "$TEST_RELEASE_VERSION" \
  '
    length == 1
    and .[0].status == "published"
    and .[0].published == true
    and .[0].version == $version
    and .[0].channel == "stable"
    and .[0].source == "local-build"
    and (.[0].artifacts | length == 1)
  ' "$WORK/stdout" >/dev/null || die "publish should emit a published manifest"
jq -e \
  --arg name "madi-$TEST_RELEASE_VERSION-arm64.dmg" \
  '.artifacts[0].name == $name' "$WORK/stdout" >/dev/null || {
    cat "$WORK/stdout" >&2 || true
    die "publish manifest should keep lowercase standard artifact name"
  }
jq -e \
  --arg url "https://downloads.example.test/releases/$TEST_RELEASE_VERSION/madi-$TEST_RELEASE_VERSION-arm64.dmg" \
  '.artifacts[0].url == $url' "$WORK/stdout" >/dev/null || {
    cat "$WORK/stdout" >&2 || true
    die "publish manifest should contain the public standard DMG URL"
  }
expected_sha="$(/usr/bin/shasum -a 256 "$TEST_RELEASE_ROOT/madi-$TEST_RELEASE_VERSION-arm64.dmg" | awk '{print $1}')"
[ "$(json_field "$WORK/stdout" '.artifacts[0].sha256')" = "$expected_sha" ] \
  || die "publish manifest should contain the standard DMG SHA-256"
[ -f "$WORK/s3/test-bucket/madi/releases/$TEST_RELEASE_VERSION/madi-$TEST_RELEASE_VERSION-arm64.dmg" ] \
  || die "publish should upload the versioned DMG to fake S3"
[ -f "$WORK/s3/test-bucket/madi/releases/index.json" ] \
  || die "publish should update the fake S3 release index"
[ -f "$WORK/s3/test-bucket/madi/channels/stable/latest.json" ] \
  || die "publish should update the fake stable channel feed"
[ "$(json_field "$WORK/s3/test-bucket/madi/channels/stable/latest.json" '.version')" = "$TEST_RELEASE_VERSION" ] \
  || die "stable latest.json should point at the published version"
[ "$(json_field "$WORK/s3/test-bucket/madi/releases/index.json" '.channels.stable')" = "$TEST_RELEASE_VERSION" ] \
  || die "release index should point stable at the published version"
[ "$(json_field "$WORK/s3/test-bucket/madi/releases/index.json" '.releases[0].objectKey')" = "madi/releases/$TEST_RELEASE_VERSION/madi-$TEST_RELEASE_VERSION-arm64.dmg" ] \
  || die "release index should publish the standard DMG object key"
pass

expect_ok "release_local_free --publish-local should remain idempotent over the same verified artifact" \
  run_wrapper "$TEST_RELEASE_VERSION" --publish-local --skip-tests --json
jq -s -e \
  --arg version "$TEST_RELEASE_VERSION" \
  '
    length == 1
    and .[0].command == "publish"
    and .[0].status == "published"
    and .[0].published == true
    and .[0].version == $version
    and (.[0].artifacts | length == 1)
  ' "$WORK/stdout" >/dev/null || die "publish-local wrapper should surface the same published manifest"
pass

printf 'stale-offline\n' > "$TEST_RELEASE_ROOT/madi-$TEST_RELEASE_VERSION-offline-arm64.dmg"
(
  cd "$TEST_RELEASE_ROOT"
  /usr/bin/shasum -a 256 ./*.dmg > SHA256SUMS.txt
)
: > "$MOCK_AWS_LOG"

expect_ok "upload should prune stale offline artifacts from a reused standard release root" \
  run_cli upload "$TEST_RELEASE_VERSION" --skip-tests --json
[ ! -f "$TEST_RELEASE_ROOT/madi-$TEST_RELEASE_VERSION-offline-arm64.dmg" ] \
  || die "upload should remove stale offline dmg before publishing"
jq -e '.includeOffline == false and (.artifacts | length == 1)' "$WORK/stdout" >/dev/null \
  || die "upload manifest should stay standard-only after pruning stale offline artifacts"
if grep -q "madi-$TEST_RELEASE_VERSION-offline-arm64.dmg" "$MOCK_AWS_LOG"; then
  die "upload should not send a stale offline dmg to fake S3"
fi
pass

printf 'legacy-stale-offline\n' > "$TEST_RELEASE_ROOT/madi-$TEST_RELEASE_VERSION-offline-arm64.dmg"
(
  cd "$TEST_RELEASE_ROOT"
  /usr/bin/shasum -a 256 ./*.dmg > SHA256SUMS.txt
)
: > "$MOCK_AWS_LOG"

expect_ok "release_local_free --publish should promote only the GitHub-verified standard DMG" \
  run_wrapper_with_github_asset \
    "madi-$TEST_RELEASE_VERSION-arm64.dmg" "$expected_sha" \
    "$TEST_RELEASE_VERSION" --publish --skip-tests --json
jq -s -e \
  --arg version "$TEST_RELEASE_VERSION" \
  '
    length == 1
    and .[0].command == "promote-github"
    and .[0].source == "github-release"
    and .[0].status == "published"
    and .[0].version == $version
    and (.[0].artifacts | length == 1)
  ' "$WORK/stdout" >/dev/null || die "legacy wrapper should emit one GitHub-origin published manifest"
[ ! -f "$TEST_RELEASE_ROOT/madi-$TEST_RELEASE_VERSION-offline-arm64.dmg" ] \
  || die "promote-github should remove a stale offline dmg before upload"
if grep -q "madi-$TEST_RELEASE_VERSION-offline-arm64.dmg" "$MOCK_AWS_LOG"; then
  die "promote-github should not send a stale offline dmg to fake S3"
fi
pass

# ── prune: retire every published version except the live stable ───────────
# The retired fixture has its own unique version: a refused prune still leaves
# its run directory under build/local-release/<version>/, which cleanup removes.
MOCK_BUCKET_DIR="$WORK/s3/test-bucket/madi"
RETIRED="$TEST_RETIRED_VERSION"
mkdir -p "$MOCK_BUCKET_DIR/releases/$RETIRED"
printf 'retired\n' > "$MOCK_BUCKET_DIR/releases/$RETIRED/madi-$RETIRED-arm64.dmg"
jq --arg retired "$RETIRED" '
  .releases += [{
    version: $retired,
    platform: "macos-arm64",
    objectKey: ("madi/releases/" + $retired + "/madi-" + $retired + "-arm64.dmg"),
    sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    size: 1,
    publishedAt: "2026-01-01T00:00:00Z"
  }]
' "$MOCK_BUCKET_DIR/releases/index.json" > "$WORK/index.tmp"
mv "$WORK/index.tmp" "$MOCK_BUCKET_DIR/releases/index.json"

expect_fail "--dry-run must be rejected outside prune" run_cli plan "$TEST_RELEASE_VERSION" --dry-run --json
expect_fail "prune must refuse a version that is not the live stable" run_cli prune "$RETIRED" --json
[ -f "$MOCK_BUCKET_DIR/releases/$RETIRED/madi-$RETIRED-arm64.dmg" ] || die "a refused prune must not delete anything"
jq -e '.releases | length == 2' "$MOCK_BUCKET_DIR/releases/index.json" >/dev/null || die "a refused prune must not rewrite the index"
[ -z "$(find "$TEST_RETIRED_ROOT" -name 'prune.json*' 2>/dev/null)" ] || die "a refused prune must not record a result"
pass

: > "$MOCK_AWS_LOG"
expect_ok "prune --dry-run should report the retired versions without deleting" \
  run_cli prune "$TEST_RELEASE_VERSION" --dry-run --json
jq -e --arg version "$TEST_RELEASE_VERSION" --arg retired "$RETIRED" '
  .command == "prune"
  and .version == $version
  and .applied == false
  and .kept == [$version]
  and .deleted == [$retired]
  and .deletedObjects == 1
  and .index.releasesBefore == 2
  and .index.releasesAfter == 1
' "$WORK/stdout" >/dev/null || { cat "$WORK/stdout" >&2; die "prune --dry-run JSON is wrong"; }
[ -f "$MOCK_BUCKET_DIR/releases/$RETIRED/madi-$RETIRED-arm64.dmg" ] || die "prune --dry-run must not delete"
jq -e '.releases | length == 2' "$MOCK_BUCKET_DIR/releases/index.json" >/dev/null || die "prune --dry-run must not rewrite the index"
if grep -Eq '^(rm |invalidation )' "$MOCK_AWS_LOG"; then
  die "prune --dry-run must not delete or invalidate"
fi
pass

: > "$MOCK_AWS_LOG"
expect_ok "prune should delete the retired versions, rewrite the index and invalidate the CDN" \
  run_cli prune "$TEST_RELEASE_VERSION" --json
jq -e --arg retired "$RETIRED" '
  .applied == true
  and .deleted == [$retired]
  and .index.releasesAfter == 1
  and .deletedObjects == 1
  and .cdn.distributionId == "EMOCK"
  and .cdn.invalidationId == "ITEST"
' "$WORK/stdout" >/dev/null || { cat "$WORK/stdout" >&2; die "prune JSON is wrong"; }
[ ! -e "$MOCK_BUCKET_DIR/releases/$RETIRED" ] || die "prune must delete the retired version directory"
[ -f "$MOCK_BUCKET_DIR/releases/$TEST_RELEASE_VERSION/madi-$TEST_RELEASE_VERSION-arm64.dmg" ] \
  || die "prune must keep the live stable version"
jq -e --arg version "$TEST_RELEASE_VERSION" '.channels.stable == $version and (.releases | length == 1)' \
  "$MOCK_BUCKET_DIR/releases/index.json" >/dev/null || die "the index must list only the kept version"
[ "$(json_field "$WORK/s3/test-bucket/madi/channels/stable/latest.json" '.version')" = "$TEST_RELEASE_VERSION" ] \
  || die "prune must not touch the channel feed"
grep -Fxq "rm s3://test-bucket/madi/releases/$RETIRED/" "$MOCK_AWS_LOG" || die "prune must delete by version prefix"
grep -Fq "invalidation cloudfront create-invalidation --distribution-id EMOCK --paths /releases/$RETIRED/madi-$RETIRED-arm64.dmg --query" "$MOCK_AWS_LOG" \
  || { cat "$MOCK_AWS_LOG" >&2; die "prune must invalidate the deleted object's exact path"; }
apply_run="$(json_field "$WORK/stdout" '.runDir')"
case "$apply_run" in
  "$TEST_RELEASE_ROOT"/prune/*-apply-*) ;;
  *) die "prune must record its run under the version's release root (got: $apply_run)" ;;
esac
[ -f "$apply_run/prune.json" ] && [ -f "$apply_run/release-index.before.json" ] \
  || die "the apply run must keep its result and the index it started from"
pass

expect_ok "a dry run after an apply should succeed with nothing left to retire" \
  run_cli prune "$TEST_RELEASE_VERSION" --dry-run --json
dry_run="$(json_field "$WORK/stdout" '.runDir')"
[ "$dry_run" != "$apply_run" ] || die "every prune run needs its own directory"
jq -e '.applied == false and .deleted == []' "$WORK/stdout" >/dev/null || die "a second prune should find nothing to retire"
jq -e --arg retired "$RETIRED" '.applied == true and .deleted == [$retired]' "$apply_run/prune.json" >/dev/null \
  || die "a later dry run must not overwrite the apply run's record"
jq -e '.releases | length == 2' "$apply_run/release-index.before.json" >/dev/null \
  || die "the apply run's pre-prune index must survive a later dry run"
pass

printf 'madi_release tests passed: %d, skipped: %d\n' "$pass_count" "$skip_count"
