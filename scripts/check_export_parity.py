#!/usr/bin/env python3
"""Compare SRT/VTT cues and complete editor-aware JSON against shipping Swift."""
import argparse
import copy
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import uuid
sys.dont_write_bytecode=True
from check_archive_parity import corpus as archive_corpus,word,line
from check_model_gate_parity import block

ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'out/export-parity';REFERENCE=ROOT/'design/parity/export-reference.json'
BASE=ROOT/'apps/macos/Sovereign/Transcript'
SOURCES=[BASE/name for name in ('TranscriptStore.swift','Exporters.swift','EditorCuts.swift','SpeakerID.swift')]

def corpus():
    cases,fixtures,fixture_words=archive_corpus()
    def case(name,lines,settings=None,spec=None):
        for index,value in enumerate(lines):value['id']=str(uuid.UUID(int=index+1))
        cases.append(dict(name=name,lines=lines,names={'0':'Ada','1':'이름'},settings=settings or {},spec=spec or {}))
    tokens=['Um,','UH…','음','으음','음음','어어','like','그','저','uh-huh','hmm','é','e\u0301','ΟΣ','ος','Σ','σ','',',','word','next','\u200b Um, \u200b',' \u0301mark','*\u0301','👩‍👩‍👧‍👦',' \t ','\r\n']
    rng=random.Random(2724)
    sample=[]
    for index in range(8):
        words=[word(text,rng.choice([.3,.8,.9,1]),index*30+j*.4) for j,text in enumerate(rng.choices(tokens,k=12))]
        sample.append(line(words,start=index*30,end=index*30+6,speaker=index%3))
    for values in itertools.product((False,True),repeat=6):
        settings=dict(zip(('enabled','fillers','silences','chapters','retakes','highlights'),values))
        case('toggles-'+str(values),copy.deepcopy(sample),settings)
    for width,rows,cps,duration,labelled in itertools.product((1,12,42),(0,1,2),(3,17),(.04,7),(None,False,True)):
        spec=dict(maxCharsPerLine=width,maxLines=rows,maxCPS=cps,maxDur=duration,speakerLabels=labelled)
        case('caption-'+str(spec),copy.deepcopy(sample[:3]),spec=spec)
    for edited in ('','edited source now',' \u0301alpha\t\u0301beta\r\ngamma','\u200bretained\u200b','👩‍👩‍👧‍👦 family .','a\nb\tc'):
        for start,end in ((-0.0,0),(-3,-1),(0,0),(2,1),(3,8),(59.999,60.001)):
            case('edited-'+repr(edited)+str((start,end)),[line([word('raw never returns')],start=start,end=end,editedText=edited)])
    repeated=['this','is','a','test']
    for confidence,threshold,min_tokens in itertools.product((.3,.9,1),(.5,.7,1),(0,3,5)):
        lines=[line([word(text,.9 if i==0 else confidence,start=i*4+j*.5) for j,text in enumerate(repeated)],start=i*4,end=i*4+3,editedText='overridden' if i==2 else None) for i in range(4)]
        case('retake-'+str((confidence,threshold,min_tokens)),lines,dict(retakeSim=threshold,retakeMinTokens=min_tokens))
    case('nullable-upgrade-settings',copy.deepcopy(sample),dict(enabled=None,fillers=None,silenceMinGap=None,hlMinWords=7))
    for index in range(90):
        lines=[];start=-.5
        for i in range(rng.randrange(1,15)):
            start+=rng.choice([0,.5,1,3,30]);words=[]
            for j,text in enumerate(rng.choices(tokens,k=rng.randrange(0,15))):words.append(word(text,rng.choice([0,.3,.55,.8,1]),start+j*.1))
            lines.append(line(words,start=start,end=start+rng.choice([0,1,2]),speaker=rng.choice([-1,0,1,2,255]),editedText=rng.choice([None,None,'edited text'])))
        case('random-'+str(index),lines,dict(silenceMinGap=rng.choice([0,.1,.6,1]),silencePad=rng.choice([0,.1,1]),chapterGap=rng.choice([0,2.5]),chapterMinLen=rng.choice([0,20]),hlMinPause=rng.choice([0,1,2])))
    return cases,fixtures,fixture_words

