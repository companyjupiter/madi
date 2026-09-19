#!/usr/bin/env bash
# update_translate_engines.sh — refresh engine/prebuilt/ from a sovereignLLM checkout.
#
# The DNA3 translate engines are built in the private sovereignLLM project; Madi
# commits the two small release binaries so a clean clone builds a
# translation-capable app. Run this after rebuilding the engines, review the diff
# of MANIFEST.json, and commit binaries + SHA256SUMS + MANIFEST.json together.
#
# Usage: update_translate_engines.sh [path-to-sovereignLLM]   (default ../sovereignLLM)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="${1:-$ROOT/../sovereignLLM}"
DEST="$ROOT/engine/prebuilt"
MINIMUM_OS="${MADI_MINIMUM_OS:-14.0}"

die() { echo "❌ $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required"
[ -d "$SRC" ] || die "sovereignLLM checkout not found: $SRC"
SRC="$(cd "$SRC" && pwd)"

# name | path inside sovereignLLM | model it runs | engine source dir
ENGINES=(
  "translate-engine-4b|out/metal-dna3-4b-q4km/sovereign-metal-dna3-4b-q4km|DNA3.0-4B i1-Q4_K_M|apps/metal-dna3-4b-q4km"
  "translate-engine-2b|out/metal-dna3-2b-q4km/sovereign-metal-dna3-2b-q4km|DNA3.0-2B i1-Q4_K_M|apps/metal-dna3-2b-q4km"
)

mkdir -p "$DEST"
entries='[]'
for row in "${ENGINES[@]}"; do
  IFS='|' read -r name rel model app_dir <<<"$row"
  bin="$SRC/$rel"
  [ -x "$bin" ] || die "engine binary missing or not executable: $bin"
  file "$bin" | grep -q 'Mach-O 64-bit executable arm64' || die "$name is not an arm64 executable"
  minos="$(xcrun vtool -show-build "$bin" | awk '$1 == "minos" { print $2; exit }')"
  [ "$minos" = "$MINIMUM_OS" ] || die "$name targets macOS $minos, the app declares $MINIMUM_OS"
  # the bundle must stay self-contained: system frameworks and libraries only
  if otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -vE '^(/System/Library/|/usr/lib/)' | grep -q .; then
    die "$name links a non-system library"
  fi
  cp "$bin" "$DEST/$name"
  chmod 755 "$DEST/$name"
  sha="$(shasum -a 256 "$DEST/$name" | awk '{print $1}')"
  size="$(wc -c < "$DEST/$name" | tr -d '[:space:]')"
  uuid="$(otool -l "$DEST/$name" | awk '/LC_UUID/{f=1} f && $1 == "uuid" {print $2; exit}')"
  built_at="$(date -u -r "$(stat -f %m "$bin")" '+%Y-%m-%dT%H:%M:%SZ')"
  source_commit="$(git -C "$SRC" log -1 --format=%H -- "$app_dir" 2>/dev/null || echo unknown)"
  entries="$(jq -c \
    --arg name "$name" --arg model "$model" --arg rel "$rel" --arg sha "$sha" \
    --argjson size "$size" --arg uuid "$uuid" --arg minos "$minos" \
    --arg built_at "$built_at" --arg app_dir "$app_dir" --arg source_commit "$source_commit" \
    '. + [{name: $name, model: $model, arch: "arm64", minos: $minos, sha256: $sha, size: $size,
           uuid: $uuid, builtAt: $built_at, sourcePath: $rel,
           engineSource: {dir: $app_dir, lastCommit: $source_commit}}]' <<<"$entries")"
  echo "  $name  $sha  ($size bytes, built $built_at)"
done

(cd "$DEST" && shasum -a 256 translate-engine-2b translate-engine-4b > SHA256SUMS)

head_commit="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
dirty=false
[ -z "$(git -C "$SRC" status --porcelain 2>/dev/null)" ] || dirty=true
jq -n \
  --arg project "sovereignLLM (private; source not included in this repository)" \
  --arg head "$head_commit" --argjson dirty "$dirty" --argjson engines "$entries" \
  '{schema: 1, source: {project: $project, headCommit: $head, dirty: $dirty}, engines: $engines}' \
  > "$DEST/MANIFEST.json"

[ "$dirty" = false ] || echo "⚠ sovereignLLM has uncommitted changes — MANIFEST.json records dirty=true" >&2
echo "✅ engine/prebuilt refreshed from $SRC ($head_commit)"
