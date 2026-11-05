#!/usr/bin/env python3
"""Compare fragment grouping, sentence boundaries and language routing to Swift."""
import argparse
import hashlib
import json
import os
import platform
import random
import subprocess
from pathlib import Path
from check_asr_config_parity import block

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/committed-translation-parity'
REFERENCE = ROOT / 'design/parity/committed-translation-reference.json'
SOURCES = [ROOT / 'apps/macos/Sovereign' / p for p in ('Transcript/TranslationCoalescer.swift', 'Engine/TranslateStreamParser.swift')]

def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')

def cases():
    rng = random.Random(2026110504)
    texts = ['', ' ', '\n', '\r\n', 'one', 'one two.', 'one two three.', 'one two three', 'a\tb\tc', 'a\r\nb c',
             'go.\n', 'go.\u200b', 'go.\u0301', '한글 English', '漢한', '漢漢한', '漢字かな', '1234', 'café', 'cafe\u0301',
             'a' * 219, 'a' * 220, 'a' * 221, '👩🏽\u200d💻' * 220, '말。', '말！', '말？', '말…']
    rows = []
    for i in range(360):
        lines = []
        end = 0.0
        for index in range(rng.randrange(0, 45)):
            start = end + rng.choice([-1, 0, 2.999999999, 3, 3.000000001, 4])
            end = start + rng.choice([0, 0.5, 2])
            lines.append(dict(id=f'00000000-0000-0000-0000-{index:012x}', speaker=rng.choice([0, 1, 2, 255]), text=rng.choice(texts), start=start, end=end, undecided=rng.choice([True, False])))
        rows.append(dict(text=texts[i % len(texts)], maxWords=rng.choice([0, 1, 2, 3]), softMaxWords=rng.choice([1, 3, 5]), lines=lines, maxGap=rng.choice([-1, 0, 3, 5]), deferTrailing=bool(i % 2)))
    return rows

SWIFT = r'''
struct Case: Decodable {
    struct Line: Decodable { let id: UUID; let speaker: Int; let text: String; let start: Double; let end: Double; let undecided: Bool }
    let text: String; let maxWords: Int; let softMaxWords: Int; let lines: [Line]; let maxGap: Double; let deferTrailing: Bool
}
@main struct Main {
    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let result: [[String: Any]] = cases.map { c in
            let lines = c.lines.map { TranslationCoalescer.Input(id: $0.id, speaker: $0.speaker, text: $0.text, start: $0.start, end: $0.end, undecided: $0.undecided) }
            let runs = TranslationCoalescer.runs(lines, maxGap: c.maxGap, deferTrailing: c.deferTrailing).map {
                ["anchor": $0.anchor.uuidString.lowercased(), "members": $0.members.map { $0.uuidString.lowercased() }, "text": $0.text] as [String: Any]
            }
            return ["fragment": TranslationCoalescer.isFragment(c.text, maxWords: c.maxWords, softMaxWords: c.softMaxWords), "endsSentence": TranslationCoalescer.endsSentence(c.text), "language": TranslateRouting.scriptLang(of: c.text) as Any? ?? NSNull(), "runs": runs]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    }
}
'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only', action='store_true')
    parser.add_argument('--write-reference', action='store_true')
    args = parser.parse_args()
    if args.write_reference and args.rust_only:
        parser.error('Native Swift is required to write references')
    if not args.rust_only and platform.system() != 'Darwin':
        parser.error('Native Swift requires macOS')
    OUT.mkdir(parents=True, exist_ok=True)
    corpus = cases()
    payload = encoded(corpus)
    (OUT / 'cases.json').write_bytes(payload)
    subprocess.run([os.environ.get('CARGO', 'cargo'), 'build', '--locked', '-p', 'madi-core', '--example', 'committed_translation_oracle'], cwd=ROOT, check=True)
    binary = ROOT / 'target/debug/examples' / ('committed_translation_oracle.exe' if os.name == 'nt' else 'committed_translation_oracle')
    actual = json.loads(subprocess.check_output([str(binary)], input=payload))
    (OUT / 'result.json').write_bytes(encoded(actual))
    if not args.rust_only:
        driver = OUT / 'CommittedOracle.swift'
        driver.write_text('import Foundation\n' + block(SOURCES[1].read_text(encoding='utf-8'), 'enum TranslateRouting {') + '\n' + SWIFT, encoding='utf-8')
        native = OUT / 'swift-oracle'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(driver), str(SOURCES[0]), '-o', str(native)], check=True)
        expected = json.loads(subprocess.check_output([str(native)], input=payload))
        (OUT / 'swift.json').write_bytes(encoded(expected))
        for i, (want, got) in enumerate(zip(expected, actual, strict=True)):
            assert want == got, json.dumps(dict(case=i, input=corpus[i], swift=want, rust=got), ensure_ascii=False, indent=2)
    report = dict(cases=len(corpus), lines=sum(len(c['lines']) for c in corpus), corpusSHA256=hashlib.sha256(payload).hexdigest(), resultSHA256=hashlib.sha256(encoded(actual)).hexdigest(), sources={s.relative_to(ROOT).as_posix(): hashlib.sha256(s.read_bytes()).hexdigest() for s in SOURCES})
    if args.write_reference:
        REFERENCE.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    else:
        assert report == json.loads(REFERENCE.read_text(encoding='utf-8')), 'Committed translation reference changed'
    report.update(status='passed', nativeSwiftRun=not args.rust_only, scope='Unchanged TranslationCoalescer and extracted unchanged TranslateRouting; session callbacks tested separately')
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
