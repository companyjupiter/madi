#!/usr/bin/env python3
"""Compare Rust events against the unmodified shipping Swift parser."""
import hashlib
import argparse
import json
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import time
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out" / "translate-parser-parity"
SWIFT = ROOT / "apps/macos/Sovereign/Engine/TranslateStreamParser.swift"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rust-only", action="store_true", help="Validate pinned Swift reference hashes without a local Swift runtime")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "report.json").write_text('{"status":"running"}\n')
    cargo = os.environ.get("CARGO") or shutil.which("cargo") or str(Path.home() / ".cargo/bin/cargo")
    if not args.rust_only:
        subprocess.run(["swiftc", "-O", str(SWIFT), str(ROOT / "tests/parity/TranslateOracle.swift"),
                        "-o", str(OUT / "swift-oracle")], check=True, cwd=ROOT)
    subprocess.run([cargo, "build", "-p", "madi-protocol", "--example", "translate_oracle"], check=True, cwd=ROOT)
    streams = [
        b"Loading\n[caps] pfxcache fp max\nREADY\n> PFX_OK 2 40\n",
        ("READY\n> [chat] 58 tokens\n[perf] prefill: 58 tok in 1ms\n"
         "레이저 치료後 🙂\n[perf] generation: 4 tok in 1ms\n> "
         "[chat] 3 tokens\n[perf] prefill: 3 tok\nBonjour\n[perf] generation: 1 tok\n").encode(),
        "[perf] prefill: 3 tok\n[요약] 첫 줄\n\n[액션] 둘째 줄\n[perf] generation: 2 tok\n".encode(),
        b"> [warn] oversized\n[perf] generation: 0 tok in 0ms\n> [perf] prefill: 2 tok\nHello\n[perf] generation: 1 tok\n",
        b"[perf] prefill\n\xf0\x9f\x99\x82\xea\xb0\x80\n[perf] generation: 2 tok\n",
        b"invalid \xff control\nREADY\n[perf] prefill\nok\xffmore\n[perf] generation: 1 tok\n",
        b"PFX_OK -2 20\nPFX_OK +3\nPFX_OK 999999999999999999999999\n[caps]  fp  max \n",
        b"[perf] prefill\nunfinished",
    ]
    # Probe Foundation character-set behavior, rather than assuming Rust trim
    # has the same definition. Include zero-width and line-separator edge cases.
    for cp in [0x09, 0x0b, 0x0c, 0x20, 0x85, 0xa0, 0x1680, *range(0x2000, 0x200c),
               0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff]:
        ch = chr(cp)
        streams.append(f">{ch}READY{ch}\n[perf] prefill\n{ch}한글{ch}\n[perf] generation\n".encode())
    cases = []
    rng = random.Random(47)
    for stream in streams:
        for preserve in (False, True):
            cases.append((preserve, [bytes([b]) for b in stream]))
            for split in range(len(stream) + 1):
                cases.append((preserve, [stream[:split], stream[split:]]))
            for _ in range(12):
                chunks = []
                position = 0
                while position < len(stream):
                    end = min(len(stream), position + rng.randint(1, 23))
                    chunks.append(stream[position:end])
                    position = end
                cases.append((preserve, chunks))
    payload = bytearray(struct.pack("<I", len(cases)))
    for preserve, chunks in cases:
        payload.extend(struct.pack("<BI", preserve, len(chunks)))
        for chunk in chunks:
            payload.extend(struct.pack("<I", len(chunk)))
            payload.extend(chunk)
    started = time.monotonic()
    profile = "strip-leading-bom" if args.rust_only else subprocess.check_output([str(OUT / "swift-oracle"), "--foundation-profile"], text=True).strip()
    assert profile in ("preserve-bom", "strip-leading-bom"), profile
    def run(path, arguments=()):
        return subprocess.run([str(path), *arguments], input=payload, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=True, timeout=60).stdout
    rust_path = ROOT / "target/debug/examples" / ("translate_oracle.exe" if sys.platform == "win32" else "translate_oracle")
    expected = None if args.rust_only else run(OUT / "swift-oracle")
    actual = run(rust_path, ["--preserve-bom"] if profile == "preserve-bom" else [])
    if expected is not None:
        (OUT / "swift.events").write_bytes(expected)
    (OUT / "rust.events").write_bytes(actual)
    report = {
        "cases": len(cases), "modes": ["translation", "summary"],
        "foundationUTF8Profile": None if args.rust_only else profile,
        "swiftComparison": "not-run" if args.rust_only else "live-unmodified-source",
        "canonicalDefaultMatchesHost": None if args.rust_only else profile == "strip-leading-bom",
        "corpusSha256": hashlib.sha256(payload).hexdigest(),
        "swiftSourceSha256": hashlib.sha256(SWIFT.read_bytes()).hexdigest(),
        "eventStreamSha256": hashlib.sha256(actual).hexdigest(),
        "status": "pass" if expected is None or actual == expected else "fail",
        "seconds": round(time.monotonic() - started, 3),
    }
    canonical = actual if profile == "strip-leading-bom" else run(rust_path)
    report["canonicalEventStreamSha256"] = hashlib.sha256(canonical).hexdigest()
    reference = ROOT / "design/parity/translate-reference.json"
    pinned = json.loads(reference.read_text())
    if report["corpusSha256"] != pinned["corpusSha256"] or report["canonicalEventStreamSha256"] != pinned["eventStreamSha256"] or report["swiftSourceSha256"] != pinned["swiftSourceSha256"]:
        report["status"] = "fail"
        (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        raise SystemExit("canonical macOS 27.2 parser reference changed; investigate before updating it")
    (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if expected is not None and actual != expected:
        import difflib
        print("".join(list(difflib.unified_diff(expected.decode().splitlines(True),
                                              actual.decode().splitlines(True)))[:100]))
        raise SystemExit("Swift/Rust parser mismatch")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
