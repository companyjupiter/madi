#!/usr/bin/env python3
"""Compare first-run action visibility with extracted unchanged Swift view rules."""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/model-gate-parity'
REFERENCE = ROOT / 'design/parity/model-gate-reference.json'
VIEW = ROOT / 'apps/macos/Sovereign/UI/ModelGateView.swift'
DOWNLOADERS = [ROOT / 'apps/macos/Sovereign/Model' / name for name in ('ModelDownloader.swift', 'TranslateModelDownloader.swift')]

def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only', action='store_true')
    parser.add_argument('--write-reference', action='store_true')
    args = parser.parse_args()
    if args.write_reference and args.rust_only:
        parser.error('Reference requires live Swift comparison')
    if not args.rust_only and platform.system() != 'Darwin':
        raise SystemExit('Live Swift comparison requires macOS')
    OUT.mkdir(parents=True, exist_ok=True)
    view = VIEW.read_text(encoding='utf-8')
    rules = '\n'.join(block(view, f'private var {name}: Bool') for name in ('isDownloading', 'hasRetryableDownload'))
    continuation = re.search(r'if (setupChoice == \.recommended && downloader.state == \.ready && translateDownloader.state != \.ready) \{', view)
    assert continuation, 'Source continuation rule changed; review the oracle extraction'
    swift = 'import Foundation\n'
    for path in DOWNLOADERS:
        swift += f'struct {path.stem} {{\n' + block(path.read_text(encoding='utf-8'), 'enum State: Equatable') + '\nvar state: State\n}\n'
    swift += '''
enum FirstRunModelSetupChoice: String, Decodable { case transcriptionOnly, recommended }
struct Input: Decodable { let required: String; let translation: String; let choice: FirstRunModelSetupChoice?; let engine: Bool }
struct ViewOracle {
    let downloader: ModelDownloader
    let translateDownloader: TranslateModelDownloader
    let setupChoice: FirstRunModelSetupChoice?
'''+ rules + '''
    func result() -> [String: Bool] {
        ["isDownloading": isDownloading, "hasRetryableDownload": hasRetryableDownload,
         "canContinueTranscription": '''+ continuation.group(1) + ''']
    }
}
@main enum Main {
    static func main() throws {
        let input = try JSONDecoder().decode([Input].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let output = input.map { c -> [String: Bool] in
            let required: ModelDownloader.State
            switch c.required {
            case "idle": required = .idle
            case "checking": required = .checking
            case "downloading": required = .downloading(progress: 0.35)
            case "verifying": required = .verifying
            case "ready": required = .ready
            case "cancelled": required = .cancelled
            case "failed": required = .failed("fixture")
            default: preconditionFailure("unknown required state")
            }
            let translation: TranslateModelDownloader.State
            switch c.translation {
            case "idle": translation = .idle
            case "downloading": translation = .downloading(progress: 0.35)
            case "verifying": translation = .verifying
            case "ready": translation = .ready
            case "failed": translation = .failed("fixture")
            default: preconditionFailure("unknown translation state")
            }
            return ViewOracle(downloader: .init(state: required), translateDownloader: .init(state: translation), setupChoice: c.choice).result()
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
    }
}
'''
    source = OUT / 'ModelGateOracle.swift'
    source.write_text(swift, encoding='utf-8')
    binary = OUT / 'swift-model-gate'
    if not args.rust_only:
        subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run(['cargo', 'build', '--locked', '-p', 'madi-platform', '--example', 'model_gate_oracle'], cwd=ROOT, check=True)
    cases = [dict(required=required, translation=translation, choice=choice, engine=engine)
             for required, translation, choice, engine in itertools.product(
                 ('idle', 'checking', 'downloading', 'verifying', 'ready', 'cancelled', 'failed'),
                 ('idle', 'downloading', 'verifying', 'ready', 'failed'),
                 (None, 'transcriptionOnly', 'recommended'), (False, True))]
    payload = json.dumps(cases, sort_keys=True).encode()
    suffix = '.exe' if os.name == 'nt' else ''
    rust = json.loads(subprocess.check_output([str(ROOT / 'target/debug/examples' / ('model_gate_oracle' + suffix))], input=payload))
    if not args.rust_only:
        expected = json.loads(subprocess.check_output([str(binary)], input=payload))
        if rust != expected:
            raise SystemExit(json.dumps([dict(case=c, swift=e, rust=a) for c, e, a in zip(cases, expected, rust) if e != a], indent=2))
    report = dict(schemaVersion=1, status='passed', cases=len(cases),
                  swiftComparison='not-run' if args.rust_only else 'live-extracted-unmodified-view-rules',
                  sources={p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in [VIEW, *DOWNLOADERS]},
                  corpusSHA256=hashlib.sha256(payload).hexdigest(), resultSHA256=hashlib.sha256(json.dumps(rust, sort_keys=True).encode()).hexdigest(),
                  scope='Cancel/retry/continue action visibility across required/optional states; no UI rendering or network execution')
    keys = ('cases', 'sources', 'corpusSHA256', 'resultSHA256')
    if args.write_reference:
        REFERENCE.write_text(json.dumps({k: report[k] for k in keys}, indent=2) + '\n')
    reference = json.loads(REFERENCE.read_text())
    for key in keys:
        assert reference[key] == report[key], f'Model gate reference differs: {key}'
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
