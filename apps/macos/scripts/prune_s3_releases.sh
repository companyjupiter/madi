#!/usr/bin/env bash
# Retire published Madi releases. Keeps <keep-version> (which must be the current
# stable) plus every version a channel pointer still names, rewrites
# releases/index.json to that set FIRST, then deletes the other versioned
# objects, then invalidates their CDN paths so retired DMGs stop being served.
# apply=false previews: same listing, same rewrite on disk, nothing uploaded or
# deleted.
set -euo pipefail

WORK="${1:?usage: prune_s3_releases.sh <work-dir> <bucket> <base-url> <prefix> <keep-version> <apply:true|false>}"
BUCKET="${2:?missing bucket}"
BASE_URL="${3:?missing public download base URL}"
PREFIX="${4:-madi}"
KEEP_VERSION="${5:?missing keep version}"
APPLY="${6:-false}"

command -v aws >/dev/null || { echo "❌ aws CLI is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "❌ jq is required" >&2; exit 1; }
BASE_URL="${BASE_URL%/}"
PREFIX="${PREFIX#/}"; PREFIX="${PREFIX%/}"
INDEX_KEY="$PREFIX/releases/index.json"
RELEASES_PREFIX="$PREFIX/releases/"
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

[[ "$KEEP_VERSION" =~ $SEMVER_RE ]] || { echo "❌ keep version must be full SemVer without leading v" >&2; exit 1; }
case "$APPLY" in true|false) ;; *) echo "❌ apply must be true or false (got: $APPLY)" >&2; exit 1 ;; esac

mkdir -p "$WORK"
CURRENT="$WORK/release-index.before.json"
NEXT="$WORK/release-index.after.json"
LISTING="$WORK/release-prefixes.json"

# 1. The live index says what is published, and it must already point at the
#    keeper: pruning never runs ahead of a publish.
aws s3 cp "s3://$BUCKET/$INDEX_KEY" "$CURRENT" --only-show-errors
jq -e 'type == "object" and (.channels | type == "object") and (.releases | type == "array")' "$CURRENT" >/dev/null \
  || { echo "❌ existing release index is invalid" >&2; exit 1; }
STABLE="$(jq -r '.channels.stable // empty' "$CURRENT")"
[ "$STABLE" = "$KEEP_VERSION" ] \
  || { echo "❌ refusing to prune: channels.stable is '${STABLE:-unset}', not $KEEP_VERSION — publish it first" >&2; exit 1; }
jq -e --arg v "$KEEP_VERSION" 'any(.releases[]; .version == $v and .platform == "macos-arm64")' "$CURRENT" >/dev/null \
  || { echo "❌ refusing to prune: $KEEP_VERSION has no macos-arm64 entry in the release index" >&2; exit 1; }
# Every channel pointer (stable, beta, rc) stays published.
KEEP_JSON="$(jq -c --arg v "$KEEP_VERSION" '([$v] + [.channels[] | strings]) | unique' "$CURRENT")"

# 2. What the bucket actually holds: one common prefix per version directory,
#    including orphans that never made it into the index.
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$RELEASES_PREFIX" --delimiter / \
  --query 'CommonPrefixes[].Prefix' --output json > "$LISTING"
CANDIDATES_JSON="$(jq -c --arg root "$RELEASES_PREFIX" '
  (. // [])
  | map(select(type == "string" and startswith($root)) | .[($root | length):] | rtrimstr("/"))
  | map(select(. != ""))
  | unique
' "$LISTING")"
# Only SemVer directories are ever deleted; anything else is reported, not touched.
DELETE_JSON="$(jq -c --argjson keep "$KEEP_JSON" --arg re "$SEMVER_RE" \
  '[.[] | select((IN($keep[]) | not) and test($re))]' <<<"$CANDIDATES_JSON")"
SKIPPED_JSON="$(jq -c --argjson keep "$KEEP_JSON" --arg re "$SEMVER_RE" \
  '[.[] | select((IN($keep[]) | not) and (test($re) | not))]' <<<"$CANDIDATES_JSON")"
DELETE_COUNT="$(jq 'length' <<<"$DELETE_JSON")"

# 3. The index is rewritten before any object disappears: nothing published may
#    point at a deleted key, even while the deletes are still running.
jq --argjson keep "$KEEP_JSON" '
  .releases = [.releases[] | select(.version | IN($keep[]))]
  | . as $index
  | if any(.releases[]; .version == $index.channels.stable and .platform == "macos-arm64") then .
    else error("stable channel must reference a macos-arm64 release") end
' "$CURRENT" > "$NEXT"
BEFORE_COUNT="$(jq '.releases | length' "$CURRENT")"
AFTER_COUNT="$(jq '.releases | length' "$NEXT")"

# 4. Versioned objects are served immutable (max-age one year), so a delete
#    alone leaves cached DMGs downloadable at the edge. Their keys are listed
#    BEFORE deletion and invalidated as exact paths: wildcard invalidations are
#    capped at 15 in progress per distribution (one prune of 16 versions already
#    exceeds that), exact paths at 3000.
KEYS_FILE="$WORK/deleted-keys.json"
: > "$WORK/deleted-keys.txt"
while IFS= read -r version; do
  [ -n "$version" ] || continue
  aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$RELEASES_PREFIX$version/" \
    --query 'Contents[].Key' --output json \
    | jq -r '(. // [])[] | strings' >> "$WORK/deleted-keys.txt"
done < <(jq -r '.[]' <<<"$DELETE_JSON")
jq -R -s 'split("\n") | map(select(. != "")) | unique' "$WORK/deleted-keys.txt" > "$KEYS_FILE"
rm -f "$WORK/deleted-keys.txt"
DELETED_OBJECTS="$(jq 'length' "$KEYS_FILE")"

DISTRIBUTION_ID="${MADI_CLOUDFRONT_DISTRIBUTION_ID:-}"
CDN_NOTE=""
if [ -z "$DISTRIBUTION_ID" ]; then
  host="${BASE_URL#*://}"; host="${host%%/*}"
  DISTRIBUTION_ID="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '$host')].Id | [0]" \
    --output text 2>/dev/null || true)"
  case "$DISTRIBUTION_ID" in
    None|"")
      DISTRIBUTION_ID=""
      CDN_NOTE="no CloudFront distribution with alias $host (set MADI_CLOUDFRONT_DISTRIBUTION_ID); retired DMGs may stay cached at the edge"
      ;;
  esac
