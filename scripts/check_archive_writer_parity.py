#!/usr/bin/env python3
"""Compare real-file archive writer transitions with unchanged shipping Swift."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import unicodedata

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/archive-writer-parity'
SOURCE=ROOT/'apps/macos/Sovereign/Session/SessionArchiveWriter.swift'
REFERENCE=ROOT/'design/parity/archive-writer-reference.json'

def step(op,**args): return dict(op=op,**args)
def corpus():
    cases=[]
    def case(name,*steps): cases.append(dict(name=name,steps=steps))
    case('empty-pointer',step('summary',text='none'),step('rename'),step('reset'))
    case('checkpoint',step('save',folder='work/nested',base='회의',text='first'),step('save',folder='other',base='ignored',text='updated'),step('reset'),step('save',folder='work/nested',base='회의',text='new'))
    case('collisions',step('file',folder='meeting.md',text='foreign'),step('mkdir',folder='meeting 2.md'),step('save',text='third'),step('summary',text='summary'),step('summary',text='second'),step('rename',base='renamed'),step('save',text='checkpoint'),step('summary',text='after rename'))
    case('failed-first-save',step('file',folder='blocked',text='keep'),step('save',folder='blocked',text='lost'),step('summary'),step('rename'),step('save',folder='valid',text='recovered'))
    case('failed-rename',step('save',text='record'),step('file',folder='blocked',text='keep'),step('rename',folder='blocked'),step('save',text='after failure'),step('rename',folder='valid'),step('summary',text='after success'))
    case('failed-checkpoint',step('save',text='old'),step('remove',folder='meeting.md'),step('mkdir',folder='meeting.md'),step('file',folder='meeting.md/keep',text='keep'),step('save',text='lost'),step('remove',folder='meeting.md'),step('save',text='recovered'))
    case('same-name-rename',step('save',base='file.ext',text='record'),step('summary',text='summary'),step('rename',base='file.ext'),step('rename',folder='nested',base='file.ext'),step('summary',text='next'))
    case('companion-collision',step('save',text='record'),step('summary',text='summary'),step('file',folder='new 요약.md',text='keep'),step('rename',base='new'),step('summary',text='later'))
    case('missing-source',step('save',text='record'),step('remove',folder='meeting.md'),step('rename',base='new'),step('summary',text='still points to old path'),step('save',text='restored'))
    for name in ('é','e\u0301','Å','Å','Ω','豈','丽','！','회의'):
        case('filename-'+name,step('save',base=name,text='body é\n회의'),step('summary',text='summary é\n회의'),step('rename',base=name+' renamed'))
    rng=random.Random(2147)
    for index in range(30):
        steps=[]
        for _ in range(25):
            op=rng.choice(['save','save','summary','rename','reset'])
            steps.append(step(op,folder=rng.choice(['','workspace','nested/work']),base=rng.choice(['meeting','회의','file.ext','title 2']),text=rng.choice(['','text','내용\nsecond','edited *word*'])))
        case('sequence-'+str(index),*steps)
    return cases

def portable_result(result, heading_normalization=True):
    # macOS URL paths use filesystem decomposition. Windows retains its native
    # filename representation. Compare those names canonically across hosts,
    # including only the generated filename in a summary heading; body bytes
    # remain exact. Live macOS also compares headings byte-for-byte. Paths are
    # canonical in both modes because fixture setup uses different path APIs.
    result=json.loads(json.dumps(result))
    for states in result:
        for state in states:
            if state['pointer'] is not None: state['pointer']=unicodedata.normalize('NFC',state['pointer'])
            files={}
            for path,value in state['files'].items():
                if value!='directory':
                    content=bytes.fromhex(value).decode('utf-8')
                    heading,sep,body=content.partition('\n\n')
                    if heading_normalization and heading.startswith('# ') and heading.endswith(' — 회의 요약') and sep:
                        content=unicodedata.normalize('NFC',heading)+sep+body
                    value=content.encode().hex()
                files[unicodedata.normalize('NFC',path)]=value
            state['files']=files
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only',action='store_true');parser.add_argument('--write-reference',action='store_true')
    args=parser.parse_args()
    if args.write_reference and args.rust_only: parser.error('Reference requires live Swift')
    OUT.mkdir(parents=True,exist_ok=True);swift=OUT/'swift-archive-writer'
    if not args.rust_only:
        subprocess.run(['swiftc','-parse-as-library',str(SOURCE),str(ROOT/'tests/parity/ArchiveWriterOracle.swift'),'-o',str(swift)],check=True)
    subprocess.run(['cargo','build','--locked','-p','madi-platform','--example','archive_writer_oracle'],cwd=ROOT,check=True)
    cases=corpus();payload=json.dumps(cases,sort_keys=True).encode();suffix='.exe' if os.name=='nt' else ''
    rust=json.loads(subprocess.check_output([str(ROOT/'target/debug/examples'/('archive_writer_oracle'+suffix))],input=payload))
    if not args.rust_only:
        expected=json.loads(subprocess.check_output([str(swift)],input=payload))
        if portable_result(rust,False)!=portable_result(expected,False):
            for case,a,b in zip(cases,portable_result(expected,False),portable_result(rust,False)):
                if a!=b:
                    (OUT/'mismatch.json').write_text(json.dumps(dict(case=case,swift=a,rust=b),ensure_ascii=False,indent=2),encoding='utf-8')
                    raise SystemExit('Archive writer mismatch: '+case['name'])
            raise SystemExit('Archive writer result count mismatch')
    portable=portable_result(rust)
    report=dict(schemaVersion=1,status='passed',cases=len(cases),snapshots=sum(map(len,rust)),
                swiftComparison='not-run' if args.rust_only else 'live-unmodified-writer-source',
                sources={SOURCE.relative_to(ROOT).as_posix():hashlib.sha256(SOURCE.read_bytes()).hexdigest()},
                corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(json.dumps(portable,sort_keys=True).encode()).hexdigest(),
                scope='Real temporary files: pointer/error presence, canonical names and contents after checkpoint, reset, rename, summary and I/O failure. Live macOS compares full file bytes exactly; portable reference additionally compares filename-derived summary headings canonically, with body bytes exact. Error wording, cross-volume moves, crash durability and native UI are not compared. Concurrent allocation is verified separately in Rust.')
    keys=('cases','snapshots','sources','corpusSHA256','resultSHA256')
    if args.write_reference:REFERENCE.write_text(json.dumps({key:report[key] for key in keys},indent=2)+'\n',encoding='utf-8')
    reference=json.loads(REFERENCE.read_text(encoding='utf-8'))
    for key in keys:assert report[key]==reference[key],f'Archive writer reference differs: {key}'
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
