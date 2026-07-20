#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: release_local_free.sh <version> [--upload|--publish|--publish-local] [--offline] [--skip-tests] [--beta-expiry YYYY-MM-DD] [--json]

Build a local free-account macOS release.
  default          build artifacts only
  --upload         upload immutable versioned objects to S3
  --publish        legacy flow: publish from existing GitHub Release asset and advance channel/index metadata
  --publish-local  build/reuse the local DMG, upload it to S3, and advance channel/index metadata
EOF
}

die() {
  echo "❌ $*" >&2
  exit 1
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/madi_release.sh"

[ -x "$CLI" ] || die "missing release CLI: $CLI"

VERSION="${1:-}"
[ "$VERSION" = "--help" ] || [ "$VERSION" = "-h" ] && { usage; exit 0; }
[ -n "$VERSION" ] || { usage >&2; exit 1; }
shift

MODE="build"
PASSTHRU=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --upload)
      [ "$MODE" = build ] || die "choose only one of --upload, --publish, or --publish-local"
      MODE="upload"
      ;;
    --publish)
      [ "$MODE" = build ] || die "choose only one of --upload, --publish, or --publish-local"
      MODE="promote-github"
      ;;
    --publish-local)
      [ "$MODE" = build ] || die "choose only one of --upload, --publish, or --publish-local"
      MODE="publish"
      ;;
    --offline|--skip-tests|--json)
      PASSTHRU+=("$1")
      ;;
    --beta-expiry)
      shift
      [ "$#" -ge 1 ] || die "--beta-expiry requires YYYY-MM-DD"
      PASSTHRU+=("--beta-expiry" "$1")
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

exec "$CLI" "$MODE" "$VERSION" "${PASSTHRU[@]}"
