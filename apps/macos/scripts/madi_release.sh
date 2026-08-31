#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: madi_release.sh <plan|build|upload|publish|promote-github> <version> [--offline] [--skip-tests] [--beta-expiry YYYY-MM-DD] [--json]

Subcommands:
  plan            show resolved release configuration with no side effects
  build           build or reuse local DMG artifacts only
  upload          build or reuse local DMG artifacts and upload immutable versioned objects to S3
  publish         build or reuse local DMG artifacts, upload them to S3, and advance channel/index metadata
  promote-github  legacy flow: reuse the existing GitHub Release DMG asset, publish it to S3, and undraft the GitHub Release

Common options:
  --offline            include the offline DMG in local/build/upload/publish flows
  --skip-tests         skip release gates
  --beta-expiry        override beta/rc expiry date (YYYY-MM-DD)
  --json               write only one JSON object to stdout; all logs go to stderr
  --require-notarized  fail build/upload/publish unless Developer ID signing +
                       notarization credentials are available

Signing (resolved automatically; see plan output's "signing"):
  MADI_SIGNING=auto|adhoc|developer-id   (default auto)
    auto          Developer ID sign + notarize + staple when both a
                  "Developer ID Application" identity (SIGN_ID or the sole one
                  in the keychain) AND notary credentials (NOTARY_PROFILE, the
                  NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER triplet, or
                  APPLE_ID/TEAM_ID/APP_PW) are present; otherwise ad-hoc.
    adhoc         force the ad-hoc path even when credentials exist
    developer-id  fail instead of silently falling back to ad-hoc
EOF
}

log() {
  echo "$*" >&2
}

die() {
  log "❌ $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

validate_date() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

json_bool() {
  if [ "$1" = 1 ] || [ "$1" = true ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

emit_json_payload() {
  printf '%s\n' "$1"
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DEFAULT_BETA_EXPIRY="2026-12-01"
DEFAULT_ASSETS_URL="https://madi.devart.tv/runtime-assets/v1/madi-runtime-assets-v1.tar.gz"
DEFAULT_ASSETS_SHA256="f6dc4bb3d3402aaf95a36ce7c1a86d6fd7483a320c6312004d83133d1cf017e5"
DEFAULT_RELEASE_BUCKET="devart-teamjupiter-downloads-artdapne2"
DEFAULT_RELEASE_PREFIX="madi"
DEFAULT_DOWNLOAD_BASE_URL="https://madi.devart.tv"
SPEECH_MODEL_URL="https://huggingface.co/jupitersong/madi-whisper-turbo-v3-q8/resolve/main/model.q8.safetensors"
SPEECH_MODEL_SHA256="1014fd3ad4450a2e43e473eebbab485b165fd68cbe932372071d86c522bb5c8e"

COMMAND="${1:-}"
case "$COMMAND" in
  ""|-h|--help)
    usage
    exit 0
    ;;
  plan|build|upload|publish|promote-github) ;;
  *)
    die "unknown subcommand: $COMMAND"
    ;;
esac
shift

VERSION="${1:-}"
[ -n "$VERSION" ] || die "version is required"
shift

INCLUDE_OFFLINE=0
RUN_TESTS=1
JSON_MODE=0
BETA_EXPIRY=""
REQUIRE_NOTARIZED=0
SIGNING_MODE=""
SIGNING_REASON=""

while [ "$#" -gt 0 ]; do
  case "$1" in
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
    --json)
      JSON_MODE=1
      ;;
    --require-notarized)
      REQUIRE_NOTARIZED=1
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
RELEASE_BUCKET="${MADI_RELEASE_BUCKET:-$DEFAULT_RELEASE_BUCKET}"
RELEASE_PREFIX="${MADI_RELEASE_PREFIX:-$DEFAULT_RELEASE_PREFIX}"
DOWNLOAD_BASE_URL="${MADI_DOWNLOAD_BASE_URL:-$DEFAULT_DOWNLOAD_BASE_URL}"
GIT_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=0
if git -C "$ROOT" status --porcelain >/tmp/madi_release_git_status.$$ 2>/dev/null; then
  if [ -s "/tmp/madi_release_git_status.$$" ]; then
    GIT_DIRTY=1
  fi
