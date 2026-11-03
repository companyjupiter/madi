#!/usr/bin/env python3
"""Read-only native model manifest/integrity comparison against shipping Swift."""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "apps/macos/Sovereign/Model/AssetManifest.swift"
OUT = ROOT / "out/asset-manifest-parity"
REFERENCE = ROOT / "design/parity/asset-manifest-reference.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rust-only", action="store_true", help="Compare to pinned Swift results without executing Swift")
    parser.add_argument("--write-reference", action="store_true", help="Record a new reference after a successful live Swift comparison")
    args = parser.parse_args()
    if args.write_reference and args.rust_only:
        parser.error("Writing a reference requires the live Swift comparison")
    if not args.rust_only and platform.system() != "Darwin":
        raise SystemExit("Live AssetManifest comparison requires macOS")
    OUT.mkdir(parents=True, exist_ok=True)
    swift_binary = OUT / "swift-asset-manifest"
    if not args.rust_only:
        subprocess.run(["swiftc", "-parse-as-library", str(SOURCE), str(ROOT / "tests/parity/AssetManifestOracle.swift"), "-o", str(swift_binary)], check=True)
    subprocess.run(["cargo", "build", "--locked", "-p", "madi-platform", "--example", "asset_manifest_oracle"], cwd=ROOT, check=True)
    memories = [0, 8 * (1 << 30), 12 * (1 << 30) - 1, 12 * (1 << 30), 16 * (1 << 30), 32 * (1 << 30), 64 * (1 << 30)]
    overrides = [None, "", "2b", "4b", "2B", "4B", " 2b", "4b ", "invalid", "２b"]
    suffix = ".exe" if os.name == "nt" else ""
    rust_binary = ROOT / "target/debug/examples" / ("asset_manifest_oracle" + suffix)
    def run(binary, cases):
        return json.loads(subprocess.check_output([str(binary)], input=json.dumps(cases, ensure_ascii=False).encode()))
    def compare(swift, rust):
        if swift != rust:
            for key in ("assets", "choices", "files"):
                if swift[key] != rust[key]:
                    raise SystemExit(json.dumps({"section": key, "swift": swift[key], "rust": rust[key]}, ensure_ascii=False, indent=2))
    with tempfile.TemporaryDirectory(prefix="madi-asset-parity-") as temporary:
        folder = Path(temporary)
        files = []
        contents = [b"", b"abc", "한국어 model 👩🏽‍💻".encode(), bytes(range(256)) * 32768 + b"tail"]
        for index, data in enumerate(contents):
            path = folder / f"fixture-{index}.bin"
            path.write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            for size, expected in itertools.product((len(data), len(data) + 1), (digest, "0" * 64, digest.upper())):
                files.append(dict(path=path.name, size=size, sha256=expected, hashInput=True))
        trusted = folder / "fixture-1.bin"
        link = folder / "link.bin"
        link.symlink_to(trusted)
        files.extend([
            dict(path=link.name, size=3, sha256=hashlib.sha256(b"abc").hexdigest(), hashInput=True),
            dict(path="missing", size=3, sha256="0" * 64, hashInput=False),
            dict(path=".", size=1, sha256="0" * 64, hashInput=False),
        ])
        corpus = dict(memories=memories, overrides=overrides, files=files)
        payload = dict(corpus, files=[dict(case, path=str(folder / case["path"])) for case in files])
        rust = run(rust_binary, payload)
        if not args.rust_only:
            compare(run(swift_binary, payload), rust)
            # Exercise the original override property at this machine's actual
            # memory too, independently of the deterministic pinned corpus.
            actual_memory = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]))
            host_cases = dict(memories=[actual_memory], overrides=overrides, files=[])
            compare(run(swift_binary, host_cases), run(rust_binary, host_cases))
        # Originals, including the large buffer-boundary fixture, stay untouched.
        assert all((folder / f"fixture-{index}.bin").read_bytes() == data for index, data in enumerate(contents))
        assert link.is_symlink()
    report = {
        "schemaVersion": 1, "status": "passed", "assets": len(rust["assets"]),
        "selectionCases": len(rust["choices"]), "integrityCases": len(rust["files"]),
        "swiftComparison": "not-run" if args.rust_only else "live-unmodified-source",
        "actualHostOverrideCases": 0 if args.rust_only else len(overrides),
        "sourceSHA256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "corpusSHA256": hashlib.sha256(json.dumps(corpus, ensure_ascii=False, sort_keys=True).encode()).hexdigest(),
        "resultSHA256": hashlib.sha256(json.dumps(rust, ensure_ascii=False, sort_keys=True).encode()).hexdigest(),
        "scope": "Live shipping manifest, memory/override selection, full integrity and hashing; no downloads or production model/support-directory writes",
    }
    keys = ("assets", "selectionCases", "integrityCases", "sourceSHA256", "corpusSHA256", "resultSHA256")
    if args.write_reference:
        REFERENCE.write_text(json.dumps({key: report[key] for key in keys}, indent=2) + "\n", encoding="utf-8")
    reference = json.loads(REFERENCE.read_text(encoding="utf-8"))
    for key in keys:
        if reference[key] != report[key]:
            raise SystemExit(f"Asset manifest reference differs: {key}\n" + json.dumps({"expected": reference[key], "actual": report[key]}, indent=2))
    (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
