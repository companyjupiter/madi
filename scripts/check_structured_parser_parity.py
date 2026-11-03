#!/usr/bin/env python3
"""Compare EVENTS_FILE decoding to unchanged Swift source and pinned evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/structured-parser-parity'
SWIFT = ROOT / 'apps/macos/Sovereign/Engine/EngineEvents.swift'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rust-only', action='store_true')
    parser.add_argument('--bootstrap-reference', action='store_true', help='Print new reference only after a successful live Swift comparison')
    args = parser.parse_args()
    if args.rust_only and args.bootstrap_reference:
        parser.error('reference bootstrap requires live Swift')
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'report.json').write_text('{"status":"running"}\n')
    cargo = os.environ.get('CARGO') or shutil.which('cargo') or str(Path.home() / '.cargo/bin/cargo')
    if not args.rust_only:
        subprocess.run(['swiftc', '-O', str(SWIFT), str(ROOT / 'tests/parity/StructuredOracle.swift'), '-o', str(OUT / 'swift-oracle')], check=True)
    subprocess.run([cargo, 'build', '-p', 'madi-protocol', '--example', 'structured_oracle'], cwd=ROOT, check=True)
    cases = []
    fixtures = {}
    for path in sorted((ROOT / 'web/fixtures').glob('*.events.jsonl')):
        # Decode as text so Windows checkout CRLF cannot change the corpus.
        lines = path.read_text(encoding='utf-8').splitlines()
        cases.extend(lines)
        fixtures[str(path.relative_to(ROOT))] = len(lines)
    tags = ['meta', 'ready', 'partial', 'word', 'seg', 'spk_seg', 'diar', 'seg_end', 'flush_end', 'future', '']
    values = [None, False, True, 0, 1, -1, 2, 1.5, -1.5, '', '1', '한글 日本語 🙂', [], {}, ['a', 'b'], ['a', None]]
    keys = ['model','lang','sr','v','t0','t1','conf','spk','idx','avg_logprob','fallback','tok_s','enc_ms','dec_ms','passes','dropped','text','bias_hits','speakers','silhouette','sep','tau','segments']
    for tag in tags:
        cases.append(json.dumps({'t':tag}))
        for value in values:
            cases.append(json.dumps({'t':tag, **{key:value for key in keys}}, ensure_ascii=False))
    for cp in [9,10,11,12,13,0x85,0xa0,0x1680,*range(0x2000,0x200c),0x2028,0x2029,0x202f,0x205f,0x3000,0xfeff]:
        cases.append(chr(cp) + '{"t":"ready"}' + chr(cp))
    cases.extend(['', 'not json', 'null','[]','true','42','{}','{"t":1}', '{"t":"ready",}', '{"t":"ready"} trailing', '{"t":"ready","t":"flush_end"}', '{"t":"word","text":"\\ud800"}', '{"t":"word","text":"\\ud83d\\ude42"}'])
    for number in ['-0', '-0.0', '1e-400', '1e400', 'NaN', '01', '+1', '.5', '1.', '9223372036854775807', '9223372036854775808', '18446744073709551615']:
        cases.append('{"t":"word","t0":'+number+',"spk":'+number+'}')
    rng = random.Random(53)
    for _ in range(1000):
        # Actual wire format emits bounded decimal times, confidence and counts.
        cases.append(json.dumps({'t':rng.choice(tags), 't0':round(rng.uniform(-1,100000),6), 't1':round(rng.uniform(0,100000),6), 'conf':round(rng.random(),6), 'idx':rng.randrange(10000), 'spk':rng.randrange(-1,9), 'passes':rng.randrange(8), 'dropped':bool(rng.randrange(2)), 'text':'안녕 e\u0301 👨‍👩‍👦', 'bias_hits':['한국어','C++']}, ensure_ascii=False))
    payload = bytearray(struct.pack('<I',len(cases)))
    for line in cases:
        raw=line.encode(); payload.extend(struct.pack('<I',len(raw))); payload.extend(raw)
    profile = "first" if args.rust_only else subprocess.check_output([str(OUT/'swift-oracle'),'--json-profile'],text=True).strip()
    assert profile in ('first','last'), profile
    def run(path, arguments=()):
        return subprocess.run([str(path),*arguments],input=payload,stdout=subprocess.PIPE,check=True,timeout=60).stdout
    swift = None if args.rust_only else run(OUT / 'swift-oracle')
    rust_path = ROOT / 'target/debug/examples' / ('structured_oracle.exe' if sys.platform=='win32' else 'structured_oracle')
    rust = run(rust_path, ['--last-duplicate-key'] if profile=='last' else [])
    canonical = rust if profile=='first' else run(rust_path)
    if swift is not None: (OUT / 'swift.events').write_bytes(swift)
    (OUT / 'rust.events').write_bytes(rust)
    report={'status':'pass' if swift is None or swift==rust else 'fail','cases':len(cases),'fixtures':fixtures,'swiftComparison':'not-run' if args.rust_only else 'live-unmodified-source','corpusSha256':hashlib.sha256(payload).hexdigest(),'swiftSourceSha256':hashlib.sha256(SWIFT.read_bytes()).hexdigest(),'eventStreamSha256':hashlib.sha256(rust).hexdigest(),'scope':'Engine contract fields; arbitrary-precision NSNumber coercions outside the bounded engine contract are not reproduced'}
    report.update({'duplicateKeyProfile': None if args.rust_only else profile,'canonicalEventStreamSha256':hashlib.sha256(canonical).hexdigest(),'canonicalDefaultMatchesHost':None if args.rust_only else profile=='first'})
    if not args.bootstrap_reference:
        pinned=json.loads((ROOT/'design/parity/structured-reference.json').read_text())
        if any(report[key]!=pinned[key] for key in ('corpusSha256','swiftSourceSha256')) or report['canonicalEventStreamSha256']!=pinned['eventStreamSha256']: report['status']='fail'
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    if swift is not None and swift!=rust:
        mismatches=[]
        for expected,actual in zip(swift.splitlines(),rust.splitlines()):
            if expected!=actual:
                index=int(expected.split(b':',1)[0]); mismatches.append({'input':cases[index],'swift':expected.decode(),'rust':actual.decode()})
        print(json.dumps(mismatches[:30],indent=2,ensure_ascii=False))
        raise SystemExit('structured parser mismatch')
    if report['status']!='pass': raise SystemExit('pinned structured reference mismatch')
    print(json.dumps(report,indent=2))


if __name__=='__main__': main()
