#!/usr/bin/env python3
"""Compare stateful stdout events with the unchanged shipping Swift decoder."""
import hashlib
import argparse
import itertools
import json
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out/transcribe-parser-parity"
SWIFT = ROOT / "apps/macos/Sovereign/Engine/EngineProtocol.swift"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rust-only", action="store_true")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "report.json").write_text('{"status":"running"}\n')
    cargo = os.environ.get("CARGO") or shutil.which("cargo") or str(Path.home() / ".cargo/bin/cargo")
    if not args.rust_only:
        subprocess.run(["swiftc", "-O", str(SWIFT), str(ROOT / "tests/parity/TranscribeOracle.swift"),
                        "-o", str(OUT / "swift-oracle")], check=True)
    subprocess.run([cargo, "build", "-p", "madi-protocol", "--example", "transcribe_oracle"], cwd=ROOT, check=True)
    controls = ["[stream] ready (model)", "=== WORD TIMESTAMPS ===", "=== SEGMENT ===",
                "<<PREVIEW_BEGIN>>", "<<PREVIEW_END>>", "<<FLUSH_END>>", "<<SEG_END>>", "SPKOVRESET",
                "[8] audio: 12s → 5 chunk(s)", "[perf] chunk 2: 10ms",
                "[lang] locked token 50264 margin 2.60", "[lang] detected token 50259 (en)",
                "[lang] probe 1 token 50264", "SPKNAME 2 김 부장", "SPK 2.5 1", "SPKFIX 2.5 1 1.5 0.4",
                "SPKOV 2.5 3 bad bad", "«partial 1.25» 한글 日本語 🙂", "[1.0s-2.5s] hello «conf 0.91»",
                "[3s-4s] 다음 단어", "diagnostic", ""]
    # All short state transitions, then long deterministic interleavings.
    cases = [list(case) for case in itertools.product(controls, repeat=2)]
    rng = random.Random(47)
    cases += [[rng.choice(controls) for _ in range(80)] for _ in range(50)]
    numbers = ["0", "-0", "+2", "12.5", ".25", "1e-3", "1e309", "1e-324", "nan", "-nan", "INF",
               "0x1p2", "0x1.8p1", "0x1P2", "0X1p2", "0xAbp2", "0x1", "0x1.2", "-0x1p-2",
               "0x1p99999999999999999999", "0x1p-99999999999999999", "0x1.00000000000008p0",
               "0x1.00000000000008001p0", "0x1.00000000000018p0", "0x1p-1075", "0x1.1p-1075",
               "0x1.fffffffffffff8p1023", "nan(3)", "nan()", "nan(foo)", "nan(0x123)", "-nan(3)",
               "nan(18446744073709551616)", "nan(2251799813685248)", "bad", "", "1_000", "１２", "1\t", "1 "]
    # Test exact and rounded hexadecimal values across normal/subnormal bounds
    # against Swift, rather than mirroring the Rust conversion implementation.
    numbers += [f"{'-' if rng.randrange(2) else ''}0x{rng.randrange(1,16):x}.{rng.getrandbits(80):020x}p{rng.randint(-1150,1100)}" for _ in range(500)]
    for number in numbers:
        for tag in ["SPK", "SPKFIX", "SPKOV"]:
            cases.append([f"{tag} {number} 2 {number} {number}", f"{tag} 1 {number}"])
        cases.append(["=== WORD TIMESTAMPS ===", f"[{number}s-2s] text «conf {number}»", f"«partial {number}» text"])
    for cp in [9, 10, 11, 12, 13, 0x85, 0xa0, 0x1680, *range(0x2000, 0x200c), 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff]:
        ch = chr(cp)
        cases.append([ch + line + ch for line in controls])
    for number in ["12", "12x", "12²", "١٢", "12٣", "1️⃣", "9223372036854775808", "-2"]:
        cases.append([f"[perf] chunk {number}: done", f"[lang] locked token {number} (en)", f"[8] audio: 2s → {number} chunks"])
    payload = bytearray(struct.pack("<I", len(cases)))
    for lines in cases:
        payload.extend(struct.pack("<I", len(lines)))
        for line in lines:
            raw = line.encode()
            payload.extend(struct.pack("<I", len(raw)))
            payload.extend(raw)
    profile = "current" if args.rust_only else subprocess.check_output([str(OUT / "swift-oracle"), "--float-profile"], text=True).strip()
    assert profile in ("current", "legacy"), profile
    def run(path, arguments=()):
        return subprocess.run([str(path), *arguments], input=payload, stdout=subprocess.PIPE, check=True).stdout
    swift = None if args.rust_only else run(OUT / "swift-oracle")
    rust_path = ROOT / "target/debug/examples" / ("transcribe_oracle.exe" if sys.platform == "win32" else "transcribe_oracle")
    rust = run(rust_path, ["--legacy-float-syntax"] if profile == "legacy" else [])
    canonical = rust if profile == "current" else run(rust_path)
    if swift is not None:
        (OUT / "swift.events").write_bytes(swift)
    (OUT / "rust.events").write_bytes(rust)
    report = {"status": "pass" if swift is None or swift == rust else "fail", "cases": len(cases), "events": sum(map(len, cases)),
              "swiftComparison": "not-run" if args.rust_only else "live-unmodified-source",
              "corpusSha256": hashlib.sha256(payload).hexdigest(),
              "swiftSourceSha256": hashlib.sha256(SWIFT.read_bytes()).hexdigest(),
              "eventStreamSha256": hashlib.sha256(rust).hexdigest(),
              "floatSyntaxProfile": None if args.rust_only else profile,
              "canonicalDefaultMatchesHost": None if args.rust_only else profile == "current",
              "canonicalEventStreamSha256": hashlib.sha256(canonical).hexdigest()}
    reference = ROOT / "design/parity/transcribe-reference.json"
    if not reference.exists():
        report["status"] = "fail"
        report["error"] = "pinned Swift reference is required"
    else:
        pinned = json.loads(reference.read_text())
        if (any(report[key] != pinned[key] for key in ("corpusSha256", "swiftSourceSha256"))
                or report["canonicalEventStreamSha256"] != pinned["eventStreamSha256"]):
            report["status"] = "fail"
    (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if swift is not None and swift != rust:
        for expected, actual in zip(swift.splitlines(), rust.splitlines()):
            if expected != actual:
                case, line = (int(part) for part in expected.split(b":", 2)[:2])
                print(json.dumps({"input": cases[case][line], "preceding": cases[case][:line], "swift": expected.decode(), "rust": actual.decode()}, ensure_ascii=False))
        raise SystemExit("stdout parser parity failed")
    if report["status"] != "pass":
        raise SystemExit("pinned stdout parser reference mismatch")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
