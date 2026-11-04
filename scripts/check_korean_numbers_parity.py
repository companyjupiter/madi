#!/usr/bin/env python3
"""Compare counter formatting and both number parsers with unchanged Swift."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import platform
import random
import re
import subprocess
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/korean-numbers-parity'
REFERENCE = ROOT / 'design/parity/korean-numbers-reference.json'
SOURCE = ROOT / 'apps/macos/Sovereign/Transcript/KoreanNumberFormatter.swift'
TESTS = [ROOT / 'apps/macos/Tests/SovereignCoreTests' / name for name in [
    'KoreanNumberFormatterTests.swift', 'KoreanNumberFormatterGuard5Tests.swift']]


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def corpus():
    cases = []
    def add(name, text): cases.append(dict(name=name, text=text))
    # Include every simple string literal used by the shipping guard tests,
    # including parser inputs and growth prefixes, without copying their code.
    for test in TESTS:
        for index, text in enumerate(re.findall(r'"([^"\\]*)"', test.read_text(encoding="utf-8"))):
            add(test.stem + '-' + str(index), text)
    hard = ['년대', '개월', '시간', '년', '월', '일', '시', '분', '초']
    soft = ['퍼센트', '명', '원', '개', '％', '%', '세', '살', '호']
    numbers = ['영', '공', '일', '이', '삼', '사', '오', '육', '륙', '칠', '팔', '구', '십', '백', '천', '만', '억', '영십', '이십일', '천구백사십', '이만삼천', '억만', '십십', '열', '스물', '스무', '서른', '마흔', '쉰', '예순', '일흔', '여든', '아흔', '한', '두', '세', '네', '다섯', '여섯', '일곱', '여덟', '아홉', '열한', '스물세', '셋', '하나']
    for index, (number, counter, space) in enumerate(itertools.product(numbers, hard + soft + ['번', '차', '등', '위', '도', '장', '대'], ['', ' '])):
        add('counter-' + str(index), number + space + counter)
    for index, (number, ending) in enumerate(itertools.product(['오', '사', '일', '구', '이', '삼', '두', '열한', '오십'], list('에까부반쯤경로전후넘정간마대께도면는나라고니이오옵십시') + ['', ' ', '.', '👩‍💻', '\u0301', '가'])):
        add('time-ending-' + str(index), number + '시' + ending)
    spaces = [' ', '  ', '\t', '\r', '\n', '\r\n', '\v', '\f', '\u0085', '\u00a0', '\u1680', '\u180e', '\u2000', '\u2007', '\u200a', '\u200b', '\u2028', '\u2029', '\u202f', '\u205f', '\u3000', '\ufeff', ' \u0301']
    for index, (space, number, counter) in enumerate(itertools.product(spaces, ['삼', '삼십', '열한', '스물세'], ['년', '시', '명'])):
        add('whitespace-' + str(index), number + space + counter)
    prefixes = ['', '가', '힣', '0', '9', '９', '١', 'A', 'é', '가', 'ㄱ', '👩‍💻', '\u0301', '\n', '가삼 ', '1삼 ', '가삼\t', '가삼\r\n']
    for index, (prefix, body) in enumerate(itertools.product(prefixes, ['일월', '삼 년', '십삼 명', '열한시', '오십시오', '이 년', '두시', '한 일'])):
        add('boundary-' + str(index), prefix + body)
    for index, text in enumerate(numbers + ['스물세abc', '열두\u0301', '한\u0301', '열\u0301한', '스무아홉', '오\u0301', '', '백구천억일만삼천칠십일', '가삼 일월', '가삼 이 년 오분', '삼년오분', '십일월', '삼년\u0301', '삼\u0301년', '삼년\u200d', '삼년\ufe0f']):
        add('unicode-raw-' + str(index), text)
        add('unicode-nfd-' + str(index), unicodedata.normalize('NFD', text))
        add('unicode-counter-' + str(index), unicodedata.normalize('NFD', text) + '년')
    rng = random.Random(112304)
    atoms = numbers + hard + soft + prefixes + spaces + ['오시면', '시옵소서', '구시가지', '이번', '.', '년\u0301']
    for index in range(2000):
        add('mixed-' + str(index), ''.join(rng.choice(atoms) for _ in range(rng.randrange(1, 15))))
    for index in range(500):
        add('sino-parser-' + str(index), ''.join(rng.choice('영공일이삼사오육륙칠팔구십백천만억') for _ in range(rng.randrange(20))))
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only', action='store_true')
    parser.add_argument('--write-reference', action='store_true')
    args = parser.parse_args()
    if args.write_reference and args.rust_only: parser.error('Reference requires live Swift')
    if not args.rust_only and platform.system() != 'Darwin': parser.error('Live Swift requires macOS')
    OUT.mkdir(parents=True, exist_ok=True)
    cases = corpus(); payload = encoded(cases)
    subprocess.run(['cargo', 'build', '--locked', '-p', 'madi-core', '--example', 'korean_numbers_oracle'], cwd=ROOT, check=True)
    executable = ROOT / 'target/debug/examples' / ('korean_numbers_oracle.exe' if platform.system() == 'Windows' else 'korean_numbers_oracle')
    rust = json.loads(subprocess.check_output([str(executable)], input=payload, cwd=ROOT))
    (OUT / 'rust.json').write_bytes(encoded(rust))
    if not args.rust_only:
        executable = OUT / 'swift-oracle'
        subprocess.run(['swiftc', str(SOURCE), str(ROOT / 'tests/parity/KoreanNumbersOracle.swift'), '-o', str(executable)], check=True)
        swift = json.loads(subprocess.check_output([str(executable)], input=payload))
        (OUT / 'swift.json').write_bytes(encoded(swift))
        mismatches = [(cases[i], expected, actual) for i, (expected, actual) in enumerate(zip(swift, rust, strict=True)) if expected != actual]
        assert not mismatches, f'{len(mismatches)} Korean number mismatches; first: {mismatches[:3]!r}; inspect out/korean-numbers-parity/{{swift,rust}}.json'
    report = dict(cases=len(cases), corpusSHA256=sha(payload), resultSHA256=sha(encoded(rust)),
                  sources={path.relative_to(ROOT).as_posix(): sha(path.read_bytes()) for path in [SOURCE, *TESTS]})
    if args.write_reference: REFERENCE.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    else: assert report == json.loads(REFERENCE.read_text(encoding="utf-8")), 'Pinned Korean number reference changed'
    report.update(status='passed', nativeSwiftRun=not args.rust_only,
                  scope='Counter formatting, repeated passes, Sino/native parsing and ambiguity guards; not rendered UI or inference accuracy.')
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