fi
rm -f "/tmp/madi_release_git_status.$$"

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

TMP_ASSET_ARCHIVE=""
GITHUB_DMG_NAME=""
GITHUB_DMG_SHA256=""
GITHUB_TAG="v$VERSION"

cleanup() {
  if [ -n "$TMP_ASSET_ARCHIVE" ] && [ -f "$TMP_ASSET_ARCHIVE" ]; then
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

  if ! git -C "$ROOT" ls-files --error-unmatch "apps/macos/scripts/madi_release.sh" >/dev/null 2>&1; then
    bash -n "$HERE/madi_release.sh"
  fi
  if ! git -C "$ROOT" ls-files --error-unmatch "apps/macos/scripts/release_local_free.sh" >/dev/null 2>&1; then
    bash -n "$HERE/release_local_free.sh"
  fi

  "$HERE/tests/publish_s3_release_test.sh" >&2
  "$HERE/tests/madi_release_test.sh" >&2
  (cd "$ROOT/apps/macos" && swift test) >&2
}

# Decide developer-id vs ad-hoc signing for THIS invocation. Auto-detection is
# deliberate: the same command notarizes on a machine with credentials and
# still works (loudly ad-hoc) on one without, and the manifest records which.
resolve_signing() {
  local requested="${MADI_SIGNING:-auto}"
  case "$requested" in
    adhoc)
      SIGNING_MODE=adhoc
      SIGNING_REASON="forced by MADI_SIGNING=adhoc"
      return 0
      ;;
    auto|developer-id) ;;
    *) die "MADI_SIGNING must be auto, adhoc, or developer-id (got: $requested)" ;;
  esac

  local identity="${SIGN_ID:-}"
  if [ -z "$identity" ]; then
    local ids count
    ids="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | sort -u)"
    count="$(printf '%s\n' "$ids" | awk 'NF { c++ } END { print c + 0 }')"
    if [ "$count" -eq 1 ]; then
      identity="$ids"
    elif [ "$count" -gt 1 ]; then
      SIGNING_REASON="multiple Developer ID Application identities in the keychain — set SIGN_ID"
    fi
  fi

  local notary_ok=0
  if [ -n "${NOTARY_PROFILE:-}" ] \
    || { [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; } \
    || { [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APP_PW:-}" ]; }; then
    notary_ok=1
  fi

  if [ -n "$identity" ] && [ "$notary_ok" = 1 ]; then
    SIGNING_MODE=developer-id
    SIGNING_REASON=""
    SIGN_ID="$identity"
    export SIGN_ID
  else
    SIGNING_MODE=adhoc
    if [ -n "$identity" ]; then
      SIGNING_REASON="no notary credentials (set NOTARY_PROFILE, the NOTARY_KEY triplet, or APPLE_ID/TEAM_ID/APP_PW)"
    else
      : "${SIGNING_REASON:=no Developer ID Application identity in the keychain (install the certificate or set SIGN_ID)}"
    fi
  fi

  if [ "$requested" = developer-id ] && [ "$SIGNING_MODE" != developer-id ]; then
    die "MADI_SIGNING=developer-id but signing is unavailable: $SIGNING_REASON"
  fi
}

run_preflight() {
  local asset_count asset_line asset_lines digest

  if [ "$COMMAND" != plan ] && [ "$(uname -m)" != arm64 ]; then
    die "arm64 host required"
  fi

  require_cmd jq
  resolve_signing
  if [ "$REQUIRE_NOTARIZED" = 1 ] && [ "$SIGNING_MODE" != developer-id ]; then
    case "$COMMAND" in
      build|upload|publish)
        die "--require-notarized but signing is unavailable: $SIGNING_REASON"
        ;;
      *) : ;;
    esac
  fi
  case "$COMMAND" in
    upload|publish|promote-github)
      require_cmd aws
      aws sts get-caller-identity >/dev/null
      ;;
    *)
      :
      ;;
  esac

  if [ "$COMMAND" = "promote-github" ]; then
    [ "$INCLUDE_OFFLINE" = 0 ] || die "--offline cannot be combined with promote-github"
    require_cmd gh
    gh auth status --hostname github.com >/dev/null 2>&1
    gh release view "$GITHUB_TAG" --repo companyjupiter/madi >/dev/null 2>&1 \
      || die "GitHub Release $GITHUB_TAG must already exist before promote-github"
    asset_lines="$(gh release view "$GITHUB_TAG" --repo companyjupiter/madi --json assets \
      --jq '.assets[] | select((.name | ascii_downcase | endswith(".dmg")) and ((.name | ascii_downcase | contains("offline")) | not)) | [.name, .digest] | @tsv')"
    asset_count="$(printf '%s\n' "$asset_lines" | awk 'NF { count++ } END { print count + 0 }')"
    [ "$asset_count" -eq 1 ] \
      || die "GitHub Release $GITHUB_TAG must contain exactly one standard DMG asset (found $asset_count)"
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
  curl --fail --location --retry 3 "$ASSETS_URL" --output "$TMP_ASSET_ARCHIVE" >&2
  "$HERE/prepare_release_assets.sh" "$TMP_ASSET_ARCHIVE" "$ASSETS_SHA256" >&2
}

