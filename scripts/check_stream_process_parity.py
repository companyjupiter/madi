#!/usr/bin/env python3
"""Drive actual Swift EngineProcess pipes and compare ordered Rust stream output."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/stream-process-parity'
SOURCE=ROOT/'apps/macos/Sovereign/Engine'


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--rust-only',action='store_true')
    parser.add_argument('--bootstrap-reference',action='store_true')
    args=parser.parse_args()
    if args.rust_only and args.bootstrap_reference: parser.error('bootstrap needs live Swift')
    OUT.mkdir(parents=True,exist_ok=True)
    (OUT/'report.json').write_text('{"status":"running"}\n')
    sources=[SOURCE/name for name in ['EngineProcess.swift','EngineProtocol.swift','EngineEvents.swift','EnginePathPolicy.swift']]
    if not args.rust_only:
        subprocess.run(['swiftc','-O',*[str(p) for p in sources],str(ROOT/'tests/parity/StreamProcessOracle.swift'),'-o',str(OUT/'swift-oracle')],check=True)
    cargo=os.environ.get('CARGO') or shutil.which('cargo') or str(Path.home()/'.cargo/bin/cargo')
    subprocess.run([cargo,'build','-p','madi-protocol','--example','stream_process_oracle'],cwd=ROOT,check=True)
    def batch(stdout,json=b'',ack=False):
        return {'stdout':stdout.hex(),'json':json.hex(),'ack':ack}
    partial='{"t":"partial","t0":1,"text":"안녕"}\n'.encode()
    pos=partial.index('안'.encode())+1
    scenarios=[
        [batch('[caps] preview-fp other\n[stream] ready\n=== WORD TIMESTAMPS ===\n[0s-1s] 한글 🙂\n<<SEG_END>>\n'.encode(),b'{"t":"ready"}\n'+partial[:pos],True),batch(b'<<FLUSH_END>>',partial[pos:]+b'{"t":"flush_end"}\n{"t":"ready"}')],
        [batch(b'\xff\n<<PREVIEW_BEGIN>>\n<<FLUSH_END>>\n<<PREVIEW_END>>\n<<SEG_END>>\n',b'{"t":"ready"}\n',True),batch(b'[8] audio: 1s \xe2\x86\x92 7 chunk(s)')],
        [batch(b'diagnostic without newline',b'{"t":"ready"}\n')],
        [batch(b'<<SEG_END>>\n'*1000+b'[8] audio: 1s \xe2\x86\x92 7 chunk(s)',b'{"t":"ready"}\n')],
        [batch(b'[caps] old\n[caps] preview-fp\n<<FLUSH_END>>\r\n',b'bad\n\xff\n{\"t\":\"ready\"}\r\n')],
    ]
    cases=[{'exit':7,'batches':[{**b,'chunk':chunk} for b in batches]} for batches in scenarios for chunk in [1,2,7,64]]
    fixture=ROOT/'tests/parity/stream_fixture.py'
    executable=ROOT/'target/debug/examples'/('stream_process_oracle.exe' if sys.platform=='win32' else 'stream_process_oracle')
    all_output=bytearray()
    with tempfile.TemporaryDirectory(prefix='madi-stream-parity-') as directory:
        root=Path(directory)
        case_path=root/'case.json'
        for index,case in enumerate(cases):
            case_path.write_text(json.dumps(case),encoding='utf-8')
            def run(exe):
                return subprocess.run([str(exe),sys.executable,str(fixture),str(case_path),str(root)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15,check=True).stdout
            expected=None if args.rust_only else run(OUT/'swift-oracle')
            actual=run(executable)
            if expected is not None and expected!=actual:
                (OUT/'swift.events').write_bytes(expected); (OUT/'rust.events').write_bytes(actual)
                (OUT/'report.json').write_text(json.dumps({'status':'fail','case':index})+'\n')
                raise SystemExit(f'process stream mismatch in case {index}: see {OUT}')
            all_output.extend(str(index).encode()+b'\n'+actual)
    report={'status':'pass','cases':len(cases),'swiftComparison':'not-run' if args.rust_only else 'live-unmodified-EngineProcess','sources':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},'corpusSha256':hashlib.sha256(json.dumps(cases,sort_keys=True).encode()).hexdigest(),'eventStreamSha256':hashlib.sha256(all_output).hexdigest(),'scope':'Real child pipes and JSONL barriers; fixture engine, no recording or inference'}
    if not args.bootstrap_reference:
        pinned=json.loads((ROOT/'design/parity/stream-reference.json').read_text())
        if any(report[k]!=pinned[k] for k in ['sources','corpusSha256','eventStreamSha256']): report['status']='fail'
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    if report['status']!='pass': raise SystemExit('pinned stream process reference mismatch')
    print(json.dumps(report,indent=2))


if __name__=='__main__': main()
