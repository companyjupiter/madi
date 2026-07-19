#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: release_local_free.sh <version> [--upload|--publish] [--offline] [--skip-tests] [--beta-expiry YYYY-MM-DD]

Build a local free-account macOS release.
  default    build artifacts only
  --upload   upload immutable versioned objects to S3
  --publish  upload and advance channel/index metadata
EOF
}

die() {
  echo "❌ $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

validate_date() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DEFAULT_BETA_EXPIRY="2026-12-01"
DEFAULT_ASSETS_URL="https://madi.devart.tv/runtime-assets/v1/madi-runtime-assets-v1.tar.gz"
DEFAULT_ASSETS_SHA256="f6dc4bb3d3402aaf95a36ce7c1a86d6fd7483a320c6312004d83133d1cf017e5"
SPEECH_MODEL_URL="https://huggingface.co/jupitersong/madi-whisper-turbo-v3-q8/resolve/main/model.q8.safetensors"
SPEECH_MODEL_SHA256="1014fd3ad4450a2e43e473eebbab485b165fd68cbe932372071d86c522bb5c8e"
MODE="build"
INCLUDE_OFFLINE=0
RUN_TESTS=1
BETA_EXPIRY=""
GITHUB_DMG_NAME=""
GITHUB_DMG_SHA256=""

VERSION="${1:-}"
[ "$VERSION" = "--help" ] || [ "$VERSION" = "-h" ] && { usage; exit 0; }
[ -n "$VERSION" ] || { usage >&2; exit 1; }
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --upload)
      [ "$MODE" = build ] || die "choose only one of --upload or --publish"
      MODE="upload"
      ;;
    --publish)
      [ "$MODE" = build ] || die "choose only one of --upload or --publish"
      MODE="publish"
      ;;
    --offline)
      INCLUDE_OFFLINE=1
      ;;
    --skip-tests)
      RUN_TESTS=0
      ;;
    --beta-expiry)
      shift
      [ "$#" -ge 1 ] || die "--beta-expiry requires YYYY-MM-DD"
      BETA_EXPIRY="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] \
  || die "version must be full SemVer without leading v"

CHANNEL=stable
[[ "$VERSION" == *-beta.* ]] && CHANNEL=beta
[[ "$VERSION" == *-rc.* ]] && CHANNEL=rc

if [ -z "$BETA_EXPIRY" ]; then
  BETA_EXPIRY="$DEFAULT_BETA_EXPIRY"
fi
validate_date "$BETA_EXPIRY" || die "beta expiry must be YYYY-MM-DD"

if [ -n "${MADI_RELEASE_ASSETS_URL:-}" ] || [ -n "${MADI_RELEASE_ASSETS_SHA256:-}" ]; then
  [ -n "${MADI_RELEASE_ASSETS_URL:-}" ] || die "MADI_RELEASE_ASSETS_SHA256 requires MADI_RELEASE_ASSETS_URL"
  [ -n "${MADI_RELEASE_ASSETS_SHA256:-}" ] || die "MADI_RELEASE_ASSETS_URL requires MADI_RELEASE_ASSETS_SHA256"
fi
ASSETS_URL="${MADI_RELEASE_ASSETS_URL:-$DEFAULT_ASSETS_URL}"
ASSETS_SHA256="${MADI_RELEASE_ASSETS_SHA256:-$DEFAULT_ASSETS_SHA256}"

BUILD_NUMBER="${MADI_BUILD:-}"
if [ -z "$BUILD_NUMBER" ]; then
  if git -C "$ROOT" rev-parse --verify --quiet "refs/tags/v$VERSION" >/dev/null; then
    BUILD_NUMBER="$(git -C "$ROOT" rev-list --count "v$VERSION")"
  else
    BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
  fi
fi
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "MADI_BUILD must contain digits only"

