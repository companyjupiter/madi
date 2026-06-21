#!/usr/bin/env bash
# make_dmg.sh — wrap the signed+notarized app into a DMG and staple the DMG.
# Uses create-dmg if available (brew install create-dmg), else hdiutil.
set -euo pipefail
APP="${1:?usage: make_dmg.sh <path/to/Madi.app> [version]}"
VER="${2:-1.0}"
OUT="Madi-$VER.dmg"
VOL="Madi"

rm -f "$OUT"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$VOL" \
    --window-size 540 360 \
    --icon-size 110 \
    --icon "$(basename "$APP")" 150 180 \
    --app-drop-link 390 180 \
    "$OUT" "$APP"
else
  echo "create-dmg not found — using hdiutil (no fancy layout)"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
  rm -rf "$STAGE"
fi

# notarized app inside is enough, but stapling the DMG too avoids first-open lag
xcrun stapler staple "$OUT" || true
echo "✅ DMG → $OUT"
