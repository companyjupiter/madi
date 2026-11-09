#!/usr/bin/env python3
"""Compare combined correction and stable-line policy to original Swift bodies."""
import argparse
import copy
import hashlib
import itertools
import json
from pathlib import Path
import platform
import random
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from check_transcript_store_parity import HOOK, SOURCES as STORE_SOURCES

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/text-passes-parity'
REFERENCE = ROOT / 'design/parity/text-passes-reference.json'
BASE = ROOT / 'apps/macos/Sovereign'
CONTROLLER = BASE / 'SessionController.swift'
SOURCES = [*STORE_SOURCES, *[BASE / 'Transcript' / name for name in
    ['PersonalVocabulary.swift', 'GlossaryStore.swift', 'KoreanNumberFormatter.swift']], CONTROLLER]


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def sha(data): return hashlib.sha256(data).hexdigest()


def corpus():
    cases = []
    def row(text, index):
        return [dict(id=str(uuid.UUID(int=1000 + index * 20 + i)), text=word, t0=index * 2 + i * .1,
                     t1=index * 2 + i * .1 + .09, conf=.2) for i, word in enumerate(text.split(' '))]
    def load(texts): return dict(op='rows', rows=[row(text, i) for i, text in enumerate(texts)])
    def case(name, steps): cases.append(dict(name=name, steps=copy.deepcopy(steps)))
    learn = [dict(op='learn', text='소버림', right='소버린')] * 2
    texts = ['소버림 천구백사십년', '오시면 안녕하세요', '열한시 삼십오분', '소버림 팔월', '끝입니다']
    for enabled, targets, edit in itertools.product([False, True], [False, True], [None, 'same', 'line', 'word', 'empty']):
        steps = [load(texts), *learn, dict(op='enabled', flag=enabled), dict(op='targets', flag=targets)]
        if edit:
            steps += [dict(op='editWord' if edit == 'word' else 'edit', index=0,
                           text={'same': texts[0], 'line': '수동 한시', 'word': '소버린', 'empty': ' ' }[edit])]
        steps += [dict(op='stable'), dict(op='stable'), dict(op='enabled', flag=not enabled),
                  dict(op='stable'), dict(op='all'), dict(op='all'), dict(op='stable', flag=True)]
        case(f'combined-{enabled}-{targets}-{edit}', steps)
    for count in [0, 1, 2, 31, 32, 33, 34, 65, 100]:
        steps = [load(['소버림 삼십분'] * count), dict(op='targets', flag=True), dict(op='enabled', flag=True),
                 dict(op='stable'), *learn, dict(op='stable'), dict(op='all'), dict(op='stable', flag=True)]
        case('scan-window-' + str(count), steps)
    for flag, partial in itertools.product([False, True], ['', '계속 이야기']):
        steps = [dict(op='targets', flag=flag), *learn, dict(op='enabled', flag=True)]
        for i, text in enumerate(['소버림', '팔월.', '삼십분', '뒤에.', '열한시', '약속입니다.', '오시면', '됩니다.']):
            steps += [dict(op='partial', text=partial), dict(op='word', word=dict(
                id=str(uuid.UUID(int=i + 1)), t0=i, t1=i + .4, text=text, conf=.2))]
            if i % 3 == 2: steps.append(dict(op='break'))
        steps += [dict(op='finish'), dict(op='reset'), dict(op='word', word=dict(
            id=str(uuid.UUID(int=1)), t0=0, t1=.4, text='소버림 오분', conf=.2)), dict(op='finish')]
        case(f'growth-{flag}-{partial}', steps)
    # A punctuated held word stays at the end of the previous row when the next
    # segment starts later. Preview must postpone that row until it clears.
    for partial in ['', '미완성']:
        steps = [dict(op='targets', flag=True), dict(op='word', word=dict(
            id=str(uuid.UUID(int=1)), t0=0, t1=.4, text='오분.', conf=1)), dict(op='break'),
            dict(op='partial', text=partial), dict(op='word', word=dict(
                id=str(uuid.UUID(int=2)), t0=4, t1=4.4, text='열한시.', conf=1)),
            dict(op='stable'), dict(op='partial', text=''), dict(op='stable'), dict(op='finish')]
        case('held-preview-' + partial, steps)
    # Preserve out-of-order timing as a separate merger/stable-scan interaction.
    for partial in ['', '미완성']:
        steps = [dict(op='targets', flag=True), dict(op='partial', text=partial)]
        for i, time in enumerate([0, 4, 2, 6, 8]):
            steps.append(dict(op='word', word=dict(id=str(uuid.UUID(int=i + 1)), t0=time,
                                                  t1=time + .4, text='오분.', conf=1)))
        steps += [dict(op='stable'), dict(op='break'), dict(op='finish')]
        case('held-' + partial, steps)
    rng = random.Random(513209)
    for i in range(100):
        choices = ['소버림 팔월', '이 년', '삼십분', '오시는 분', '열한시', '새로운 말', '천구백사십년', '가삼 일월', '소버림 오십분']
        steps = [load([rng.choice(choices) for _ in range(rng.randrange(2, 40))]), *learn]
        for _ in range(35):
            op = rng.choice(['targets', 'enabled', 'stable', 'all', 'edit', 'editWord', 'partial'])
            steps.append(dict(op=op, flag=rng.choice([False, True]), index=rng.randrange(40), text=rng.choice(choices)))
        steps += [dict(op='all'), dict(op='reset'), load(texts), dict(op='all')]
        case('mixed-' + str(i), steps)
    return cases


