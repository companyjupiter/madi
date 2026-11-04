#!/usr/bin/env python3
"""Exercise the linked Swift→Rust capture ABI without opening audio devices."""
from pathlib import Path
import hashlib
import json
import math
import os
import platform
import struct
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out/capture-bridge-parity"
SOURCES = [
    "apps/macos/Sovereign/Audio/Resampler.swift",
    "apps/macos/Sovereign/Audio/Segmenter.swift",
    "apps/macos/Sovereign/Audio/WavWriter.swift",
    "tests/parity/CaptureBridgeOracle.swift",
]


def run(command, **options):
    return subprocess.run(command, cwd=ROOT, check=True, **options)


def main():
    if platform.system() != "Darwin":
        raise SystemExit("native capture bridge gate requires macOS; no simulated PASS")
    OUT.mkdir(parents=True, exist_ok=True)
    cases = []
    fixtures = []
    for rate, channels in [(16000, 1), (44100, 1), (48000, 2), (96000, 2)]:
        path = OUT / f"fixture-{rate}-{channels}.wav"
        data = bytearray()
        # 13 seconds spans the short first window, steady window and final tail.
        # Include voiced, quiet, silent, and saturated channel mixtures.
        for i in range(rate * 13 + 137):
            second = i / rate
            amplitude = 0 if 4 <= second < 5 else (120 if 7 <= second < 8 else 24000)
            for channel in range(channels):
                value = round(amplitude * math.sin(2 * math.pi * (237 + channel * 313) * second))
                if 10 <= second < 10.01:
                    value = -32768 if (i + channel) % 2 else 32767
                data.extend(struct.pack("<h", value))
        with wave.open(str(path), "wb") as wav:
            wav.setnchannels(channels); wav.setsampwidth(2); wav.setframerate(rate)
            wav.writeframes(data)
        fixtures.append({"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
        for chunk in (4096, 997):
            cases.append({"name": f"{rate}-{channels}-{chunk}", "path": str(path), "chunk": chunk})
    payload = json.dumps(cases).encode()
    oracle = OUT / "swift-oracle"
    run(["xcrun", "swiftc", "-O", "-o", str(oracle), *SOURCES])
    swift = run([str(oracle)], input=payload, capture_output=True).stdout
    cargo = os.environ.get("CARGO", "cargo")
    run([cargo, "build", "--locked", "-p", "madi-platform", "--example", "capture_bridge_oracle"])
    native = run([str(ROOT / "target/debug/examples/capture_bridge_oracle")], input=payload, capture_output=True, timeout=90).stdout
    (OUT / "swift.json").write_bytes(swift)
    (OUT / "rust.json").write_bytes(native)
    expected, actual = json.loads(swift), json.loads(native)
    assert actual == expected, "native callback PCM/segmentation/lifecycle differs from shipping Swift"
    # Error delivery, final acknowledgement and cleanup also work if open fails.
    invalid = [{"name": "missing", "path": str(OUT / "does-not-exist.wav"), "chunk": 4096}]
    failed = json.loads(run([str(ROOT / "target/debug/examples/capture_bridge_oracle")], input=json.dumps(invalid).encode(), capture_output=True, timeout=30).stdout)[0]
    assert failed["events"][-1] == "stopped" and len(failed["events"]) == 2
    assert failed["events"][0].startswith("fault:") and failed["sampleCount"] == 0
    normalized = json.dumps(actual, sort_keys=True, separators=(",", ":")).encode()
    # No developer-library path may be needed when the native bridge is linked.
    binary = ROOT / "target/debug/examples/capture_bridge_oracle"
    libraries = run(["otool", "-L", str(binary)], capture_output=True, text=True).stdout
    for line in libraries.splitlines()[1:]:
        assert not any(marker in line for marker in ("/Applications/", "/Users/", "/opt/homebrew/")), line
    report = {
        "schemaVersion": 1, "status": "passed", "nativeSwiftRun": True,
        "scope": "In-process native resampler/callback ABI and Rust segmentation; no device or permissions",
        "cases": len(cases), "samples": sum(case["sampleCount"] for case in actual),
        "segments": sum(len(case["segments"]) for case in actual),
        "cancelBeforeStartCases": len(cases) + 1, "concurrentDropCases": len(cases) + 1,
        "missingFileFailure": True, "fixtures": fixtures,
        "ownedWavPipeline": True, "segmentDirectoryCleanup": True,
        "resultSHA256": hashlib.sha256(normalized).hexdigest(),
        "sourceSHA256": {source: hashlib.sha256((ROOT / source).read_bytes()).hexdigest() for source in SOURCES},
        "linkedLibraries": libraries.splitlines()[1:],
        "limitations": ["Microphone and ScreenCaptureKit hardware NOT_RUN", "Device switch and permission denial NOT_RUN", "No live engine or UI session is connected by this gate"],
    }
    (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