fi

INVALIDATION_IDS_JSON='[]'
submit_invalidation() {
  local id
  if id="$(aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" \
      --paths "$@" --query Invalidation.Id --output text 2>"$WORK/cdn-invalidation-error.txt")"; then
    rm -f "$WORK/cdn-invalidation-error.txt"
    INVALIDATION_IDS_JSON="$(jq -c --arg id "$id" '. + [$id]' <<<"$INVALIDATION_IDS_JSON")"
    echo "  CloudFront invalidation $id on $DISTRIBUTION_ID ($# paths)" >&2
    return 0
  fi
  CDN_NOTE="create-invalidation failed on $DISTRIBUTION_ID: $(tr '\n' ' ' < "$WORK/cdn-invalidation-error.txt")"
  echo "  ⚠ $CDN_NOTE" >&2
  return 1
}

if [ "$APPLY" = true ]; then
  aws s3 cp "$NEXT" "s3://$BUCKET/$INDEX_KEY" --content-type application/json \
    --cache-control 'no-cache, no-store, must-revalidate' --only-show-errors
  echo "  rewrote $INDEX_KEY: $BEFORE_COUNT -> $AFTER_COUNT releases" >&2
  while IFS= read -r version; do
    [ -n "$version" ] || continue
    aws s3 rm "s3://$BUCKET/$RELEASES_PREFIX$version/" --recursive --only-show-errors
    echo "  deleted $RELEASES_PREFIX$version/" >&2
  done < <(jq -r '.[]' <<<"$DELETE_JSON")
  if [ -n "$DISTRIBUTION_ID" ] && [ "$DELETED_OBJECTS" -gt 0 ]; then
    paths=()
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      paths+=("$path")
      if [ "${#paths[@]}" -ge 3000 ]; then
        submit_invalidation "${paths[@]}" || break
        paths=()
      fi
    done < <(jq -r --arg prefix "$PREFIX/" '.[] | "/" + ltrimstr($prefix)' "$KEYS_FILE")
    if [ "${#paths[@]}" -gt 0 ] && [ -z "$CDN_NOTE" ]; then
      submit_invalidation "${paths[@]}" || true
    fi
  fi
fi

jq -n \
  --argjson applied "$APPLY" \
  --arg keep_version "$KEEP_VERSION" \
  --argjson kept "$KEEP_JSON" \
  --argjson deleted "$DELETE_JSON" \
  --argjson deleted_objects "$DELETED_OBJECTS" \
  --argjson skipped "$SKIPPED_JSON" \
  --arg index_key "$INDEX_KEY" \
  --arg index_url "$BASE_URL/releases/index.json" \
  --argjson before "$BEFORE_COUNT" \
  --argjson after "$AFTER_COUNT" \
  --arg before_file "$CURRENT" \
  --arg after_file "$NEXT" \
  --arg keys_file "$KEYS_FILE" \
  --arg distribution "$DISTRIBUTION_ID" \
  --argjson invalidations "$INVALIDATION_IDS_JSON" \
  --arg cdn_note "$CDN_NOTE" \
  '
    {
      schema: 1,
      applied: $applied,
      keepVersion: $keep_version,
      kept: $kept,
      deleted: $deleted,
      deletedObjects: $deleted_objects,
      deletedKeysFile: $keys_file,
      skipped: $skipped,
      index: {
        key: $index_key,
        url: $index_url,
        releasesBefore: $before,
        releasesAfter: $after,
        beforeFile: $before_file,
        afterFile: $after_file
      },
      cdn: {
        distributionId: (if $distribution == "" then null else $distribution end),
        invalidationId: ($invalidations[0] // null),
        invalidationIds: $invalidations,
        note: (if $cdn_note == "" then null else $cdn_note end)
      }
    }
  '

if [ "$APPLY" = true ]; then
  echo "✅ pruned $DELETE_COUNT retired version(s), $DELETED_OBJECTS object(s); $INDEX_KEY now lists $AFTER_COUNT release(s)" >&2
else
  echo "ℹ️  dry run: $DELETE_COUNT version(s), $DELETED_OBJECTS object(s) would be deleted; nothing changed" >&2
fi
