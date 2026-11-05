#!/usr/bin/env python3
"""Compare first-run entry/download-size policy with unchanged shipping Swift."""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "apps/macos/Sovereign/AppInfo/FirstRunModelSetupPolicy.swift",
           ROOT / "apps/macos/Sovereign/Model/AssetManifest.swift"]
OUT = ROOT / "out/model-setup-parity"
REFERENCE = ROOT / "design/parity/model-setup-reference.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rust-only", action="store_true")
    parser.add_argument("--write-reference", action="store_true")
    args = parser.parse_args()
    if args.write_reference and args.rust_only:
        parser.error("Writing a reference requires the live Swift comparison")
    if not args.rust_only and platform.system() != "Darwin":
        raise SystemExit("Live model setup comparison requires macOS")
    OUT.mkdir(parents=True, exist_ok=True)
    swift_binary = OUT / "swift-model-setup"
    if not args.rust_only:
        subprocess.run(["swiftc", "-parse-as-library", *map(str, SOURCES), str(ROOT / "tests/parity/ModelSetupOracle.swift"), "-o", str(swift_binary)], check=True)
    subprocess.run(["cargo", "build", "--locked", "-p", "madi-platform", "--example", "model_setup_oracle"], cwd=ROOT, check=True)
    cases = [dict(requiredModelReady=required, translationModelReady=translation,
                  translationEngineAvailable=engine, choice=choice, variant=variant)
             for required, translation, engine, choice, variant in itertools.product(
                 (False, True), (False, True), (False, True),
                 (None, "transcriptionOnly", "recommended"), ("quality4B", "realtime2B"))]
    payload = json.dumps(cases, sort_keys=True).encode()
    suffix = ".exe" if os.name == "nt" else ""
    rust = json.loads(subprocess.check_output([str(ROOT / "target/debug/examples" / ("model_setup_oracle" + suffix))], input=payload))
    if not args.rust_only:
        swift = json.loads(subprocess.check_output([str(swift_binary)], input=payload))
        if swift != rust:
            for case, expected, actual in zip(cases, swift, rust):
                if expected != actual:
                    raise SystemExit(json.dumps(dict(case=case, swift=expected, rust=actual), indent=2))
            raise SystemExit("Model setup record count differs")
    report = dict(schemaVersion=1, status="passed", cases=len(cases),
                  swiftComparison="not-run" if args.rust_only else "live-unmodified-source",
                  sources={path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in SOURCES},
                  corpusSHA256=hashlib.sha256(payload).hexdigest(),
                  resultSHA256=hashlib.sha256(json.dumps(rust, sort_keys=True).encode()).hexdigest(),
                  scope="Existing-install entry, explicit first-run choice, engine absence and missing-only download totals; no download or UI execution")
    keys = ("cases", "sources", "corpusSHA256", "resultSHA256")
    if args.write_reference:
        REFERENCE.write_text(json.dumps({key: report[key] for key in keys}, indent=2) + "\n", encoding="utf-8")
    reference = json.loads(REFERENCE.read_text(encoding="utf-8"))
    for key in keys:
        if reference[key] != report[key]:
            raise SystemExit(f"Model setup reference differs: {key}\n" + json.dumps({"expected": reference[key], "actual": report[key]}, indent=2))
    (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
