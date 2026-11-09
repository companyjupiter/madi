#!/usr/bin/env python3
"""Compare typed file-mode launch arguments/options with shipping Swift code.

Extracts unchanged Config, launch construction and SpeakerCount properties.
No process is launched by the Swift oracle and no user/model files are read.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "apps/macos/Sovereign/Engine/EngineProcess.swift"
SESSION = ROOT / "apps/macos/Sovereign/SessionController.swift"
OUT = ROOT / "out/asr-config-parity"
KEYS = "CONF DIAR OSD ENC_F16_CACHE DIAR_MAXK DIAR_K VAD_PROB WHISPER_LANG_ID PROMPT APP_FILE STREAM AUDIO_CTX PARTIALS LANG_CANDIDATES DIAR_ANCHOR STREAM_WAV_ROOTS VOICEPRINTS".split()


def block(source, signature):
    start = source.index(signature)
    position = source.index("{", start) + 1
    depth = 1
    while depth:
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
        position += 1
    return source[start:position]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rust-only", action="store_true", help="Compare to the pinned Swift reference without executing Swift")
    args = parser.parse_args()
    if not args.rust_only and platform.system() != "Darwin":
        raise SystemExit("Live ASR configuration comparison requires macOS")
    OUT.mkdir(parents=True, exist_ok=True)
    engine, session = ENGINE.read_text(encoding="utf-8"), SESSION.read_text(encoding="utf-8")
    config = block(engine, "    struct Config {")
    start = engine.index("        process.executableURL = config.binaryURL")
    end = engine.index("        process.environment = env", start) + len("        process.environment = env")
    launch = engine[start:end]
    speakers = session[session.index("enum SpeakerCount:"):]
    properties = "\n".join(block(speakers, "    var " + name) for name in ("maxSpeakers: Int", "fixedK: Int?", "vadProb: Double"))
    token_table = next(line.strip() for line in session.splitlines() if 'let tok: [String: Int] = ["English":' in line)
    driver = OUT / "ASRConfigOracle.swift"
    driver.write_text('''import Foundation
enum SpeakerCount: Int { case auto = 0, two = 2, three = 3, four = 4, fivePlus = 5
''' + properties + '''
}
struct LaunchOracle {
''' + config + '''
    let config: Config
    let process = Process()
    let eventsURL = URL(fileURLWithPath: "/madi/owned/events.jsonl")
    func build() {
''' + launch + '''
    }
}
struct Case: Decodable {
    let speakerCount: Int; let diarize: Bool; let osd: Bool
    let inputLanguage: String?; let physicalMemory: UInt64; let biasTerms: [String]; let defaults: Bool
}
@main enum Driver {
    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let keys = Set(''' + json.dumps(KEYS) + ''')
        ''' + token_table + '''
        var result: [[String: Any]] = []
        for c in cases {
            var config = LaunchOracle.Config(binaryURL: URL(fileURLWithPath: "/madi/engine"), modelURL: URL(fileURLWithPath: "/madi/model"), bpeURL: URL(fileURLWithPath: "/madi/bpe"), assetsDir: URL(fileURLWithPath: "/madi/assets"), fileURL: URL(fileURLWithPath: "/madi/owned/input.wav"))
            if !c.defaults {
                let speakers = SpeakerCount(rawValue: c.speakerCount)!
                config.diarize = c.diarize; config.osd = c.osd
                config.languageTokenID = c.inputLanguage.flatMap { tok[$0] }
                config.maxSpeakers = speakers.maxSpeakers; config.fixedK = speakers.fixedK; config.vadProb = speakers.vadProb
                config.encoderF16Cache = c.physicalMemory >= 24 * (1 << 30)
                config.biasTerms = c.biasTerms
            }
            let oracle = LaunchOracle(config: config)
            oracle.build()
            result.append(["executable": oracle.process.executableURL!.path, "cwd": oracle.process.currentDirectoryURL!.path, "arguments": oracle.process.arguments!, "environment": oracle.process.environment!.filter { keys.contains($0.key) }])
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    }
}
''', encoding="utf-8")
    binary = OUT / "swift-asr-config"
    if not args.rust_only:
        subprocess.run(["swiftc", "-parse-as-library", str(driver), str(ROOT / "apps/macos/Sovereign/Engine/EnginePathPolicy.swift"), "-o", str(binary)], check=True)
    subprocess.run(["cargo", "build", "--locked", "-p", "madi-platform", "--example", "asr_config_oracle"], cwd=ROOT, check=True)
    cases = [dict(speakerCount=count, inputLanguage=language, diarize=diarize, osd=osd, physicalMemory=memory, biasTerms=terms, defaults=False)
             for count, language, diarize, osd, memory, terms in itertools.product(
                 (0, 2, 3, 4, 5), (None, "English", "Chinese", "Korean", "Japanese"), (False, True), (False, True),
                 (24 * (1 << 30) - 1, 24 * (1 << 30), 32 * (1 << 30)), ([], ["마디", "Rust/Tauri", "two words", "line\nbreak"]))]
    cases.append(dict(cases[0], defaults=True))
    payload = json.dumps(cases, ensure_ascii=False).encode()
    # Compare normal app launches. Parent-shell contamination is a separate Rust
    # regression: the port intentionally clears unset owned keys, unlike Swift.
    environment = {key: value for key, value in os.environ.items() if key not in KEYS}
    suffix = ".exe" if os.name == "nt" else ""
    rust = json.loads(subprocess.check_output([str(ROOT / "target/debug/examples" / ("asr_config_oracle" + suffix))], input=payload, env=environment))
    swift = None if args.rust_only else json.loads(subprocess.check_output([str(binary)], input=payload, env=environment))
    if swift is not None and swift != rust:
        for case, expected, actual in zip(cases, swift, rust):
            if expected != actual:
                raise SystemExit(json.dumps({"case": case, "swift": expected, "rust": actual}, ensure_ascii=False, indent=2))
        raise SystemExit("ASR configuration record count differs")
    report = {
        "schemaVersion": 1, "status": "passed", "cases": len(cases),
        "swiftComparison": "not-run" if args.rust_only else "live-extracted-unmodified-source",
        "sources": {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in (ENGINE, SESSION)},
        "extractedSourceSHA256": hashlib.sha256((config + launch + properties + token_table).encode()).hexdigest(),
        "corpusSHA256": hashlib.sha256(payload).hexdigest(),
        "resultSHA256": hashlib.sha256(json.dumps(rust, ensure_ascii=False, sort_keys=True).encode()).hexdigest(),
        "scope": "File-mode launch construction and setup mapping; no process execution, model admission, live capture or UI integration",
        "intentionalDifference": "Rust removes unset engine-owned environment keys so inherited STREAM/fixed-K/language/glossary cannot override the setup",
    }
    reference = json.loads((ROOT / "design/parity/asr-config-reference.json").read_text(encoding="utf-8"))
    for key in ("cases", "sources", "extractedSourceSHA256", "corpusSHA256", "resultSHA256"):
        if reference[key] != report[key]:
            raise SystemExit(f"ASR configuration reference differs: {key}\n" + json.dumps({"expected": reference[key], "actual": report[key]}, indent=2))
    (OUT / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
