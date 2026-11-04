#!/usr/bin/env python3
"""Compare glossary restoration/mutations with unchanged shipping Swift sources."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import random
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/glossary-parity'
REFERENCE = ROOT / 'design/parity/glossary-reference.json'
STORE = ROOT / 'apps/macos/Sovereign/Transcript/GlossaryStore.swift'
VIEW = ROOT / 'apps/macos/Sovereign/UI/GlossarySettingsView.swift'


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def corpus():
    queries = ['오픈소스', '회의록', 'éclair', 'e\u0301clair', '가나다', '가나다', '', 'unknown']
    operations = [dict(kind='learn', wrong='오픈소스', right='오픈소스'),
                  dict(kind='learn', wrong='', right='교정'),
                  dict(kind='learn', wrong='회의록', right=''),
                  dict(kind='learn', wrong='회의록', right='회의실'),
                  dict(kind='learn', wrong='회의록', right='회의실'),
                  dict(kind='learn', wrong='회의록', right='회의내용'),
                  dict(kind='learn', wrong='e\u0301clair', right='크레페'),
                  dict(kind='learn', wrong='éclair', right='크레페'),
                  dict(kind='learn', wrong='가나다', right='가나다'),
                  dict(kind='enabled', enabled=True), dict(kind='minHits', minHits=3),
                  dict(kind='enabled', enabled=False), dict(kind='forget', wrong='éclair'),
                  dict(kind='forget', wrong='unknown'), dict(kind='clear')]
    values = [None, 'null', '[]', '42', '"text"', '{', '{}']
    for version in [None, -2, 0, 1, 2, 3, 2.0, 1.5, '2', True, 9223372036854775807, 9223372036854775808]:
        for minimum in [None, -3, 0, 1, 2, 5, 3.0, 2.5, '2', True]:
            values.append(json.dumps(dict(schemaVersion=version, minHits=minimum, enabled=True)))
    for field in ['enabled', 'entries']:
        for value in [None, False, True, 0, 1, 'yes', [], {}]:
            values.append(json.dumps({field: value}))
    for field in ['wrong', 'right', 'hits']:
        for value in [None, '', 'word', 0, -5, 1, 2.0, 1.5, True, [], {}, 9223372036854775807]:
            values.append(json.dumps(dict(schemaVersion=2, entries={'회의록': {field: value}})))
    values.append(json.dumps(dict(schemaVersion=2, entries={'회의록': dict(wrong='회의록', right='회의실', hits=2), '오픈소스': dict(wrong='오픈소스', right='오픈쏘스', hits=4)})))
    for number in ['-9223372036854775809', '-9223372036854775808', '9223372036854775806', '9223372036854775807', '9223372036854775808', '-9223372036854775809.0', '-9223372036854775808.0', '9223372036854775807.0', '-9.223372036854775809e18', '1e3', '-1e3', '1e100', '-1e100', '1.0000000000000001']:
        values.append('{"schemaVersion":2,"minHits":' + number + '}')
    # Avoid learning into Int.max: Swift traps there; the Rust owner rejects it.
    cases = [dict(raw=raw, operations=operations if '92233720368547758' not in (raw or '') else [], queries=queries) for raw in values]
    rng = random.Random(527195)
    words = ['회의록', '오픈소스', 'éclair', 'e\u0301clair', '가나다', '가나다', 'Alpha', 'Ωμέγα', '👩‍💻개발', '']
    for _ in range(60):
        ops = []
        for _ in range(35):
            kind = rng.choice(['learn'] * 6 + ['enabled', 'minHits', 'forget', 'clear'])
            if kind == 'learn': op = dict(kind=kind, wrong=rng.choice(words), right=rng.choice(words))
            elif kind == 'enabled': op = dict(kind=kind, enabled=bool(rng.randrange(2)))
            elif kind == 'minHits': op = dict(kind=kind, minHits=rng.randrange(-2, 7))
            elif kind == 'forget': op = dict(kind=kind, wrong=rng.choice(words))
            else: op = dict(kind=kind)
            ops.append(op)
        cases.append(dict(raw=None, operations=ops, queries=words))
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only', action='store_true')
    parser.add_argument('--write-reference', action='store_true')
    args = parser.parse_args()
    if args.write_reference and args.rust_only: parser.error('Reference requires live Swift')
    if not args.rust_only and platform.system() != 'Darwin': parser.error('Live Swift requires macOS')
    OUT.mkdir(parents=True, exist_ok=True)
    cases = corpus()
    payload = canonical(cases)
    subprocess.run(['cargo', 'build', '--locked', '-p', 'madi-core', '--example', 'glossary_oracle'], cwd=ROOT, check=True)
    executable = ROOT / 'target/debug/examples' / ('glossary_oracle.exe' if platform.system() == 'Windows' else 'glossary_oracle')
    rust = json.loads(subprocess.check_output([str(executable)], input=payload, cwd=ROOT))
    (OUT / 'rust.json').write_bytes(canonical(rust))
    if not args.rust_only:
        # The Settings row order is compiled from its original computed property.
        body = VIEW.read_text().split('private var entries: [GlossaryEntry] {', 1)[1].split('private var totalCount:', 1)[0]
        body = body.rsplit('}', 1)[0].replace('session.glossary.entries', 'entries')
        extension = OUT / 'GlossaryDisplay.swift'
        extension.write_text('extension Glossary { var parityDisplayEntries: [GlossaryEntry] {' + body + '} }\n')
        oracle = OUT / 'swift-oracle'
        subprocess.run(['swiftc', str(STORE), str(extension), str(ROOT / 'tests/parity/GlossaryOracle.swift'), '-o', str(oracle)], check=True)
        swift = json.loads(subprocess.check_output([str(oracle)], input=payload))
        (OUT / 'swift.json').write_bytes(canonical(swift))
        for index, (expected, actual) in enumerate(zip(swift, rust, strict=True)):
            assert expected == actual, f'Glossary mismatch case {index}: inspect out/glossary-parity/{{swift,rust}}.json'
    report = dict(cases=len(cases), states=sum(1 + len(c['operations']) for c in cases),
                  corpusSHA256=digest(payload), resultSHA256=digest(canonical(rust)),
                  sources={path.relative_to(ROOT).as_posix(): digest(path.read_bytes()) for path in [STORE, VIEW]})
    if args.write_reference:
        REFERENCE.write_text(json.dumps(report, indent=2) + '\n')
    else:
        assert report == json.loads(REFERENCE.read_text()), 'Pinned glossary reference changed'
    report.update(status='passed', nativeSwiftRun=not args.rust_only,
                  scope='Glossary storage, schema restoration and mutations only; no matcher, learning integration, persistent owner or Settings UI')
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