def canonical(results):
    # Swift Dictionary traversal makes equal-duration speaker ordering
    # nondeterministic. Preserve descending duration; only ties are canonicalized.
    for result in results:
        result.pop('jsonUtf8',None)
        result['json']['speakers'].sort(key=lambda s:(-s['talk_seconds'],s['speaker']))
    return results

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--rust-only',action='store_true');parser.add_argument('--write-reference',action='store_true');args=parser.parse_args()
    if args.write_reference and args.rust_only:parser.error('Reference requires live Swift')
    OUT.mkdir(parents=True,exist_ok=True)
    store=SOURCES[0].read_text(encoding='utf-8');source='import Foundation\n'+store[store.index('struct Word:'):store.index('/// Stable, process-independent')]+block(store,'enum SegmentStatus: Equatable')+'\n'
    wrappers=(ROOT/'tests/parity/ArchiveOracle.swift').read_text(encoding='utf-8');source+=wrappers[wrappers.index('struct InputWord:'):wrappers.index('struct Case:')]
    extracted=OUT/'OriginalExportTypes.swift';extracted.write_text(source,encoding='utf-8');swift=OUT/'swift-exports'
    if not args.rust_only:subprocess.run(['swiftc','-parse-as-library',str(extracted),*[str(path) for path in SOURCES[1:]],str(ROOT/'tests/parity/ExportOracle.swift'),'-o',str(swift)],check=True)
    subprocess.run(['cargo','build','--locked','-p','madi-platform','--example','export_oracle'],cwd=ROOT,check=True)
    cases,fixtures,fixture_words=corpus();payload=json.dumps(cases,ensure_ascii=False,sort_keys=True).encode();suffix='.exe' if os.name=='nt' else ''
    rust=json.loads(subprocess.check_output([str(ROOT/'target/debug/examples'/('export_oracle'+suffix))],input=payload))
    formatting_cases=0
    if not args.rust_only:
        expected=json.loads(subprocess.check_output([str(swift)],input=payload))
        for case,a,b in zip(cases,expected,rust):
            durations=[speaker['talk_seconds'] for speaker in a['json']['speakers']]
            if len(set(durations))==len(durations):
                formatting_cases+=1
                if a['jsonUtf8']!=b['jsonUtf8']:
                    (OUT/'format-mismatch.json').write_text(json.dumps(dict(case=case,swift=bytes.fromhex(a['jsonUtf8']).decode(),rust=bytes.fromhex(b['jsonUtf8']).decode()),ensure_ascii=False,indent=2),encoding='utf-8')
                    raise SystemExit('Native JSON formatting mismatch: '+case['name'])
        expected=canonical(expected)
        rust=canonical(rust)
        if rust!=expected:
            for case,a,b in zip(cases,expected,rust):
                if a!=b:
                    (OUT/'mismatch.json').write_text(json.dumps(dict(case=case,swift=a,rust=b),ensure_ascii=False,indent=2),encoding='utf-8');raise SystemExit('Export mismatch: '+case['name'])
            raise SystemExit('Export result count differs')
    rust=canonical(rust)
    report=dict(schemaVersion=1,status='passed',cases=len(cases),fixtureWords=fixture_words,captionCues=sum(len(r['cues']) for r in rust),nativeJSONFormattingCases=formatting_cases,swiftComparison='not-run' if args.rust_only else 'live-unmodified-exporters-and-editor-cuts',
        sources={str(path.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(path.read_bytes()).hexdigest() for path in [*SOURCES,*fixtures]},corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(json.dumps(rust,sort_keys=True).encode()).hexdigest(),
        scope='Finite supported numeric inputs: exact SRT/VTT UTF-8, cue float bits/text, complete JSON data including editor analysis, and upgrade-safe editor defaults. Live macOS also compares exact JSON formatting when speaker ordering is deterministic. Nondeterministic equal-duration speaker ordering is canonicalized. No native save dialogs or UI.')
    keys=('cases','fixtureWords','captionCues','sources','corpusSHA256','resultSHA256')
    if args.write_reference:REFERENCE.write_text(json.dumps({k:report[k] for k in keys},indent=2)+'\n',encoding='utf-8')
    reference=json.loads(REFERENCE.read_text(encoding='utf-8'))
    for key in keys:assert report[key]==reference[key],f'Export reference differs: {key}'
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