RELEASE_ROOT="$ROOT/build/local-release/$VERSION"
case "$RELEASE_ROOT" in
  "$ROOT"/build/local-release/*) ;;
  *) die "refusing to use unsafe output path: $RELEASE_ROOT" ;;
esac

cleanup() {
  if [ -n "${TMP_ASSET_ARCHIVE:-}" ] && [ -f "$TMP_ASSET_ARCHIVE" ]; then
    rm -f "$TMP_ASSET_ARCHIVE"
  fi
  return 0
}
trap cleanup EXIT

run_release_gates() {
  local script repo_rel
  while IFS= read -r repo_rel; do
    [ -n "$repo_rel" ] || continue
    script="$ROOT/$repo_rel"
    bash -n "$script"
  done < <(git -C "$ROOT" ls-files '*.sh')

  if ! git -C "$ROOT" ls-files --error-unmatch "apps/macos/scripts/release_local_free.sh" >/dev/null 2>&1; then
    bash -n "$HERE/release_local_free.sh"
  fi

  "$HERE/tests/publish_s3_release_test.sh"
  (cd "$ROOT/apps/macos" && swift test)
}

run_preflight() {
  local asset_count asset_line asset_lines digest
  [ "$(uname -m)" = arm64 ] || die "arm64 host required"

  if [ "$MODE" != build ]; then
    require_cmd aws
    require_cmd jq
    aws sts get-caller-identity >/dev/null
  fi
  if [ "$MODE" = publish ]; then
    [ "$INCLUDE_OFFLINE" = 0 ] || die "--offline cannot be combined with publishing an existing release"
    require_cmd gh
    gh auth status --hostname github.com >/dev/null
    gh release view "v$VERSION" --repo companyjupiter/madi >/dev/null 2>&1 \
      || die "GitHub Release v$VERSION must already exist before publishing"
    asset_lines="$(gh release view "v$VERSION" --repo companyjupiter/madi --json assets \
      --jq '.assets[] | select((.name | ascii_downcase | endswith(".dmg")) and ((.name | ascii_downcase | contains("offline")) | not)) | [.name, .digest] | @tsv' \
    )"
    asset_count="$(printf '%s\n' "$asset_lines" | awk 'NF { count++ } END { print count + 0 }')"
    [ "$asset_count" -eq 1 ] \
      || die "GitHub Release v$VERSION must contain exactly one standard DMG asset (found $asset_count)"
    asset_line="$asset_lines"
    IFS=$'\t' read -r GITHUB_DMG_NAME digest <<< "$asset_line"
    GITHUB_DMG_SHA256="$(printf '%s' "${digest#sha256:}" | tr '[:upper:]' '[:lower:]')"
    [[ "$GITHUB_DMG_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] \
      || die "GitHub Release asset $GITHUB_DMG_NAME has no SHA-256 digest"
  fi
}

refresh_release_assets() {
  require_cmd curl
  TMP_ASSET_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/madi-release-assets.XXXXXX")"
  curl --fail --location --retry 3 "$ASSETS_URL" --output "$TMP_ASSET_ARCHIVE"
  "$HERE/prepare_release_assets.sh" "$TMP_ASSET_ARCHIVE" "$ASSETS_SHA256"
}

build_dmg() {
  local build_dir="$1" dmg_version="$2" final_name="$3"
  shift 3
  mkdir -p "$build_dir"
  env "$@" "$HERE/make_app.sh" "$build_dir"
  "$HERE/verify_release_bundle.sh" "$build_dir/Madi.app" "$VERSION"
  (
    cd "$RELEASE_ROOT"
    SKIP_STAPLE=1 "$HERE/make_dmg.sh" "$build_dir/Madi.app" "$dmg_version"
  )
  mv "$RELEASE_ROOT/Madi-$dmg_version.dmg" "$RELEASE_ROOT/$final_name"
}

ensure_offline_model() {
  local model="$ROOT/engine/metal/bench/runs/model.q8.safetensors"

  if [ ! -f "$model" ]; then
    require_cmd curl
    mkdir -p "$(dirname "$model")"
    curl --fail --location --retry 3 "$SPEECH_MODEL_URL" --output "$model"
  fi
  echo "$SPEECH_MODEL_SHA256  $model" | shasum -a 256 -c -
}

upload_release() {
  local publish_flag=false
  local bucket="${MADI_RELEASE_BUCKET:-devart-teamjupiter-downloads-artdapne2}"
  local prefix="${MADI_RELEASE_PREFIX:-madi}"
  local base_url="${MADI_DOWNLOAD_BASE_URL:-https://madi.devart.tv}"

  [ "$MODE" = publish ] && publish_flag=true

  "$HERE/publish_s3_release.sh" "$RELEASE_ROOT" "$bucket" "$base_url" "$prefix" \
    "$VERSION" "$CHANNEL" "$publish_flag"
}

publish_github_release() {
  local tag="v$VERSION"
  local notes="$RELEASE_ROOT/github-release-notes.md"

  gh release view "$tag" --repo companyjupiter/madi >/dev/null 2>&1 \
    || die "GitHub Release $tag must already exist before publishing"
  gh release view "$tag" --repo companyjupiter/madi --json assets \
    --jq '.assets[].name' | grep -Eqi '\.dmg$' \
    || die "GitHub Release $tag has no DMG asset for the current in-app updater"

  gh release view "$tag" --repo companyjupiter/madi --json body --jq .body > "$notes"
  if ! grep -Fq "madi-$VERSION-arm64.dmg" "$notes"; then
    printf '\n\n' >> "$notes"
    command cat "$RELEASE_ROOT/release-notes.md" >> "$notes"
  fi
  gh release edit "$tag" --repo companyjupiter/madi \
    --notes-file "$notes" --draft=false
}

can_reuse_artifacts() {
  [ "$MODE" != build ] || return 1
  [ -f "$RELEASE_ROOT/madi-$VERSION-arm64.dmg" ] || return 1
  [ -f "$RELEASE_ROOT/SHA256SUMS.txt" ] || return 1
  if [ "$INCLUDE_OFFLINE" = 1 ]; then
    [ -f "$RELEASE_ROOT/madi-$VERSION-offline-arm64.dmg" ] || return 1
  fi
  (cd "$RELEASE_ROOT" && shasum -a 256 -c SHA256SUMS.txt >/dev/null)
}

prepare_existing_release_artifact() {
  local standard="$RELEASE_ROOT/madi-$VERSION-arm64.dmg"
  local actual

  if [ -f "$standard" ]; then
    actual="$(shasum -a 256 "$standard" | awk '{print $1}')"
    if [ "$actual" = "$GITHUB_DMG_SHA256" ]; then
      (cd "$RELEASE_ROOT" && shasum -a 256 "$(basename "$standard")" > SHA256SUMS.txt)
      echo "♻️ reusing GitHub-verified release artifact in $RELEASE_ROOT"
      return
    fi
  fi

  rm -rf "$RELEASE_ROOT"
  mkdir -p "$RELEASE_ROOT"
  gh release download "v$VERSION" --repo companyjupiter/madi \
    --pattern "$GITHUB_DMG_NAME" --output "$standard"
  echo "$GITHUB_DMG_SHA256  $standard" | shasum -a 256 -c -
  (cd "$RELEASE_ROOT" && shasum -a 256 "$(basename "$standard")" > SHA256SUMS.txt)
  echo "✅ existing GitHub Release asset prepared as $(basename "$standard")"
}

run_preflight

if [ "$RUN_TESTS" = 1 ]; then
  run_release_gates
fi

if [ "$MODE" = publish ]; then
  prepare_existing_release_artifact
elif can_reuse_artifacts; then
  echo "♻️ reusing verified release artifacts in $RELEASE_ROOT"
else
  rm -rf "$RELEASE_ROOT"
  mkdir -p "$RELEASE_ROOT"

  refresh_release_assets
  "$HERE/build_engine.sh"

  STANDARD_ENV=(
    STRICT_ASSETS=1
    MADI_VERSION="$VERSION"
    MADI_BUILD="$BUILD_NUMBER"
    MADI_CHANNEL="$CHANNEL"
  )
  [ "$CHANNEL" = stable ] || STANDARD_ENV+=(MADI_BETA_EXPIRY="$BETA_EXPIRY")

  build_dmg "$RELEASE_ROOT/standard" "$VERSION" "madi-$VERSION-arm64.dmg" "${STANDARD_ENV[@]}"

  if [ "$INCLUDE_OFFLINE" = 1 ]; then
    OFFLINE_ENV=(
      BUNDLE_MODEL=1
      STRICT_ASSETS=1
      MADI_VERSION="$VERSION"
      MADI_BUILD="$BUILD_NUMBER"
      MADI_CHANNEL="$CHANNEL"
    )
    [ "$CHANNEL" = stable ] || OFFLINE_ENV+=(MADI_BETA_EXPIRY="$BETA_EXPIRY")

    ensure_offline_model
    build_dmg "$RELEASE_ROOT/offline" "$VERSION-offline" "madi-$VERSION-offline-arm64.dmg" "${OFFLINE_ENV[@]}"
  fi

  (cd "$RELEASE_ROOT" && shasum -a 256 ./*.dmg > SHA256SUMS.txt)
fi

if [ "$MODE" != build ]; then
  upload_release
fi
if [ "$MODE" = publish ]; then
  publish_github_release
fi

echo "✅ release artifacts ready in $RELEASE_ROOT"
