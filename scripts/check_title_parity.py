#!/usr/bin/env python3
"""Compare Rust title policy to the unchanged shipping Swift implementation."""
import hashlib
import itertools
import json
from pathlib import Path
import platform
import random
import subprocess
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/title-parity'
SOURCE = ROOT / 'apps/macos/Sovereign/Transcript/TitleGenerator.swift'


def corpus():
    bodies = ['주간 회의', '주간 회의', 'Sprint plan', '中文 会議', '회의 👩‍💻',
              'a / b : c', '../', '***', '', '🙂', '\u0301', 'Ⅳ', '²', '١٢٣',
              '가' * 60, '👩‍💻한' * 30, 'a' * 23 + ' next', '漢字' * 20]
    labels = ['', '제목:', '제목 :', '제목:', 'Title:', 'TITLE :', 'title :', '# 제목:']
    wrappers = [('', ''), ('**', '**'), ('“', '”'), ('\n\n', '\n설명'),
                ('\r\n', '\r\n설명'), ('\u200b', '\u200b'), ('[', ']')]
    cases = [prefix + label + ' ' + body + suffix
             for label, body, (prefix, suffix) in itertools.product(labels, bodies, wrappers)]
    spaces = [' ', '\t', '\n', '\r', '\r\n', '\v', '\f', '\u0085', '\u00a0',
              '\u1680', '\u180e', '\u2000', '\u200b', '\u2028', '\u2029',
              '\u202f', '\u205f', '\u3000', '\ufeff', ' \u0301', '\r\n\u0301']
    cases += [s + '한' + s + '글' + s for s in spaces]
    rng = random.Random(11222026)
    atoms = bodies + labels + spaces + ['/', '\\', ':', '*', '?', '"', '<', '>', '|',
                                      '\0', '\x01', '—', '…', '🇰🇷', '\u200d', '\ufe0f']
    for _ in range(1500):
        text = ''.join(rng.choice(atoms) for _ in range(rng.randrange(1, 15)))
        cases.extend([text, unicodedata.normalize('NFD', text)])
    return cases


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def main():
    if platform.system() != 'Darwin':
        raise SystemExit('Live title comparison requires macOS Foundation')
    OUT.mkdir(parents=True, exist_ok=True)
    inputs = corpus()
    payload = encoded(inputs)
    subprocess.run(['cargo', 'build', '--locked', '-p', 'madi-platform', '--example', 'title_oracle'],
                   cwd=ROOT, check=True)
    metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--no-deps', '--format-version', '1'], cwd=ROOT))
    executable = Path(metadata['target_directory']) / 'debug/examples/title_oracle'
    rust = json.loads(subprocess.check_output([str(executable)], input=payload))
    subprocess.run(['swiftc', str(SOURCE), str(ROOT / 'tests/parity/TitleOracle.swift'),
                    '-o', str(OUT / 'swift-oracle')], check=True)
    swift = json.loads(subprocess.check_output([str(OUT / 'swift-oracle')], input=payload))
    (OUT / 'rust.json').write_bytes(encoded(rust))
    (OUT / 'swift.json').write_bytes(encoded(swift))
    mismatches = [{'index': i, 'input': inputs[i], 'expected': expected, 'actual': actual}
                  for i, (expected, actual) in enumerate(zip(swift, rust, strict=True)) if expected != actual]
    (OUT / 'mismatches.json').write_bytes(encoded(mismatches))
    source_paths = [SOURCE, ROOT / 'tests/parity/TitleOracle.swift',
                    ROOT / 'crates/madi-core/src/title.rs', ROOT / 'crates/madi-platform/src/title.rs']
    report = {'status': 'passed' if not mismatches else 'failed', 'cases': len(inputs),
              'mismatches': len(mismatches), 'corpusSHA256': hashlib.sha256(payload).hexdigest(),
              'resultSHA256': hashlib.sha256(encoded(rust)).hexdigest(),
              'sources': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths},
              'scope': 'Native macOS title sanitization and prompt only; final AI generation/rename are not connected.'}
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))
    raise SystemExit(bool(mismatches))


if __name__ == '__main__':
    main()
