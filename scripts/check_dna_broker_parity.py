#!/usr/bin/env python3
"""Compare native DNA scheduling, wire normalization and timeout policy to Swift.

Compiles the complete unmodified shipping broker with a no-op diagnostic sink.
This pure oracle starts no model processes; real-child lifecycle tests and Metal
smoke are separate. Portable mode checks the pinned native Swift result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/dna-broker-parity'
REFERENCE = ROOT / 'design/parity/dna-broker-reference.json'
SOURCES = [ROOT / f'apps/macos/Sovereign/Engine/{name}.swift' for name in
           ('DNAEngineBroker', 'DNATurnBudget', 'TranslateStreamParser')]


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')


def cases():
    result = []
    for engine in ('translate-engine-2b', '/bundle/translate-engine-4b', 'unknown', 'translate-engine-2b.exe'):
        for count in (-1, 0, 1, 119, 1024, 24000, 1000000):
            for steps in (-1, 0, 1, 512, 100000):
                result.append(dict(kind='budget', bytes=count, steps=steps, engine=engine))
    rng = random.Random(2026110501)
    for _ in range(512):
        result.append(dict(kind='select', pressure=rng.choice([-1, 0, 1, 6, 999]),
                           aging=rng.choice([0, 90, 120]), items=[
                               [rng.choice([0, 10, 30, 79, 80, 100, 101]), rng.randrange(10),
                                rng.choice([-1, 0, 89.999, 90, 90.001, 120])]
                               for _ in range(rng.randrange(20))]))
    whitespace = '\t\n\r\v\f \u0085\u00a0\u1680\u2000\u200b\u2028\u2029\u202f\u205f\u3000'
    for edge in whitespace:
        for text in ('', '안녕\nworld\r\n日', 'cafe\u0301', 'x\u0000y', '%%PFX 3 %%FP fixed', '👩🏽‍💻'):
            result.append(dict(kind='line', text=edge + text + edge))
    for text in ('', '0', '-1', '200', '0.5', '2e3', '1e-3', ' 200', '200 ', 'hello', '200ms', '+250'):
        result.append(dict(kind='override', text=text))
    return result


DRIVER = r'''
@MainActor final class DebugLog {
    static var shared: DebugLog? = nil
    func emit(_ lane: String, _ event: String, _ fields: [String: Any]) {}
}
extension DNAEngineBroker {
    func normalizedForOracle(_ text: String) -> String { oneLine(text) }
}
@main struct Main {
    @MainActor static func main() throws {
        let cases = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String: Any]]
        let broker = DNAEngineBroker()
        var results: [Any] = []
        for c in cases {
            switch c["kind"] as! String {
            case "budget":
                let value = DNATurnBudget.seconds(promptBytes: c["bytes"] as! Int, steps: c["steps"] as! Int,
                    rates: DNATurnBudget.rates(forEnginePath: c["engine"] as! String))
                results.append(String(format: "%016llx", value.bitPattern))
            case "select":
                let items = (c["items"] as! [[NSNumber]]).map { (priority: $0[0].intValue, sequence: $0[1].uint64Value, waitedSeconds: $0[2].doubleValue) }
                let index = DNAEngineBroker.eligibleIndex(items, captionPressure: c["pressure"] as! Int, aging: c["aging"] as! Double)
                results.append(index.map { $0 as Any } ?? NSNull())
            case "line": results.append(broker.normalizedForOracle(c["text"] as! String))
            case "override":
                let value = DNATurnBudget.override(["MADI_DNA_TIMEOUT_MS": c["text"] as! String])
                results.append(value.map { String(format: "%016llx", $0.bitPattern) as Any } ?? NSNull())
            default: fatalError("unexpected case")
            }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .fragmentsAllowed]))
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only', action='store_true')
    parser.add_argument('--write-reference', action='store_true')
    args = parser.parse_args()
    if args.write_reference and args.rust_only:
        parser.error('Native Swift is required to write reference')
    if not args.rust_only and platform.system() != 'Darwin':
        parser.error('Native Swift requires macOS')
    OUT.mkdir(parents=True, exist_ok=True)
    corpus = cases()
    payload = encoded(corpus)
    (OUT / 'cases.json').write_bytes(payload)
    subprocess.run([os.environ.get('CARGO', 'cargo'), 'build', '--locked', '-p', 'madi-core', '--example', 'dna_policy_oracle'], cwd=ROOT, check=True)
    binary = ROOT / 'target/debug/examples' / ('dna_policy_oracle.exe' if os.name == 'nt' else 'dna_policy_oracle')
    actual = json.loads(subprocess.check_output([str(binary)], input=payload))
    (OUT / 'result.json').write_bytes(encoded(actual))
    if not args.rust_only:
        driver = OUT / 'DNAOracle.swift'
        # Same-file extension grants access to oneLine; the shipping source is
        # concatenated verbatim, and the diagnostic sink has no product effects.
        driver.write_text(SOURCES[0].read_text(encoding='utf-8') + '\n' + DRIVER, encoding='utf-8')
        native = OUT / 'swift-oracle'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(driver), *map(str, SOURCES[1:]), '-o', str(native)], check=True)
        expected = json.loads(subprocess.check_output([str(native)], input=payload))
        (OUT / 'swift.json').write_bytes(encoded(expected))
        for index, (case, want, got) in enumerate(zip(corpus, expected, actual, strict=True)):
            assert want == got, json.dumps(dict(index=index, case=case, swift=want, rust=got), ensure_ascii=False)
    report = dict(cases=len(corpus), corpusSHA256=hashlib.sha256(payload).hexdigest(),
                  resultSHA256=hashlib.sha256(encoded(actual)).hexdigest(),
                  sources={p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES})
    if args.write_reference:
        REFERENCE.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    else:
        assert report == json.loads(REFERENCE.read_text(encoding='utf-8')), 'DNA broker reference changed'
    report.update(status='passed', nativeSwiftRun=not args.rust_only,
                  scope='Broker priority/pressure/FIFO selection, normalized wire text and watchdog budgets; process lifetime tested separately')
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
