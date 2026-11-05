#!/usr/bin/env python3
"""Compare every PCM window/preview with unchanged Swift Segmenter.swift."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import random
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/segmenter-parity'
REFERENCE = ROOT / 'design/parity/segmenter-reference.json'
SOURCES = [ROOT / name for name in [
    'apps/macos/Sovereign/Audio/Segmenter.swift',
    'apps/macos/Sovereign/Audio/WavWriter.swift',
    'apps/macos/Tests/SovereignCoreTests/SegmenterEarlyFlushTests.swift',
]]

def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')

def sha(data):
    return hashlib.sha256(data).hexdigest()

def configuration(**changes):
    return dict(sampleRate=16000, segmentSeconds=10, overlapSeconds=3,
                firstSegmentSeconds=1.5, earlyFlushSilenceSeconds=0.7,
                earlyFlushMinBodySeconds=2.5) | changes

def push(count, amplitude=3000, pattern=None, phase=0):
    return dict(type='push', count=count, pattern=pattern or [amplitude, -amplitude], phase=phase)

def corpus():
    cases = []
    def add(name, config, operations, group=None):
        cases.append(dict(name=name, configuration=config, operations=operations + [dict(type='flush'), dict(type='flush'), push(0)], invariantGroup=group))
    # The shipping early-flush test boundaries, plus exact-threshold and peak carry.
    for name, operations in [
        ('speech-then-silence', [push(48000), push(16000, 40)]),
        ('silence-only', [push(96000, 40)]),
        ('short-body', [push(16000), push(16000, 40)]),
        ('quiet-speech', [push(96000, 220)]),
        ('two-turns', [push(48000), push(16000, 40)] * 2),
        ('exact-floor', [push(48000, 200), push(11200, 0)]),
        ('below-floor', [push(48000, 199), push(11200, 0)]),
    ]:
        add(name, configuration(firstSegmentSeconds=10), operations)
    add('disabled-shipping-boundary', configuration(segmentSeconds=5, firstSegmentSeconds=5, overlapSeconds=1, earlyFlushSilenceSeconds=0), [push(48000), push(30400, 40), push(3200, 40)])
    add('peak-held-after-first', configuration(), [push(24000, 3000), push(48000, 220), push(16000, 0), push(160000, 220)])
    add('int16-extremes-and-partial-hop', configuration(), [push(159, pattern=[-32768, 32767, 1, -1, 0]), push(1, 0), push(32001, pattern=[-32768, 0]), push(16000, 0)])
    add('push-after-explicit-flush', configuration(), [push(7300), dict(type='flush'), push(47001, 220), dict(type='flush'), push(1234, 0)])
    # Each legacy group is the SAME PCM stream under different delivery boundaries.
    # Early flush is intentionally excluded: the source analyzes whole pushes.
    for rate in [100, 101, 16000, 22050]:
        for overlap in [0, 0.013, 0.4, 3.0]:
            config = configuration(sampleRate=rate, segmentSeconds=0.7, firstSegmentSeconds=0.17, overlapSeconds=overlap, earlyFlushSilenceSeconds=0)
            total = rate * 4 + 17
            for chunk in [37, 4096, total]:
                operations = [push(min(chunk, total-offset), pattern=[-32768, 32767, 0, 199, 200, 220, -3000], phase=offset % 7) for offset in range(0, total, chunk)]
                add(f'legacy-{rate}-{overlap}-{chunk}', config, operations, f'{rate}-{overlap}')
    # Real capture sizes, short first windows, fractional sample truncation,
    # disabled/enabled transitions and parameters changed with buffered audio.
    rng = random.Random(20261104)
    for index in range(160):
        rate = rng.choice([100, 8000, 16000, 22050, 44100])
        config = configuration(sampleRate=rate, segmentSeconds=rng.choice([0.35, 2.5, 5, 7, 10]),
                               firstSegmentSeconds=rng.choice([0.015, 0.17, 1.5, 3]),
                               overlapSeconds=rng.choice([0, 0.001, 0.13, 1, 3, 12]),
                               earlyFlushSilenceSeconds=rng.choice([-1, 0, 0.017, 0.7, 1.1]),
                               earlyFlushMinBodySeconds=rng.choice([-0.25, 0, 0.17, 2.5]))
        operations = []
        for step in range(14):
            if step in [5, 10]:
                updated = dict(config)
                updated.update(segmentSeconds=rng.choice([0.35, 1.5, 5, 10]), overlapSeconds=rng.choice([0, 0.1, 3]),
                               earlyFlushSilenceSeconds=rng.choice([0, 0.017, 0.7]))
                operations.append(dict(type='configure', configuration=updated))
            operations.append(push(rng.choice([0, 1, max(1, rate//100-1), rate//100, rate//100+1, 4096, rate*3+1]),
                                   pattern=rng.choice([[0], [40, -40], [199, -200, 201], [220, -220], [3000, -3000], [-32768, 32767]])))
        add(f'changing-{index}', config, operations)
    for chunk in [159, 160, 161, 4096, 48000]:
        total = 16000 * 12
        operations = [push(min(chunk, total-offset), pattern=[220, -220], phase=offset % 2) for offset in range(0, total, chunk)]
        add(f'capture-hop-{chunk}', configuration(), operations)
    add('two-minute-capture', configuration(), [push(4096, 3000 if index % 18 < 12 else 40) for index in range(469)])
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
    subprocess.run(['cargo', 'build', '--locked', '-p', 'madi-core', '--example', 'segmenter_oracle'], cwd=ROOT, check=True)
    executable = ROOT / 'target/debug/examples' / ('segmenter_oracle.exe' if platform.system() == 'Windows' else 'segmenter_oracle')
    rust = json.loads(subprocess.check_output([str(executable)], input=payload, cwd=ROOT))
    (OUT / 'rust.json').write_bytes(encoded(rust))
    if not args.rust_only:
        executable = OUT / 'swift-oracle'
        subprocess.run(['swiftc', '-O', *map(str, SOURCES[:2]), str(ROOT / 'tests/parity/SegmenterOracle.swift'), '-o', str(executable)], check=True)
        swift = json.loads(subprocess.check_output([str(executable)], input=payload))
        (OUT / 'swift.json').write_bytes(encoded(swift))
        for case, expected, actual in zip(cases, swift, rust, strict=True):
            if expected != actual:
                differences = [(i, e, a) for i, (e, a) in enumerate(zip(expected['states'], actual['states'], strict=True)) if e != a]
                raise AssertionError(f"Segmenter mismatch {case['name']}: {differences[:1]}")
    groups = {}
    for case, result in zip(cases, rust, strict=True):
        if case['invariantGroup']:
            segments = [segment for state in result['states'] for segment in state['segments']]
            previous = groups.setdefault(case['invariantGroup'], segments)
            assert previous == segments, case['name']
    report = dict(cases=len(cases), snapshots=sum(len(result['states']) for result in rust),
                  segments=sum(len(state['segments']) for result in rust for state in result['states']),
                  legacyFragmentationGroups=len(groups), corpusSHA256=sha(payload), resultSHA256=sha(encoded(rust)),
                  sources={path.relative_to(ROOT).as_posix(): sha(path.read_bytes()) for path in SOURCES})
    if args.write_reference: REFERENCE.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    else: assert report == json.loads(REFERENCE.read_text(encoding='utf-8')), 'Pinned segmenter reference changed'
    report.update(status='passed', nativeSwiftRun=not args.rust_only,
                  scope='Exact PCM hashes, offset bits, body counts, speech flags, previews and flush/configuration transitions; not device capture, resampling, WAV IO, engine feeding or native UI acceptance.')
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))

if __name__ == '__main__': main()
