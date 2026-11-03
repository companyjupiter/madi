#!/usr/bin/env python3
"""Compare the production frontend follow model with unchanged native Swift."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import platform
import random
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/transcript-follow-parity'
REFERENCE = ROOT / 'design/parity/transcript-follow-reference.json'
SOURCE = ROOT / 'apps/macos/Sovereign/Transcript/TranscriptFollowModel.swift'


def line(i, end=None):
    return dict(id=str(uuid.UUID(int=i + 1)), end=float(i if end is None else end))


def corpus():
    cases = []
    # Boundary values around every native threshold, in live/file/archive modes.
    for gap, delta, live in itertools.product(
            [-1, 0, 2, 2.001, 119.999, 120, 120.001, 160, 160.001, 600],
            [-12, -2.001, -2, -1, 0, 1, 2, 2.001, 12], [False, True]):
        lines = [line(i) for i in range(5)]
        cases.append(dict(operations=[
            dict(kind='geometry', gap=0, live=live, lines=lines),
            dict(kind='wheel', gap=gap, delta=delta),
            dict(kind='geometry', gap=gap, live=live, lines=lines),
            dict(kind='lines', lines=lines + [line(5), line(6)]),
            dict(kind='pill', lines=lines + [line(5), line(6)]),
            dict(kind='geometry', gap=2400, live=live, lines=lines),
            dict(kind='geometry', gap=0, live=live, lines=lines),
        ]))
    # The native merge regression, including removal of the last seen identity.
    lines = [line(i) for i in range(5)]
    operations = [dict(kind='geometry', gap=0, live=True, lines=lines),
                  dict(kind='wheel', delta=40, gap=900),
                  dict(kind='geometry', gap=900, live=True, lines=lines)]
    lines = lines + [line(i) for i in range(5, 8)]
    operations.append(dict(kind='lines', lines=lines))
    lines = [item for item in lines if item['id'] != line(6)['id']]
    operations.append(dict(kind='lines', lines=lines))
    lines = lines + [line(i) for i in range(8, 12)]
    operations.append(dict(kind='lines', lines=lines))
    lines = [item for item in lines if item['id'] != line(4)['id']]
    operations.append(dict(kind='lines', lines=lines))
    operations += [dict(kind='jump'), dict(kind='reset'), dict(kind='lines', lines=[])]
    cases.append(dict(operations=operations))
    # A vanished identity falls back to time with the exact 0.001 epsilon.
    for end in [9.999, 10, 10.0009, 10.001, 10.0011, 11]:
        cases.append(dict(operations=[dict(kind='geometry', gap=0, live=False, lines=[line(10)]),
            dict(kind='jump'), dict(kind='geometry', gap=300, live=False, lines=[line(10)]),
            dict(kind='lines', lines=[line(20, end)])]))
    rng = random.Random(420271)
    for case in range(100):
        lines = []
        operations = []
        for _ in range(120):
            kind = rng.choice(['geometry', 'wheel', 'jump', 'lines', 'lines', 'pill', 'reset'])
            if kind == 'lines':
                change = rng.randrange(4)
                if change == 0: lines = lines + [line(case * 1000 + rng.randrange(500), rng.randrange(1000) / 10)]
                elif change == 1 and lines: lines = lines[:rng.randrange(len(lines))] + lines[rng.randrange(len(lines)):]
                elif change == 2: lines = []
                else: lines = [dict(item, id=item['id'].upper()) for item in lines]
                operations.append(dict(kind=kind, lines=lines))
            elif kind == 'geometry':
                operations.append(dict(kind=kind, gap=rng.choice([0, 1, 2, 120, 121, 160, 600]), live=bool(rng.randrange(2)), lines=lines))
            elif kind == 'wheel':
                operations.append(dict(kind=kind, delta=rng.choice([-20, -2, -1, 0, 1, 2, 20]), gap=rng.choice([0, 120, 160, 161, 800])))
            elif kind == 'pill': operations.append(dict(kind=kind, lines=lines))
            else: operations.append(dict(kind=kind))
        cases.append(dict(settings=dict(nearZone=rng.choice([80, 120]), pinTolerance=rng.choice([0, 2]),
                                        rearmZone=rng.choice([140, 160]), wheelDeadband=rng.choice([1, 2])), operations=operations))
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--frontend-only', action='store_true')
    parser.add_argument('--write-reference', action='store_true')
    args = parser.parse_args()
    if args.write_reference and args.frontend_only: parser.error('Reference requires live Swift')
    if not args.frontend_only and platform.system() != 'Darwin': parser.error('Live Swift requires macOS')
    OUT.mkdir(parents=True, exist_ok=True)
    cases = corpus()
    payload = json.dumps(cases, sort_keys=True).encode()
    actual = json.loads(subprocess.check_output(['node', '--experimental-strip-types', str(ROOT / 'tests/parity/transcript_follow_oracle.mjs')], input=payload))
    if not args.frontend_only:
        binary = OUT / 'swift-transcript-follow'
        subprocess.run(['swiftc', '-parse-as-library', str(SOURCE), str(ROOT / 'tests/parity/TranscriptFollowOracle.swift'), '-o', str(binary)], check=True)
        expected = json.loads(subprocess.check_output([str(binary)], input=payload))
        if actual != expected:
            for i, (found, wanted) in enumerate(zip(actual, expected)):
                if found != wanted: raise AssertionError(json.dumps(dict(case=i, input=cases[i], actual=found, expected=wanted)))
            raise AssertionError('case count differs')
    report = dict(schemaVersion=1, status='passed', cases=len(cases), snapshots=sum(len(case['operations']) for case in cases),
                  swiftComparison='not-run' if args.frontend_only else 'live-unmodified-follow-model',
                  sources={SOURCE.relative_to(ROOT).as_posix(): hashlib.sha256(SOURCE.read_bytes()).hexdigest()},
                  corpusSHA256=hashlib.sha256(payload).hexdigest(), resultSHA256=hashlib.sha256(json.dumps(actual, sort_keys=True).encode()).hexdigest(),
                  scope='Pure state/action parity: live/static geometry, wheel intent, merge identity/time, unseen count, pill, reset and threshold boundaries. No native wheel/scrollbar events, layout or animation comparison.')
    keys = ('cases', 'snapshots', 'sources', 'corpusSHA256', 'resultSHA256')
    if args.write_reference: REFERENCE.write_text(json.dumps({key:report[key] for key in keys}, indent=2)+'\n')
    reference = json.loads(REFERENCE.read_text())
    for key in keys: assert reference[key] == report[key], f'Follow reference differs: {key}'
    (OUT / 'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
