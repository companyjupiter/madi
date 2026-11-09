#!/usr/bin/env python3
"""Compare personal vocabulary matching and prompts to unchanged shipping Swift."""
import argparse
import copy
import hashlib
import itertools
import json
from pathlib import Path
import platform
import random
import subprocess
import unicodedata
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/personal-vocabulary-parity'
REFERENCE = ROOT / 'design/parity/personal-vocabulary-reference.json'
BASE = ROOT / 'apps/macos/Sovereign/Transcript'
SOURCES = [BASE / name for name in ['PersonalVocabulary.swift', 'GlossaryStore.swift', 'TranscriptStore.swift']]


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def comparable(cases, results):
    """Swift dictionary order leaves equivalent-spelling prompt ties unspecified.

    Normalize only those tied output terms for the reference, and require the
    actual bytes to be one of their source spellings. All other text stays exact.
    """
    values = copy.deepcopy(results)
    affected = []
    whitespace = ''.join(chr(value) for value in [*range(9, 14), 32, 133, 160, 5760, *range(8192, 8204), 8232, 8233, 8239, 8287, 12288])
    for case, result in zip(cases, values, strict=True):
        groups = {}
        for entry in case['glossary']['entries'].values():
            groups.setdefault((entry['hits'], unicodedata.normalize('NFC', entry['right'])), set()).add(entry['right'])
        ambiguous = {}
        for spellings in groups.values():
            if len(spellings) > 1:
                trimmed = {term.strip(whitespace) for term in spellings}
                ambiguous[unicodedata.normalize('NFC', next(iter(trimmed)))] = trimmed
        changed = False
        for index, term in enumerate(result['bias']):
            canonical = unicodedata.normalize('NFC', term)
            if canonical in ambiguous:
                assert term in ambiguous[canonical], 'Bias term must retain an original tied spelling'
                result['bias'][index] = canonical
                changed = True
        if changed: affected.append(case['name'])
    return values, affected


