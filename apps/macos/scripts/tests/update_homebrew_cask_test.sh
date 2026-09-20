#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SCRIPT="$ROOT/apps/macos/scripts/update_homebrew_cask.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/madi.rb" <<'RUBY'
cask "madi" do
  version "0.4.1"
  sha256 "e8b70fe9830de5e0fa7bde702731d56382f8ab85d9dca03b05336cf3f25280d0"
  url "https://github.com/companyjupiter/madi/releases/download/v#{version}/madi-#{version}-arm64.dmg"
end
RUBY

sha="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
"$SCRIPT" "$WORK/madi.rb" 1.2.3 "$sha"
grep -Fxq '  version "1.2.3"' "$WORK/madi.rb"
grep -Fxq "  sha256 \"$sha\"" "$WORK/madi.rb"
grep -Fq 'releases/download/v#{version}' "$WORK/madi.rb"

! "$SCRIPT" "$WORK/madi.rb" 1.2.3-beta.1 "$sha" 2>/dev/null
! "$SCRIPT" "$WORK/madi.rb" 1.2.4 invalid 2>/dev/null

printf 'update_homebrew_cask tests passed\n'
