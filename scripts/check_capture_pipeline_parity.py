#!/usr/bin/env python3
"""Compare Rust post-converter capture/WAV behavior with shipping AudioCapture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/capture-pipeline-parity'
REFERENCE = ROOT / 'design/parity/capture-pipeline-reference.json'
SOURCES = [f'apps/macos/Sovereign/Audio/{name}.swift' for name in
           ('AudioCapture', 'AudioSource', 'AudioDevices', 'SystemAudioCapture', 'Resampler', 'Segmenter', 'WavWriter')]
SOURCES += ['apps/macos/Sovereign/Session/SessionCoordinator.swift', 'tests/parity/CapturePipelineOracle.swift']


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def sha(value):
    return hashlib.sha256(value).hexdigest()


def configuration(**changes):
    return dict(source='mic', segmentSeconds=10, overlapSeconds=3,
                firstSegmentSeconds=1.5, previewSeconds=1, previewEnabled=True) | changes


def ingest(count, microphone=True, pattern=None):
    return dict(type='ingest', count=count, microphone=microphone, pattern=pattern or [3000, -3000])


def op(kind):
    return dict(type=kind)


def corpus():
    cases = []
    def add(name, operations, **changes):
        cases.append(dict(name=name, configuration=configuration(**changes),
                          operations=[ingest(17), op('start')] + operations + [op('stop'), op('stop'), ingest(1000), op('abort'), ingest(1000, False)]))
    for source in ('mic', 'system', 'both'):
        add(f'{source}-short-first-preview-silence-tail', [ingest(4096, i % 2 == 0, [3000, -3000] if i % 18 < 12 else [0]) for i in range(120)], source=source)
        add(f'{source}-empty-and-extreme', [ingest(0), ingest(159, pattern=[-32768,32767,1,-1,0]), ingest(1,False,[-1,1]), ingest(32_001,False,[-32768,32767]), ingest(32_001,pattern=[32767,-32768])], source=source)
    add('strict-two-second-stall', [ingest(32_000), ingest(1), ingest(32_000,False), ingest(1,False)], source='both')
    add('prefix-clamp-and-unmatched-tail', [ingest(3,pattern=[32767,-32768,9]), ingest(2,False,[9,-9]), ingest(31_999)], source='both')
    add('pause-with-no-delivery-then-stop', [ingest(1001), op('pause')], source='both')
    add('pause-drops-both-queues', [ingest(1001),op('pause'),ingest(4000,False),op('resume'),ingest(1000,False)], source='both')
    add('single-pause-omits-timeline', [ingest(9000),op('pause'),ingest(32_001),op('resume'),ingest(9000)])
    add('abort-no-tail-rejects-late', [ingest(16001),op('abort'),ingest(10000),op('start'),ingest(16001)])
    add('preview-exact-half-pending', [ingest(32000),ingest(1),ingest(16000),ingest(16000),ingest(16000)])
    add('large-push-multiple-cuts-one-preview', [ingest(240001),ingest(32001),ingest(16001)])
    add('repeat-start-preview-counter-and-slot', [ingest(11000),op('start'),ingest(9000),op('stop'),op('start'),ingest(16001)])
    add('preview-toggle-keeps-counter', [ingest(12000),dict(type='configure',configuration=configuration(previewEnabled=False)),ingest(3000),dict(type='configure',configuration=configuration()),ingest(8001)])
    rng = random.Random(2026110402)
    for index in range(96):
        config = configuration(source=rng.choice(['mic','system','both']),
                               segmentSeconds=rng.choice([1,2.5,5,10]),
                               firstSegmentSeconds=rng.choice([0.1,1.5,3]),
                               overlapSeconds=rng.choice([0,0.13,1,3]),
                               previewSeconds=rng.choice([0.1,0.333,1,1.5]),
                               previewEnabled=rng.choice([True,False]))
        operations = []
        for step in range(24):
            if step in (5,6,11,18):
                operations.append(op(rng.choice(['pause','resume','abort','start'])))
            if step == 15:
                updated = dict(config); updated.update(segmentSeconds=rng.choice([1,5,10]),overlapSeconds=rng.choice([0,1,3]),previewEnabled=not config['previewEnabled'])
                operations.append(dict(type='configure',configuration=updated))
            operations.append(ingest(rng.choice([0,1,159,160,161,4096,8000,8001,16000,32000,32001,120001]),rng.choice([True,False]),rng.choice([[0],[40,-40],[199,-200,201],[220,-220],[3000,-3000],[-32768,32767]])))
        add(f'varied-{index}',operations,**config)
    add('five-minute-alternating-both', [ingest(4096,i%2==0,[3000,-3000] if i%31<24 else [40,-40]) for i in range(2344)], source='both')
    return cases


def run(command, **kwargs):
    return subprocess.run(command, cwd=ROOT, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only', action='store_true')
    parser.add_argument('--write-reference', action='store_true')
    args = parser.parse_args()
    if args.write_reference and args.rust_only:
        parser.error('Reference requires live shipping Swift')
    if not args.rust_only and platform.system() != 'Darwin':
        parser.error('Live shipping AudioCapture requires macOS')
    OUT.mkdir(parents=True, exist_ok=True)
    cases = corpus(); payload = encoded(cases)
    run([os.environ.get('CARGO','cargo'),'build','--locked','-p','madi-platform','--example','capture_pipeline_oracle'])
    rust_binary = ROOT / 'target/debug/examples' / ('capture_pipeline_oracle.exe' if platform.system() == 'Windows' else 'capture_pipeline_oracle')
    rust = json.loads(run([str(rust_binary)],input=payload,capture_output=True,timeout=120).stdout)
    (OUT/'rust.json').write_bytes(encoded(rust))
    if not args.rust_only:
        # Same-file private access is the only instrumentation. The complete
        # shipping AudioCapture bytes are retained as the generated file prefix.
        original = (ROOT/SOURCES[0]).read_bytes()
        combined = OUT/'ShippingAudioCaptureOracle.swift'
        combined.write_bytes(original+b'\n'+(ROOT/SOURCES[-1]).read_bytes())
        assert combined.read_bytes().startswith(original)
        coordinator = (ROOT/SOURCES[-2]).read_text(encoding='utf-8')
        protocol = OUT/'SessionCaptureProtocol.swift'
        protocol.write_text(coordinator.split('enum SessionEngineOutput {')[0],encoding='utf-8')
        swift_binary = OUT/'swift-oracle'
        run(['xcrun','swiftc','-O','-parse-as-library',*SOURCES[1:7],str(protocol),str(combined),'-o',str(swift_binary)])
        swift = json.loads(run([str(swift_binary)],input=payload,capture_output=True,timeout=120).stdout)
        (OUT/'swift.json').write_bytes(encoded(swift))
        for case,expected,actual in zip(cases,swift,rust,strict=True):
            if expected != actual:
                differences = [(i,e,a) for i,(e,a) in enumerate(zip(expected['states'],actual['states'],strict=True)) if e != a]
                raise AssertionError(f"Capture mismatch {case['name']}: {differences[:1] or (expected['files'],actual['files'],expected['directoryCleaned'],actual['directoryCleaned'])}")
    assert all(case['directoryCleaned'] for case in rust)
    events = [event for result in rust for state in result['states'] for event in state]
    report = dict(cases=len(cases),operations=sum(len(c['operations']) for c in cases),
                  levelEvents=sum(e['type']=='level' for e in events),
                  segments=sum(e['type']=='segment' for e in events),
                  previews=sum(e['type']=='preview' for e in events),
                  wavBytesCompared=sum(e.get('bytes',0) for e in events),
                  corpusSHA256=sha(payload),resultSHA256=sha(encoded(rust)),
                  sourceSHA256={path:sha((ROOT/path).read_bytes()) for path in SOURCES})
    if args.write_reference:
        REFERENCE.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    else:
        expected = json.loads(REFERENCE.read_text(encoding='utf-8'))
        differences = {key: dict(expected=expected.get(key), actual=report.get(key))
                       for key in sorted(expected.keys() | report.keys())
                       if expected.get(key) != report.get(key)}
        if differences:
            report.update(status='failed', nativeSwiftRun=not args.rust_only, differences=differences)
            (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
            raise AssertionError('Pinned capture pipeline reference changed: '+json.dumps(differences))
    report.update(status='passed',nativeSwiftRun=not args.rust_only,
                  scope='Shipping ingest/mix/pause/stop/abort, exact Float meter and callback order, WAV bytes/names, preview rotation, retained files and cleanup; no hardware, live engine or UI acceptance')
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))


if __name__ == '__main__':
    main()
