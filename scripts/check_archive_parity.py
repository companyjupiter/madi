#!/usr/bin/env python3
"""Compare Markdown/plain export and lossy reopen with unchanged Swift methods."""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import subprocess
import unicodedata
import uuid
import sys
sys.dont_write_bytecode = True
from check_model_gate_parity import block

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/archive-parity'
REFERENCE = ROOT / 'design/parity/archive-reference.json'
STORE = ROOT / 'apps/macos/Sovereign/Transcript/TranscriptStore.swift'
EXPORT = ROOT / 'apps/macos/Sovereign/Transcript/Exporters.swift'
ARCHIVE = ROOT / 'apps/macos/Sovereign/Transcript/TranscriptArchive.swift'
SPEAKER = ROOT / 'apps/macos/Sovereign/Transcript/SpeakerID.swift'

def word(text, conf=1.0, start=0):
    return dict(id=str(uuid.UUID(int=1)),t0=start,t1=start+.25,text=text,conf=conf)

def line(words, **overrides):
    value=dict(id=str(uuid.UUID(int=1)),speaker=0,start=0,end=1,words=words,overlapSpeakers=[],speakerMargin=1,
               translations={},staleTranslations={},editedTranslations=[],suppressedTranslations=[],editedText=None)
    value.update(overrides)
    return value