def corpus():
    particles = ['한테서', '이라고', '으로', '에게', '에서', '부터', '까지', '처럼', '보다', '께서', '한테', '이랑', '라고', '은', '는', '이', '가', '을', '를', '와', '과', '의', '에', '께', '로', '도', '만', '랑']
    queries = ['', '.', 'ab', 'abc', '소버림', '소버린', '회의록', '회의실', '사과', 'AWS', '쿠버네티스', '쿠버네티쓰', 'microservice', 'microservise', 'éclair', 'e\u0301clair', 'ΟΣ', 'İSTANBUL', '👩‍💻개발자', '👩‍👩‍👧‍👦팀원', '가나다', '가나다', ' 용어 ', '용어\t가', '용어\u200b가', '가나\u0345', '가나\u0301', '123', 'ㄱㄴㄷ', '각', 'カナ字', '한글API']
    queries += ['소버림' + particle for particle in particles]
    queries += [unicodedata.normalize('NFD', '소버림에게'), '\u200b“소버림,”\u200b', ' (소버림);', '소버림, ', '소버림!\u0301', '소버림...']
    pairs = [('소버림은 좋아요', '소버린은 좋아요'), ('쿠버는 좋아요', '쿠버네티스는 좋아요'), ('소버림', '이 소버린'), ('소버림', 'A'), ('소버림은', '소버린에게'), ('회의록을 봅니다', '회의실을 봅니다'), ('AWS API', 'aws api'), ('e\u0301clair', 'éclair'), ('', ''), ('a', 'b'), ('ab', 'ba'), ('martha', 'marhta'), ('dwayne', 'duane'), ('dixon', 'dicksonx')]
    for space in [' ', '\t', '\r\n', '\u0085', '\u00a0', '\u200b', '\u2028', '\u3000', ' \u0301']:
        pairs.append(('소버림' + space + '좋아요', '소버린' + space + '좋아요'))
    cases = []
    def case(name, entries, enabled=True, minimum=2, qs=None, ps=None, confs=None, edited=None):
        qs = queries if qs is None else qs
        ps = pairs if ps is None else ps
        confs = [.1, .7999999999999999, .8, 1.0] if confs is None else confs
        words = [dict(id=str(uuid.UUID(int=i + 1)), t0=i * .5, t1=i * .5 + .4, text=text, conf=confs[i % len(confs)]) for i, text in enumerate(qs)]
        cases.append(dict(name=name, glossary=dict(schemaVersion=2, enabled=enabled, minHits=minimum, entries={wrong: dict(wrong=wrong, right=right, hits=hits) for wrong, right, hits in entries}), queries=qs, pairs=[dict(before=a, after=b) for a, b in ps], words=words, editedText=edited))
    base = [('소버림', '소버린', 2), ('회의록', '회의실', 4), ('쿠버네티스', '쿠버네티즈', 3), ('microservice', 'service', 8), ('éclair', '크레페', 5), ('가나다', '라마바', 2)]
    for enabled, minimum, edited in itertools.product([False, True], [-1, 0, 1, 2, 5], [None, '', '수동 교정']):
        case(f'baseline-{enabled}-{minimum}-{edited}', base, enabled=enabled, minimum=minimum, edited=edited)
    for particle in particles:
        case('particle-' + particle, [('소버림', '소버린', 2), ('다른말', '소버린' + particle, 2)], qs=['소버림' + particle, '다른말' + particle, '소버림' + particle + ','], ps=[('소버림' + particle, '소버린' + particle)])
    for conf in [-1, 0, .7999999999999999, .8, .8000000000000002, 2]:
        case('confidence-' + str(conf), base, confs=[conf])
    case('bias-count', [(f'w{i}', f'용어{i}', 200 - i) for i in range(100)])
    for length in [298, 299, 300, 898, 899, 900]:
        case('bias-length-' + str(length), [('first', '가' * length, 8), ('second', '나' * length, 7), ('third', '다' * length, 6), ('last', '소버린', 5)])
    case('bias-filter', [(f'w{i}', value, 100 - i) for i, value in enumerate(queries + [' 가나 ', '소버린', '소버린 ', '용어\n가', '🧑‍💻한글', '용어①', '용어́'])])
    case('full-surface-before-stem', [('소버림', '줄기', 2), ('소버림에게', '표면우선', 3)], qs=['소버림에게', '소버림에게!'])
    rng = random.Random(371129)
    tokens = ['소버림', '소버린', '회의록', '회의실', '쿠버네티스', '쿠버네티쓰', 'microservice', 'microservise', 'e\u0301clair', 'éclair', '가나다', '가나다', '👩‍💻개발자', 'abcdefg', 'abcxefg', '한글용어', '한글단어']
    for index in range(120):
        keys = {}
        for _ in range(12):
            wrong = rng.choice(tokens)
            keys[unicodedata.normalize('NFC', wrong)] = (wrong, rng.choice(tokens), rng.randrange(1, 6))
        qs = [rng.choice(tokens) + rng.choice(['', ',', '에게', '...']) for _ in range(20)]
        ps = [(rng.choice(tokens), rng.choice(tokens)) for _ in range(25)]
        case(f'random-{index}', list(keys.values()), minimum=rng.randrange(1, 5), qs=qs, ps=ps)
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
    subprocess.run(['cargo', 'build', '--locked', '-p', 'madi-core', '--example', 'personal_vocabulary_oracle'], cwd=ROOT, check=True)
    executable = ROOT / 'target/debug/examples' / ('personal_vocabulary_oracle.exe' if platform.system() == 'Windows' else 'personal_vocabulary_oracle')
    rust = json.loads(subprocess.check_output([str(executable)], input=payload, cwd=ROOT))
    (OUT / 'rust.json').write_bytes(encoded(rust))
    rust_comparable, ambiguous = comparable(cases, rust)
    if not args.rust_only:
        source = SOURCES[2].read_text()
        declarations = source[source.index('struct Word:'):source.index('/// Stable, process-independent')]
        declarations += source[source.index('enum SegmentStatus:'):source.index('@Observable')]
        model = OUT / 'TranscriptValues.swift'
        model.write_text('import Foundation\n' + declarations)
        executable = OUT / 'swift-oracle'
        subprocess.run(['swiftc', str(SOURCES[0]), str(SOURCES[1]), str(model), str(ROOT / 'tests/parity/PersonalVocabularyOracle.swift'), '-o', str(executable)], check=True)
        swift = json.loads(subprocess.check_output([str(executable)], input=payload))
        (OUT / 'swift.json').write_bytes(encoded(swift))
        swift_comparable, swift_ambiguous = comparable(cases, swift)
        assert ambiguous == swift_ambiguous
        for index, (expected, actual) in enumerate(zip(swift_comparable, rust_comparable, strict=True)):
            assert expected == actual, f'PersonalVocabulary mismatch case {index} ({cases[index]["name"]}); inspect out/personal-vocabulary-parity/{{swift,rust}}.json'
    report = dict(cases=len(cases), queries=sum(len(c['queries']) for c in cases), pairs=sum(len(c['pairs']) for c in cases),
                  corpusSHA256=sha(payload), resultSHA256=sha(encoded(rust_comparable)), canonicalBiasTieCases=ambiguous,
                  sources={path.relative_to(ROOT).as_posix(): sha(path.read_bytes()) for path in SOURCES})
    if args.write_reference: REFERENCE.write_text(json.dumps(report, indent=2) + '\n')
    else: assert report == json.loads(REFERENCE.read_text()), 'Pinned PersonalVocabulary reference changed'
    report.update(status='passed', nativeSwiftRun=not args.rust_only,
                  scope='Pure vocabulary learning/matching, display correction and prompt policy; native owner, file effects and UI remain separate')
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
