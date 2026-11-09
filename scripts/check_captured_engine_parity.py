#!/usr/bin/env python3
"""Replay real macOS engine output through unchanged Swift and Rust parsers.

Requires the local engine smoke's stdout.log, events.jsonl and dna4b-stdout.log.
This tests captured bytes, not live product supervision or translation quality.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def word(value):
    return struct.pack("<I", value)


def strings(values):
    return word(len(values)) + b"".join(word(len(value)) + value for value in values)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("Live Swift comparison requires macOS")
    directory = args.directory.resolve()
    stdout = (directory / "stdout.log").read_bytes()
    jsonl = (directory / "events.jsonl").read_bytes()
    translation = (directory / "dna4b-stdout.log").read_bytes()
    events = [json.loads(line) for line in jsonl.splitlines()]
    transcript = " ".join(event["text"] for event in events if event["t"] == "seg")
    if b"<<FLUSH_END>>" not in stdout or "ask not what your country" not in transcript:
        raise SystemExit("Expected completed JFK file transcription is absent")
    out = directory / "parser-comparison"
    out.mkdir(exist_ok=True)
    source_files = {
        "transcribe": ("EngineProtocol.swift", "TranscribeOracle.swift"),
        "structured": ("EngineEvents.swift", "StructuredOracle.swift"),
        "translate": ("TranslateStreamParser.swift", "TranslateOracle.swift"),
    }
    command = ["cargo", "build", "--locked", "-p", "madi-protocol"]
    for name in source_files:
        command += ["--example", f"{name}_oracle"]
    subprocess.run(command, cwd=ROOT, check=True)
    reports = []
    translate_payload = word(4)
    for size in (1, 7, 31, 4096):
        translate_payload += b"\0" + strings([translation[i:i + size] for i in range(0, len(translation), size)])
    payloads = {
        "transcribe": word(1) + strings(stdout.splitlines()),
        "structured": strings(jsonl.splitlines()),
        "translate": translate_payload,
    }
    completed = []
    for name, (source, driver) in source_files.items():
        source = ROOT / "apps/macos/Sovereign/Engine" / source
        binary = out / f"swift-{name}"
        subprocess.run(["swiftc", str(source), str(ROOT / "tests/parity" / driver), "-o", str(binary)], check=True)
        rust_args = []
        if name == "transcribe" and subprocess.check_output([str(binary), "--float-profile"]).strip() == b"legacy":
            rust_args = ["--legacy-float-syntax"]
        if name == "structured" and subprocess.check_output([str(binary), "--json-profile"]).strip() == b"last":
            rust_args = ["--last-duplicate-key"]
        if name == "translate" and subprocess.check_output([str(binary), "--foundation-profile"]).strip() == b"preserve-bom":
            rust_args = ["--preserve-bom"]
        swift = subprocess.check_output([str(binary)], input=payloads[name])
        rust = subprocess.check_output([str(ROOT / "target/debug/examples" / f"{name}_oracle"), *rust_args], input=payloads[name])
        if swift != rust:
            raise SystemExit(f"{name}: real engine output differs between original Swift and Rust")
        (out / f"{name}.events").write_bytes(rust)
        reports.append({
            "parser": name, "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "payloadSHA256": hashlib.sha256(payloads[name]).hexdigest(),
            "eventSHA256": hashlib.sha256(rust).hexdigest(), "compatibilityArguments": rust_args,
        })
        if name == "translate":
            completed = [bytes.fromhex(line.split(":", 3)[3]).decode() for line in rust.decode().splitlines() if ":complete:" in line]
    if len(completed) != 4 or len(set(completed)) != 1 or not completed[0].strip():
        raise SystemExit("Translation must complete once identically at all four chunk sizes")
    report = {
        "schemaVersion": 1, "status": "passed", "comparisons": reports,
        "structuredEvents": len(events), "transcript": transcript,
        "translation": completed[0], "translationChunkSizes": [1, 7, 31, 4096],
        "scope": "Captured real ASR/DNA4B output, not Tauri product integration or a quality/performance benchmark",
    }
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