# Developer ID path for the DMG itself: sign, notarize, staple. The app inside
# is already notarized+stapled (sign_notarize.sh), so this second submission is
# quick and gives the DMG its own ticket — no first-open Gatekeeper lag.
sign_and_staple_dmg() {
  local dmg="$1"
  codesign --force --timestamp --sign "$SIGN_ID" "$dmg" >&2
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait >&2
  elif [ -n "${NOTARY_KEY:-}" ]; then
    xcrun notarytool submit "$dmg" --key "$NOTARY_KEY" \
      --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait >&2
  else
    xcrun notarytool submit "$dmg" \
      --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW" --wait >&2
  fi
  xcrun stapler staple "$dmg" >&2
}

build_dmg() {
  local build_dir="$1" dmg_version="$2" final_name="$3"
  shift 3
  mkdir -p "$build_dir"
  env "$@" "$HERE/make_app.sh" "$build_dir" >&2
  "$HERE/verify_release_bundle.sh" "$build_dir/Madi.app" "$VERSION" >&2
  if [ "$SIGNING_MODE" = developer-id ]; then
    "$HERE/sign_notarize.sh" "$build_dir/Madi.app" >&2
  else
    log "⚠️  signing: ad-hoc — $SIGNING_REASON (Gatekeeper will warn users)"
  fi
  (
    cd "$RELEASE_ROOT"
    # make_dmg's own staple stays skipped in BOTH modes: at that point the DMG
    # is never notarized yet. The developer-id path staples it right after.
    SKIP_STAPLE=1 "$HERE/make_dmg.sh" "$build_dir/Madi.app" "$dmg_version" >&2
  )
  mv "$RELEASE_ROOT/Madi-$dmg_version.dmg" "$RELEASE_ROOT/$final_name"
  if [ "$SIGNING_MODE" = developer-id ]; then
    sign_and_staple_dmg "$RELEASE_ROOT/$final_name"
  fi
}

ensure_offline_model() {
  local model="$ROOT/engine/metal/bench/runs/model.q8.safetensors"

  if [ ! -f "$model" ]; then
    require_cmd curl
    mkdir -p "$(dirname "$model")"
    curl --fail --location --retry 3 "$SPEECH_MODEL_URL" --output "$model" >&2
  fi
  echo "$SPEECH_MODEL_SHA256  $model" | shasum -a 256 -c - >&2
}

