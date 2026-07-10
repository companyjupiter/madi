#!/usr/bin/env bash
# sign_notarize.sh — Developer ID sign (inner→outer), notarize, staple.
# Prereqs: Apple Developer Program, a "Developer ID Application" cert in the
# login keychain, and an app-specific password (or a notarytool keychain profile).
#
# Env:
#   SIGN_ID   "Developer ID Application: NAME (TEAMID)"
#   APPLE_ID  your Apple ID email
#   TEAM_ID   10-char team id
#   APP_PW    app-specific password  (or set NOTARY_PROFILE for a stored profile)
set -euo pipefail
APP="${1:?usage: sign_notarize.sh <path/to/Sovereign.app>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENT="$HERE/../Sovereign/Sovereign.entitlements"
: "${SIGN_ID:?set SIGN_ID}"

echo "[1/4] sign embedded executables (inner first)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENT" --sign "$SIGN_ID" "$APP/Contents/MacOS/transcribe"
# metallib lives in Resources/ (make_app.sh) or MacOS/ (assemble_bundle.sh);
# sign whichever exists. In Resources/ the outer bundle signature already seals
# it — signing here is harmless and keeps --strict happy for the MacOS/ layout.
for mlib in "$APP/Contents/Resources/whisper.metallib" "$APP/Contents/MacOS/whisper.metallib"; do
  [ -f "$mlib" ] && codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$mlib"
done

echo "[2/4] sign the app bundle (no --deep; inner already signed)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENT" --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "[3/4] notarize"
ZIP="${APP%.app}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
else
  : "${APPLE_ID:?set APPLE_ID}"; : "${TEAM_ID:?set TEAM_ID}"; : "${APP_PW:?set APP_PW}"
  xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW" --wait
fi
rm -f "$ZIP"

echo "[4/4] staple"
xcrun stapler staple "$APP"
spctl -a -vvv --type exec "$APP" || true
echo "✅ signed + notarized: $APP"
