#!/usr/bin/env bash
# Keep the canonical VERSION file and the runtime fallbacks in lockstep.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

python3 - "$ROOT/VERSION" "$ROOT/apps/macos/Sovereign/Info.plist" \
  "$ROOT/apps/macos/Sovereign/AppInfo/AppVersion.swift" <<'PY'
import pathlib
import plistlib
import re
import sys

version_path, plist_path, swift_path = map(pathlib.Path, sys.argv[1:])
version = version_path.read_text(encoding="utf-8").strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit(f"VERSION must contain x.y.z, got {version!r}")

with plist_path.open("rb") as handle:
    plist = plistlib.load(handle)
for key in ("CFBundleShortVersionString", "MADIFullVersion"):
    if plist.get(key) != version:
        raise SystemExit(f"{plist_path}:{key}={plist.get(key)!r}, expected {version!r}")

swift = swift_path.read_text(encoding="utf-8")
for name in ("fallbackFull", "fallbackMarketing"):
    match = re.search(rf'static let {name} = "([^"]+)"', swift)
    if not match or match.group(1) != version:
        actual = match.group(1) if match else "missing"
        raise SystemExit(f"{swift_path}:{name}={actual!r}, expected {version!r}")

print(f"✅ version mirrors match VERSION ({version})")
PY