def swift_harness():
    controller = CONTROLLER.read_text(encoding="utf-8")
    start = controller.index('    private func translateStableLines(')
    end = controller.index('        lines = transcript.lines   // a pass may have rewritten line text', start)
    stable = controller[start:end] + '    }\n'
    start = controller.index('    private func applyTextPasses(')
    end = controller.index('\n    /// The source revision', start)
    apply = controller[start:end]
    # Exactly the source's pre-translation scan and complete combined pass.
    # Only translation dispatch is excluded; the original store is compiled too.
    return '''import Foundation
@MainActor final class TextPassHarness {
    let transcript = TranscriptStore()
    var glossary = Glossary()
    var translateTargets: Set<String> = []
    var livePartial = ""
    var stablePassHash: [UUID: Int] = [:]
    static let stableScanWindow = 32
    var userEditedLines: Set<UUID> = []
    func tick(_ includingLast: Bool) { translateStableLines(includingLast: includingLast) }
    func sweep() { for line in transcript.lines { applyTextPasses(line) } }
''' + stable + apply + '\n}\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only', action='store_true')
    parser.add_argument('--write-reference', action='store_true')
    args = parser.parse_args()
    if args.write_reference and args.rust_only: parser.error('Reference requires live Swift')
    if not args.rust_only and platform.system() != 'Darwin': parser.error('Live Swift requires macOS')
    OUT.mkdir(parents=True, exist_ok=True)
    cases = corpus(); payload = encoded(cases)
    subprocess.run(['cargo', 'build', '--locked', '-p', 'madi-core', '--example', 'text_passes_oracle'], cwd=ROOT, check=True)
    executable = ROOT / 'target/debug/examples' / ('text_passes_oracle.exe' if platform.system() == 'Windows' else 'text_passes_oracle')
    rust = json.loads(subprocess.check_output([str(executable)], input=payload, cwd=ROOT))
    (OUT / 'rust.json').write_bytes(encoded(rust))
    if not args.rust_only:
        source = OUT / 'OriginalTranscriptStore.swift'
        source.write_text(STORE_SOURCES[0].read_text(encoding="utf-8") + HOOK, encoding="utf-8")
        harness = OUT / 'TextPassHarness.swift'; harness.write_text(swift_harness(), encoding="utf-8")
        stubs = OUT / 'Diagnostics.swift'
        original = (ROOT / 'tests/parity/TranscriptStoreOracle.swift').read_text(encoding="utf-8")
        stubs.write_text(original[:original.index('struct InputWord:')], encoding='utf-8')
        executable = OUT / 'swift-oracle'
        subprocess.run(['swiftc', '-parse-as-library', str(source), *[str(path) for path in SOURCES[1:-1]],
                        str(harness), str(stubs), str(ROOT / 'tests/parity/TextPassesOracle.swift'), '-o', str(executable)], check=True)
        swift = json.loads(subprocess.check_output([str(executable)], input=payload))
        (OUT / 'swift.json').write_bytes(encoded(swift))
        for case, expected, actual in zip(cases, swift, rust, strict=True):
            for index, (a, b) in enumerate(zip(expected, actual, strict=True)):
                assert a == b, f'Text pass mismatch {case["name"]} step {index} {case["steps"][index]}; inspect out/text-passes-parity/{{swift,rust}}.json'
    report = dict(cases=len(cases), snapshots=sum(map(len, rust)), corpusSHA256=sha(payload), resultSHA256=sha(encoded(rust)),
                  sources={path.relative_to(ROOT).as_posix(): sha(path.read_bytes()) for path in SOURCES})
    if args.write_reference: REFERENCE.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    else: assert report == json.loads(REFERENCE.read_text(encoding="utf-8")), 'Pinned text-pass reference changed'
    report.update(status='passed', nativeSwiftRun=not args.rust_only,
                  scope='Unchanged combined display pass and pre-translation stable scan with the original transcript store. Word/line identity, edits, target/cache/preview gates and reset; translation dispatch, clocks and UI excluded.')
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