rewrite_checksums() {
  local dmgs=()
  shopt -s nullglob
  dmgs=("$RELEASE_ROOT"/*.dmg)
  shopt -u nullglob

  if [ "${#dmgs[@]}" -eq 0 ]; then
    rm -f "$RELEASE_ROOT/SHA256SUMS.txt"
    return 0
  fi

  (
    cd "$RELEASE_ROOT"
    shasum -a 256 ./*.dmg > SHA256SUMS.txt
  )
}

prune_unrequested_artifacts() {
  local path name
  shopt -s nullglob
  for path in "$RELEASE_ROOT"/*.dmg; do
    name="$(basename "$path")"
    case "$name" in
      "madi-$VERSION-arm64.dmg") ;;
      "madi-$VERSION-offline-arm64.dmg")
        [ "$INCLUDE_OFFLINE" = 1 ] || rm -f "$path"
        ;;
      *) rm -f "$path" ;;
    esac
  done
  shopt -u nullglob
  rewrite_checksums
}

can_reuse_artifacts() {
  [ "$GIT_DIRTY" = 0 ] || return 1
  [ -f "$RELEASE_ROOT/madi-$VERSION-arm64.dmg" ] || return 1
  [ -f "$RELEASE_ROOT/SHA256SUMS.txt" ] || return 1
  [ -f "$RELEASE_ROOT/manifest.json" ] || return 1
  if [ "$INCLUDE_OFFLINE" = 1 ]; then
    [ -f "$RELEASE_ROOT/madi-$VERSION-offline-arm64.dmg" ] || return 1
  fi
  jq -e \
    --arg version "$VERSION" \
    --arg git_sha "$GIT_SHA" \
    --arg channel "$CHANNEL" \
    --arg build_number "$BUILD_NUMBER" \
    --arg assets_url "$ASSETS_URL" \
    --arg assets_sha256 "$ASSETS_SHA256" \
    --arg beta_expiry "$BETA_EXPIRY" \
    --arg signing "$SIGNING_MODE" \
    --argjson include_offline "$(json_bool "$INCLUDE_OFFLINE")" \
    '
      .version == $version
      and .gitSha == $git_sha
      and .gitDirty == false
      and .source == "local-build"
      and .channel == $channel
      and .buildNumber == $build_number
      and .assetsUrl == $assets_url
      and .assetsSha256 == $assets_sha256
      and .betaExpiry == $beta_expiry
      and .includeOffline == $include_offline
      and .signing == $signing
      and any(.artifacts[]?; .name == ("madi-" + $version + "-arm64.dmg"))
      and (if $include_offline then any(.artifacts[]?; .name == ("madi-" + $version + "-offline-arm64.dmg")) else true end)
    ' "$RELEASE_ROOT/manifest.json" >/dev/null || return 1
  (cd "$RELEASE_ROOT" && shasum -a 256 -c SHA256SUMS.txt >/dev/null 2>&1)
}

prepare_existing_release_artifact() {
  local standard="$RELEASE_ROOT/madi-$VERSION-arm64.dmg"
  local actual

  if [ -f "$standard" ]; then
    actual="$(shasum -a 256 "$standard" | awk '{print $1}')"
    if [ "$actual" = "$GITHUB_DMG_SHA256" ]; then
      (
        cd "$RELEASE_ROOT"
        shasum -a 256 "$(basename "$standard")" > SHA256SUMS.txt
      )
      log "♻️ reusing GitHub-verified release artifact in $RELEASE_ROOT"
      return
    fi
  fi

  rm -rf "$RELEASE_ROOT"
  mkdir -p "$RELEASE_ROOT"
  gh release download "$GITHUB_TAG" --repo companyjupiter/madi \
    --pattern "$GITHUB_DMG_NAME" --output "$standard" >&2
  echo "$GITHUB_DMG_SHA256  $standard" | shasum -a 256 -c - >&2
  (
    cd "$RELEASE_ROOT"
    shasum -a 256 "$(basename "$standard")" > SHA256SUMS.txt
  )
  log "✅ existing GitHub Release asset prepared as $(basename "$standard")"
}

build_local_release() {
  local standard_env=() offline_env=()

  if can_reuse_artifacts; then
    prune_unrequested_artifacts
    log "♻️ reusing verified release artifacts in $RELEASE_ROOT"
    save_manifest "built" "local-build" false
    return
  fi

  rm -rf "$RELEASE_ROOT"
  mkdir -p "$RELEASE_ROOT"

  refresh_release_assets
  "$HERE/build_engine.sh" >&2

  standard_env=(
    STRICT_ASSETS=1
    MADI_VERSION="$VERSION"
    MADI_BUILD="$BUILD_NUMBER"
    MADI_CHANNEL="$CHANNEL"
  )
  [ "$CHANNEL" = stable ] || standard_env+=(MADI_BETA_EXPIRY="$BETA_EXPIRY")

  build_dmg "$RELEASE_ROOT/standard" "$VERSION" "madi-$VERSION-arm64.dmg" "${standard_env[@]}"

  if [ "$INCLUDE_OFFLINE" = 1 ]; then
    offline_env=(
      BUNDLE_MODEL=1
      STRICT_ASSETS=1
      MADI_VERSION="$VERSION"
      MADI_BUILD="$BUILD_NUMBER"
      MADI_CHANNEL="$CHANNEL"
    )
    [ "$CHANNEL" = stable ] || offline_env+=(MADI_BETA_EXPIRY="$BETA_EXPIRY")

    ensure_offline_model
    build_dmg "$RELEASE_ROOT/offline" "$VERSION-offline" "madi-$VERSION-offline-arm64.dmg" "${offline_env[@]}"
  fi

  rewrite_checksums
  save_manifest "built" "local-build" false
}

upload_release() {
  local publish_flag="$1"
  prune_unrequested_artifacts
  MADI_BUILD="$BUILD_NUMBER" "$HERE/publish_s3_release.sh" "$RELEASE_ROOT" "$RELEASE_BUCKET" "$DOWNLOAD_BASE_URL" "$RELEASE_PREFIX" \
    "$VERSION" "$CHANNEL" "$publish_flag" >&2
}

publish_github_release_notes() {
  local notes="$RELEASE_ROOT/github-release-notes.md"

  gh release view "$GITHUB_TAG" --repo companyjupiter/madi >/dev/null 2>&1 \
    || die "GitHub Release $GITHUB_TAG must already exist before promote-github"
  gh release view "$GITHUB_TAG" --repo companyjupiter/madi --json assets \
    --jq '.assets[].name' | grep -Eqi '\.dmg$' \
    || die "GitHub Release $GITHUB_TAG has no DMG asset for the current in-app updater"

  gh release view "$GITHUB_TAG" --repo companyjupiter/madi --json body --jq .body > "$notes"
  if ! grep -Fq "madi-$VERSION-arm64.dmg" "$notes"; then
    printf '\n\n' >> "$notes"
    command cat "$RELEASE_ROOT/release-notes.md" >> "$notes"
  fi
  gh release edit "$GITHUB_TAG" --repo companyjupiter/madi \
    --notes-file "$notes" --draft=false >&2
}

build_artifacts_json() {
  local standard_path="$RELEASE_ROOT/madi-$VERSION-arm64.dmg"
  local offline_path="$RELEASE_ROOT/madi-$VERSION-offline-arm64.dmg"
  local standard_name="" standard_sha="" standard_size=0 standard_url=""
  local offline_name="" offline_sha="" offline_size=0 offline_url=""

  if [ -f "$standard_path" ]; then
    standard_name="$(basename "$standard_path")"
    standard_sha="$(shasum -a 256 "$standard_path" | awk '{print $1}')"
    standard_size="$(wc -c < "$standard_path" | tr -d '[:space:]')"
    standard_url="${DOWNLOAD_BASE_URL%/}/releases/$VERSION/$standard_name"
  fi

  if [ "$INCLUDE_OFFLINE" = 1 ] && [ -f "$offline_path" ]; then
    offline_name="$(basename "$offline_path")"
    offline_sha="$(shasum -a 256 "$offline_path" | awk '{print $1}')"
    offline_size="$(wc -c < "$offline_path" | tr -d '[:space:]')"
    offline_url="${DOWNLOAD_BASE_URL%/}/releases/$VERSION/$offline_name"
  fi

  jq -n \
    --arg standard_name "$standard_name" \
    --arg standard_path "$standard_path" \
    --arg standard_sha "$standard_sha" \
    --argjson standard_size "${standard_size:-0}" \
    --arg standard_url "$standard_url" \
    --arg offline_name "$offline_name" \
    --arg offline_path "$offline_path" \
    --arg offline_sha "$offline_sha" \
    --argjson offline_size "${offline_size:-0}" \
    --arg offline_url "$offline_url" \
    '
      def artifact($name; $path; $sha; $size; $url):
        {name:$name, path:$path, sha256:$sha, size:$size, url:$url};
      (if $standard_name != "" then [artifact($standard_name; $standard_path; $standard_sha; $standard_size; $standard_url)] else [] end)
      + (if $offline_name != "" then [artifact($offline_name; $offline_path; $offline_sha; $offline_size; $offline_url)] else [] end)
    '
}

save_manifest() {
  local status="$1" source="$2" published="$3"
  local manifest="$RELEASE_ROOT/manifest.json"
  local release_json="$RELEASE_ROOT/release.json"
  local checksums="$RELEASE_ROOT/SHA256SUMS.txt"
  local release_notes="$RELEASE_ROOT/release-notes.md"
  local feed_url="${DOWNLOAD_BASE_URL%/}/channels/$CHANNEL/latest.json"
  local index_url="${DOWNLOAD_BASE_URL%/}/releases/index.json"
  local artifacts_json

  mkdir -p "$RELEASE_ROOT"
  artifacts_json="$(build_artifacts_json)"

  jq -n \
    --arg status "$status" \
    --arg command "$COMMAND" \
    --arg source "$source" \
    --arg version "$VERSION" \
    --arg tag "$GITHUB_TAG" \
    --arg git_sha "$GIT_SHA" \
    --arg channel "$CHANNEL" \
    --arg build_number "$BUILD_NUMBER" \
    --arg release_root "$RELEASE_ROOT" \
    --arg bucket "$RELEASE_BUCKET" \
    --arg prefix "$RELEASE_PREFIX" \
    --arg base_url "${DOWNLOAD_BASE_URL%/}" \
    --arg assets_url "$ASSETS_URL" \
    --arg assets_sha256 "$ASSETS_SHA256" \
    --arg beta_expiry "$BETA_EXPIRY" \
    --arg feed_url "$feed_url" \
    --arg index_url "$index_url" \
    --arg manifest_path "$manifest" \
    --arg release_json "$release_json" \
    --arg checksums "$checksums" \
    --arg release_notes "$release_notes" \
    --arg github_dmg_name "$GITHUB_DMG_NAME" \
    --arg github_dmg_sha256 "$GITHUB_DMG_SHA256" \
    --arg signing "$SIGNING_MODE" \
    --argjson include_offline "$(json_bool "$INCLUDE_OFFLINE")" \
    --argjson git_dirty "$(json_bool "$GIT_DIRTY")" \
    --argjson published "$(json_bool "$published")" \
    --argjson has_release_json "$(json_bool "$( [ -f "$release_json" ] && echo 1 || echo 0 )")" \
    --argjson has_release_notes "$(json_bool "$( [ -f "$release_notes" ] && echo 1 || echo 0 )")" \
    --argjson has_checksums "$(json_bool "$( [ -f "$checksums" ] && echo 1 || echo 0 )")" \
    --argjson artifacts "$artifacts_json" \
    '
      {
        schema: 1,
        status: $status,
        command: $command,
        source: $source,
        version: $version,
        tag: $tag,
        gitSha: $git_sha,
        gitDirty: $git_dirty,
        channel: $channel,
        buildNumber: $build_number,
        includeOffline: $include_offline,
        signing: $signing,
        published: $published,
        releaseRoot: $release_root,
        bucket: $bucket,
        prefix: $prefix,
        baseUrl: $base_url,
        assetsUrl: $assets_url,
        assetsSha256: $assets_sha256,
        betaExpiry: $beta_expiry,
        latestUrl: $feed_url,
        indexUrl: $index_url,
        manifestPath: $manifest_path,
        files: {
          checksums: (if $has_checksums then $checksums else null end),
          releaseJson: (if $has_release_json then $release_json else null end),
          releaseNotes: (if $has_release_notes then $release_notes else null end)
        },
        github: {
          assetName: (if $github_dmg_name == "" then null else $github_dmg_name end),
          assetSha256: (if $github_dmg_sha256 == "" then null else $github_dmg_sha256 end)
        },
        artifacts: $artifacts
      }
    ' > "$manifest"

}

emit_plan_json() {
  local action_build=0 action_upload=0 action_publish=0 action_promote_github=0
  local requires_aws=0 requires_gh=0
  local payload

  case "$COMMAND" in
    build)
      action_build=1
      ;;
    upload)
      action_build=1
      action_upload=1
      requires_aws=1
      ;;
    publish)
      action_build=1
      action_upload=1
      action_publish=1
      requires_aws=1
      ;;
    promote-github)
      action_upload=1
      action_publish=1
      action_promote_github=1
      requires_aws=1
      requires_gh=1
      ;;
    *)
      :
      ;;
  esac

  payload="$(
    jq -n \
    --arg command "$COMMAND" \
    --arg version "$VERSION" \
    --arg tag "$GITHUB_TAG" \
    --arg git_sha "$GIT_SHA" \
    --arg channel "$CHANNEL" \
    --arg build_number "$BUILD_NUMBER" \
    --arg release_root "$RELEASE_ROOT" \
    --arg bucket "$RELEASE_BUCKET" \
    --arg prefix "$RELEASE_PREFIX" \
    --arg base_url "${DOWNLOAD_BASE_URL%/}" \
    --arg assets_url "$ASSETS_URL" \
    --arg assets_sha256 "$ASSETS_SHA256" \
    --arg beta_expiry "$BETA_EXPIRY" \
    --arg standard_dmg "$RELEASE_ROOT/madi-$VERSION-arm64.dmg" \
    --arg offline_dmg "$RELEASE_ROOT/madi-$VERSION-offline-arm64.dmg" \
    --arg latest_url "${DOWNLOAD_BASE_URL%/}/channels/$CHANNEL/latest.json" \
    --arg index_url "${DOWNLOAD_BASE_URL%/}/releases/index.json" \
    --argjson include_offline "$(json_bool "$INCLUDE_OFFLINE")" \
    --argjson git_dirty "$(json_bool "$GIT_DIRTY")" \
    --argjson run_tests "$(json_bool "$RUN_TESTS")" \
    --argjson action_build "$(json_bool "$action_build")" \
    --argjson action_upload "$(json_bool "$action_upload")" \
    --argjson action_publish "$(json_bool "$action_publish")" \
    --argjson action_promote_github "$(json_bool "$action_promote_github")" \
    --argjson requires_aws "$(json_bool "$requires_aws")" \
    --argjson requires_gh "$(json_bool "$requires_gh")" \
    --arg signing_mode "$SIGNING_MODE" \
    --arg signing_reason "$SIGNING_REASON" \
    '
      {
        schema: 1,
        command: $command,
        version: $version,
        tag: $tag,
        gitSha: $git_sha,
        gitDirty: $git_dirty,
        channel: $channel,
        buildNumber: $build_number,
        releaseRoot: $release_root,
        bucket: $bucket,
        prefix: $prefix,
        baseUrl: $base_url,
        assetsUrl: $assets_url,
        assetsSha256: $assets_sha256,
        betaExpiry: $beta_expiry,
        includeOffline: $include_offline,
        runTests: $run_tests,
        latestUrl: $latest_url,
        indexUrl: $index_url,
        plannedArtifacts: {
          standard: $standard_dmg,
          offline: (if $include_offline then $offline_dmg else null end)
        },
        actions: {
          build: $action_build,
          upload: $action_upload,
          publishMetadata: $action_publish,
          promoteGithubRelease: $action_promote_github
        },
        signing: {
          mode: $signing_mode,
          reason: (if $signing_reason == "" then null else $signing_reason end)
        },
        requirements: {
          aws: $requires_aws,
          gh: $requires_gh,
          arm64Host: ($command != "plan"),
          jq: true
        }
      }
    '
  )"

  emit_json_payload "$payload"
}

run_preflight

if [ "$COMMAND" = plan ]; then
  emit_plan_json
  exit 0
fi

if [ "$RUN_TESTS" = 1 ]; then
  run_release_gates
fi

case "$COMMAND" in
  build)
    build_local_release
    ;;
  upload)
    build_local_release
    upload_release false
    save_manifest "uploaded" "local-build" false
    ;;
  publish)
    build_local_release
    upload_release true
    save_manifest "published" "local-build" true
    ;;
  promote-github)
    prepare_existing_release_artifact
    upload_release true
    publish_github_release_notes
    save_manifest "published" "github-release" true
    ;;
esac

if [ "$JSON_MODE" = 1 ]; then
  cat "$RELEASE_ROOT/manifest.json"
fi

log "✅ release artifacts ready in $RELEASE_ROOT"
