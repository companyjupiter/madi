#!/usr/bin/env python3
"""Record a built parity harness. This does not execute or certify its UI."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
binary = ROOT / "target/debug" / ("madi-desktop.exe" if sys.platform == "win32" else "madi-desktop")
source_status = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).splitlines()
report = {
    "schemaVersion": 1,
    "sourceHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
    "sourceDirty": bool(source_status),
    "sourceStatus": source_status,
    "host": platform.platform(),
    "binary": str(binary.relative_to(ROOT)),
    "bytes": binary.stat().st_size,
    "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "productRelease": False,
    "nativeUIParity": "not-verified",
    "fileTranscription": "native timed owner connected; native screen interaction not verified",
    "recording": "not-connected",
}
out = ROOT / "out/desktop-build/report.json"
out.parent.mkdir(parents=True, exist_ok=True)
(out.parent / "source.diff").write_bytes(subprocess.check_output(["git", "diff", "--no-ext-diff"], cwd=ROOT))
out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(json.dumps(report, indent=2))