def corpus():
    cases=[]
    def case(name, lines=None, names=None, summary=None, archive=None):
        cases.append(dict(name=name,lines=lines or [],names=names or {},summary=summary,archive=archive))
    case('empty'); case('unrecognized',archive='# meeting\nnot a transcript\n  - [번역:en] orphan')
    for time in (-61.9,-1.9,-0.0,0,.99,59.99,60,5999,6000,7200,43200,128849018880.0):
        case('time-'+str(time),[line([word('내용')],start=time)])
    tokens=['','plain','네','é','e\u0301','*','**','*반갑*습니다','a*b','*\u0301','*\ufe0f\u20e3',
            ' \u0301x','a \u0301b','a\tb','a\u00a0b',',','.','!','?','…','!\u0301','👩‍👩‍👧‍👦','⟨+이름 겹침⟩',
            '\u200btrim\u200b','\t spaced \t','\nnew\rline','\u0085','\u2028','a\x00b']
    for token, conf in itertools.product(tokens,(0.3,0.549999999999,0.55,1.0)):
        case(f'token-{token}-{conf}',[line([word(''),word(token,conf),word('last')])],archive=f'- **[00:01] Speaker 0** {token} last')
    for who in ('Speaker 0','Speaker 002','Speaker 255','Speaker 254','Speaker -1','Speaker １２','Speaker ١٢',
                '미확인',unicodedata.normalize('NFD','미확인'),' 이름 ','\u200b이름\u200b','é','e\u0301',''):
        case('speaker-'+who,archive=f'- **[00:01] {who}** first\n- **[00:02] Named** second\n- **[00:03] Speaker 4** third\n- **[00:00] {who}** again')
    case('canonical-speakers',archive='- **[00:00] e\u0301** one\n- **[00:00] é** two')
    case('canonical-translations',archive='- **[00:00] Speaker 1** x\n  - [번역:e\u0301] old\n  - [번역:é] new')
    case('canonical-translations-reversed',archive='- **[00:00] Speaker 1** x\n  - [번역:é] old\n  - [번역:e\u0301] new')
    for newline in ('\n','\r','\r\n','\v','\f','\u0085','\u2028','\u2029'):
        case('newline-'+repr(newline),archive=newline.join(['- **[00:00] Name** *low*','header','  - [번역:en] retained','- **[00:02] Speaker 3** next']))
    for timestamp in ('0:00','000:99','12:1','１２:３４','١٢:٣٤','0:٠٠','00:00','1'*320+':00'):
        case('parse-time-'+timestamp,archive=f'- **[{timestamp}] Name** words')
    for summary in (None,'',' ','\u200b\n',' summary\n다음 ','a\r\nb'):
        for edited in (None,'','수정됨 *text*'):
            case('export-'+repr(summary)+'-'+repr(edited),[line([word(' low ',.3),word('word')],speaker=255,
                 overlapSpeakers=[0,255,7],translations={'en':'a\nb\r\nc','한국어':'한국어','e\u0301':'accent','z':'last'},
                 staleTranslations={'ja':'exclude'},editedTranslations=['en'],editedText=edited)],names={'0':'Name','255':'must be ignored'},summary=summary)
    randomizer=random.Random(9401)
    for index in range(100):
        rows=[]
        for _ in range(randomizer.randrange(1,12)):
            who=randomizer.choice(['Speaker 0','Speaker 4','Speaker 255','Alpha','Beta','미확인'])
            body=' '.join(randomizer.choices(tokens,k=randomizer.randrange(0,15)))
            rows.extend([f'- **[{randomizer.randrange(0,720):02}:{randomizer.randrange(100):02}] {who}** {body}',
                         '  - [번역:en] value','ignored','  - [번역:en] replacement'])
        case('random-'+str(index),archive='\n'.join(rows))
    fixtures=sorted((ROOT/'web/fixtures').glob('*.events.jsonl')); fixture_words=0
    for path in fixtures:
        words=[]
        for row in path.read_text(encoding='utf-8').splitlines():
            event=json.loads(row)
            if event.get('t')=='word':
                words.append(dict(id=str(uuid.UUID(int=len(words)+1)),t0=event['t0'],t1=event['t1'],text=event['text'],conf=event.get('conf',1)))
        fixture_words+=len(words)
        lines=[line(words[i:i+12],start=words[i]['t0'],speaker=i%3) for i in range(0,len(words),12)]
        case(path.name,lines,names={'0':'Alice','1':'미확인'})
    return cases,fixtures,fixture_words

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only',action='store_true'); parser.add_argument('--write-reference',action='store_true')
    args=parser.parse_args()
    if args.rust_only and args.write_reference: parser.error('Reference requires live Swift')
    OUT.mkdir(parents=True,exist_ok=True)
    store=STORE.read_text(encoding='utf-8'); export=EXPORT.read_text(encoding='utf-8')
    source='import Foundation\n'+store[store.index('struct Word:'):store.index('/// Stable, process-independent')]
    source+='\n'+block(store,'enum SegmentStatus: Equatable')+'\nenum Exporters {\n'
    threshold=next(row for row in export.splitlines() if 'private static let confidenceThreshold =' in row)
    source+=threshold+'\n'+'\n'.join(block(export,marker) for marker in ('static func markdown(', 'private static func renderWords(', 'static func plainText(', 'private static func timecode('))+'\n}\n'
    original=OUT/'OriginalArchiveTypes.swift'; original.write_text(source,encoding='utf-8')
    swift=OUT/'swift-archive'
    if not args.rust_only:
        subprocess.run(['swiftc','-parse-as-library',str(original),str(SPEAKER),str(ARCHIVE),str(ROOT/'tests/parity/ArchiveOracle.swift'),'-o',str(swift)],check=True)
    subprocess.run(['cargo','build','--locked','-p','madi-platform','--example','archive_oracle'],cwd=ROOT,check=True)
    cases,fixtures,fixture_words=corpus(); payload=json.dumps(cases,ensure_ascii=False,sort_keys=True).encode()
    suffix='.exe' if os.name=='nt' else ''
    rust=json.loads(subprocess.check_output([str(ROOT/'target/debug/examples'/('archive_oracle'+suffix))],input=payload))
    if not args.rust_only:
        expected=json.loads(subprocess.check_output([str(swift)],input=payload))
        if rust!=expected:
            for case,a,b in zip(cases,expected,rust):
                if a!=b:
                    (OUT/'mismatch.json').write_text(json.dumps(dict(case=case,swift=a,rust=b),ensure_ascii=False,indent=2),encoding='utf-8')
                    raise SystemExit('Archive mismatch: '+case['name']+'; see out/archive-parity/mismatch.json')
            raise SystemExit('Archive result count mismatch')
    report=dict(schemaVersion=1,status='passed',cases=len(cases),fixtureWords=fixture_words,
                swiftComparison='not-run' if args.rust_only else 'live-unmodified-export-methods-and-archive-source',
                sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in [STORE,EXPORT,ARCHIVE,SPEAKER,*fixtures]},
                corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(json.dumps(rust,sort_keys=True).encode()).hexdigest(),
                scope='Exact UTF-8 Markdown/plain export; reopened names, word times/confidence, translations and identity invariants. Fresh UUID values differ intentionally. Does not verify native UI, file writes, SRT/VTT/JSON export or invalid Swift-trapping numeric inputs.')
    keys=('cases','fixtureWords','sources','corpusSHA256','resultSHA256')
    if args.write_reference: REFERENCE.write_text(json.dumps({key:report[key] for key in keys},indent=2)+'\n',encoding='utf-8')
    reference=json.loads(REFERENCE.read_text(encoding='utf-8'))
    for key in keys: assert reference[key]==report[key],f'Archive reference differs: {key}'
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))

if __name__=='__main__': main()
