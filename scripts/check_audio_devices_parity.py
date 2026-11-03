#!/usr/bin/env python3
"""Compare live read-only Core Audio discovery with the unchanged Swift source.

Device identities are ephemeral; this is a live comparison, not a fixed golden.
Names stay local/in memory; the retained report only contains hashes and counts.
No stream is opened, permission requested or system default changed.
"""
import hashlib
import json
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "apps/macos/Sovereign/Audio/AudioDevices.swift"
OUT = ROOT / "out/audio-devices-parity"


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True)


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Live AudioDevices comparison requires macOS; Windows discovery is not implemented.")
    OUT.mkdir(parents=True, exist_ok=True)
    binary = OUT / "swift-audio-devices"
    subprocess.run([
        "swiftc", str(SOURCE), str(ROOT / "tests/parity/AudioDevicesOracle.swift"),
        "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run(["cargo", "build", "--locked", "-p", "madi-platform", "--example", "input_devices"], cwd=ROOT, check=True)
    before = json.loads(run(str(binary)))
    rust = json.loads(run(str(ROOT / "target/debug/examples/input_devices")))
    after = json.loads(run(str(binary)))
    if before != after:
        raise SystemExit("Device list/default changed during comparison; rerun after the hardware settles.")
    if rust != before:
        raise SystemExit("Rust and original Swift input device order/names/default differ.")
    report = {
        "schemaVersion": 1,
        "status": "passed",
        "os": platform.platform(),
        "source": str(SOURCE.relative_to(ROOT)),
        "sourceSHA256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "deviceCount": len(rust["devices"]),
        "defaultPresent": rust["defaultInputId"] is not None,
        "snapshotSHA256": hashlib.sha256(json.dumps(rust, ensure_ascii=False, sort_keys=True).encode()).hexdigest(),
        "scope": "Live read-only enumeration and default input only; no capture, hot-swap or permission validation",
    }
    (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
