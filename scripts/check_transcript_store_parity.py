#!/usr/bin/env python3
"""Replay synchronous transcript/edit state against the shipping Swift model.

No production Swift method body is changed. A same-file extension supplies
fixture UUIDs and explicitly delivers the render timer. The synchronous main
does not yield to the Swift MainActor: no wall-clock timer races enter this
model comparison. Native timer scheduling and visible UI need separate gates.
"""
import argparse
import copy
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/transcript-store-parity'
REFERENCE = ROOT / 'design/parity/transcript-store-reference.json'
BASE = ROOT / 'apps/macos/Sovereign'
SOURCES = [BASE / ('Transcript/' + name + '.swift') for name in
           ('TranscriptStore', 'WordMerger', 'SpeakerID', 'SpeakerDisplayNumber', 'LiveFeatureWiring', 'EnergyArc')]
SOURCES.append(BASE / 'Engine/EngineProtocol.swift')
HOOK = '''
extension TranscriptStore {
    func oracleIngestWord(_ word: Word) { merger.add(word); rebuildLive() }
    func oracleDeliverRender() {
        guard renderScheduled else { return }
        renderScheduled = false
        publishDisplayLines(lines, invalidateEnergy: false)
    }
    var oracleRenderPending: Bool { renderScheduled }
    var oracleFixPending: Bool { spkFixRebuildScheduled }
    var oracleDisplayRevision: UInt64 { displayRevision }
}
'''

def word(t0, t1, text, conf=1.0, **kw):
    return dict(op='word', word=dict(t0=t0, t1=t1, text=text, conf=conf), **kw)

def label(op, time, speaker, duration=1.5, margin=1.0, **kw):
    return dict(op=op, label=dict(time=time, id=speaker, duration=duration, margin=margin), **kw)

def corpus():
    cases=[]
    def case(name, steps, **features):
        steps=copy.deepcopy(steps)
        for i, step in enumerate(steps):
            if 'word' in step: step['word']['id']=str(uuid.UUID(int=i+1))
        cases.append(dict(name=name, features=dict(join=True,ledger=True,turnHead=True,island=False,weak=0.0,minSeconds=10.0)|features,steps=steps))
    case('empty-boundaries', [dict(op=op) for op in ('snapshot','render','flushFix','archive','load','break','finish','reset','render','finish')])
    for gap, ending in itertools.product((.299,.3,.301,1.499,1.5,1.501), ('word','word.','word。','word…','word\n','word.\u200b')):
        case(f'gap-{gap}-{ending}', [label('speaker',0,2),word(0,.5,ending),word(.5+gap,2.5,'tail'),dict(op='break'),word(3,3.5,'next'),dict(op='finish'),dict(op='render')])
    for n, interval, ending in itertools.product((15,16,27,28,29,65),(.2,.5,1.0),(',', '，', ';', 'word')):
        steps=[label('speaker',0,7,100)]
        for i in range(n):
            steps.append(word(i*interval,(i+1)*interval,ending if i%16==15 else f'w{i}',inspect=i%7==0))
            if i%4==3: steps.append(dict(op='break',inspect=False))
        case(f'cap-{n}-{interval}-{ending}',steps+[dict(op='finish'),dict(op='render')])
    base=[label('speaker',0,7,5),word(0,.5,'Hello'),word(.6,.9,'world'),dict(op='break'),dict(op='render')]
    for edit in ('HELLO WORLD!', 'hello world', 'Something else', '  ', 'é', 'e\u0301', 'ΟΣ', 'ος', 'hello\u200bworld', 'Hello 👩‍👩‍👧‍👦'):
        case('overlays-'+edit,base+[
            dict(op='remember'),dict(op='translate',lang='en',text=' English ',revision='current'),
            dict(op='translate',lang='ja',text='日本語',userEdited=True),dict(op='suppress',lang='ja'),
            dict(op='edit',text=edit,revision='bad'),dict(op='edit',text=edit,revision='saved'),
            dict(op='translate',lang='en',text='stale result',revision='saved'),
            dict(op='suppress',lang='en',revision='current'),dict(op='editWord',wordIndex=0,text='Confirmed'),
            dict(op='translate',lang='en',text='Fresh',revision='current'),
            dict(op='prune',targets=['en'],revision='current'),dict(op='archive'),dict(op='load'),
            dict(op='suppress',lang='en'),dict(op='edit',text='CONFIRMED WORLD!'),dict(op='render'),
            word(1.1,1.4,'incoming'),dict(op='break'),dict(op='finish'),dict(op='render'),dict(op='reset')])
    for before,after in [('é','e\u0301'),('가','가'),('ΟΣ','οσ'),('ΟΣ','ος'),('Hi!\u0301','hi'),('Hi!','hi'),('9️⃣','9')]:
        case('cosmetic-'+before+'-'+after,[word(0,.4,before),dict(op='translate',lang='en',text='translation'),dict(op='suppress',lang='ja'),dict(op='edit',text=after),dict(op='render'),dict(op='break'),dict(op='finish')])
    # Preserve the concrete frozen-prefix and edited-row regressions from
    # SameSpeakerJoinTests, not just random speaker changes.
    for edited,join in itertools.product((False,True),(False,True)):
        steps=[label('speaker',0,1,2,.9),label('speaker',2,2,2,.05),label('speaker',4,3,8,.9),dict(op='break')]
        for i,text in enumerate('It was during the pandemic so the story goes and then more'.split()):
            steps.append(word(i+.1,i+.9,text))
        steps += [dict(op='break'),dict(op='remember'),dict(op='translate',lang='en',text='old fragment',revision='current')]
        if edited: steps.append(dict(op='editWord',wordIndex=0,text='That'))
        steps += [label('fix',2,1,2,.9),dict(op='flushFix'),dict(op='render'),word(12.1,12.9,'after'),dict(op='break'),dict(op='finish'),dict(op='render')]
        case(f'frozen-join-edited-{edited}-enabled-{join}',steps,join=join)
    for margin,ending,island in itertools.product((.05,.349,.35,.9),('옛날에는','옛날에는.'),(False,True)):
        steps=[label('speaker',0,3,2,.9),label('speaker',2,11,1,margin),label('speaker',3,3,3,.9),dict(op='break')]
        for start,end,text in [(0.2,.8,'인간은'),(.9,1.4,'그걸'),(1.5,1.95,ending),(2.05,2.4,'판단할'),(2.45,2.7,'수가'),(2.75,2.95,'없었던'),(3.05,3.4,'거고'),(3.5,4,'판단해도'),(4.1,4.6,'문제가')]:
            steps.append(word(start,end,text))
        case(f'island-margin-{margin}-{ending}-{island}',steps+[dict(op='break'),word(4.7,5,'많았고'),dict(op='finish')],island=island)
    for first,second in ((1,7),(7,1),(255,1),(1,255)):
        case(f'merge-chain-{first}-{second}',[label('speaker',0,first,2),label('speaker',2,second,3),word(.1,.9,'one'),word(1.1,1.9,'two'),word(2.1,2.9,'three'),word(3.1,3.9,'four'),dict(op='break'),
             {'op':'merge','from':first,'into':second},{'op':'merge','from':second,'into':9},{'op':'merge','from':9,'into':first},dict(op='revert'),dict(op='finish')],minSeconds=0)
    case('reset-with-pending-timers',base+[label('fix',0,9),dict(op='reset'),dict(op='flushFix'),dict(op='render'),word(0,.3,'new'),dict(op='finish'),dict(op='render')])
    case('invalid-edit-targets',base+[dict(op='editWord',wordIndex=-1,text='no'),dict(op='editWord',wordIndex=999,text='no'),dict(op='editWord',wordIndex=0,text='\t '),dict(op='translate',index=999,lang='en',text='no'),dict(op='edit',index=999,text='no'),dict(op='suppress',index=999,lang='en'),dict(op='prune',index=999,targets=['en'])])
    for island, weak, ledger, turn_head, join in itertools.product((False,True),(0.0,.2),(False,True),(False,True),(False,True)):
        steps=[]
        for i in range(54):
            speaker=7 if i%12<5 or i%12>7 else 9
            steps += [label('speaker',i*.5,speaker,.49,.1 if speaker==9 else .8,inspect=False),word(i*.5,i*.5+.45,f'w{i}',.8,inspect=i%4==0)]
            if i%3==2: steps.append(dict(op='break',inspect=False))
        steps += [dict(op='remember'),dict(op='translate',lang='en',text='old'),label('fix',0,9),label('fix',.5,9),dict(op='flushFix'),dict(op='render'),
                  dict(op='merge',from_=7,into=9),dict(op='relabel',index=1,into=255),dict(op='revert'),dict(op='finish'),dict(op='render')]
        for step in steps:
            if 'from_' in step: step['from']=step.pop('from_')
        case(f'features-{island}-{weak}-{ledger}-{turn_head}-{join}',steps,island=island,weak=weak,ledger=ledger,turnHead=turn_head,join=join,minSeconds=0)
    for broken in (False,True):
        steps=[label('speaker',0,7,10),label('speaker',5,9,10),word(0,1,'A'),word(2,3,'B.'),word(6,7,'C'),dict(op='break'),word(8,9,'D'),
               label('fix',.004,3,10),label('fix',.005,5,10),label('fix',.006,11,10),label('overlap',1,255,8),label('overlap',1,255,8),dict(op='flushFix')]
        if broken: steps.append(dict(op='broken'))
        case('fix-dedup-broken-'+str(broken),steps+[dict(op='finish'),dict(op='render'),dict(op='overlapReset'),dict(op='render'),dict(op='reset'),dict(op='flushFix')])
    rng=random.Random(813371)
    for seed in range(120):
        steps=[];time=0.0
        for i in range(90):
            roll=rng.randrange(16)
            if roll<7:
                time+=rng.choice((.1,.3,.5,1.5,2.0))
                steps.append(word(time,time+rng.choice((.04,.1,.4)),rng.choice(('hello','world.','네','안녕,','é','e\u0301','?', '👩‍👩‍👧‍👦','ΟΣ')),rng.choice((.2,.8,1.0))))
            elif roll==7: steps.append(label('speaker',time,rng.choice((0,2,7,9,255)),rng.choice((.2,1.5,3)),rng.choice((.1,.34,.35,.8,1.0))))
            elif roll==8: steps.append(label('fix',max(0,time-rng.choice((0,1,3))),rng.choice((0,2,7)),margin=.4))
            elif roll==9: steps.append(dict(op='break'))
            elif roll==10: steps.append(dict(op='flushFix'))
            elif roll==11: steps.append(dict(op='translate',index=rng.randrange(4),lang=rng.choice(('en','ja')),text='translated',revision=rng.choice(('bad','current')),userEdited=rng.choice((False,True))))
            elif roll==12: steps.append(dict(op='edit',index=rng.randrange(4),text=rng.choice(('corrected','É','안녕하세요!',' '))))
            elif roll==13: steps.append(dict(op='relabel',index=rng.randrange(4),into=rng.choice((0,2,255))))
            elif roll==14: steps.append(label('overlap',time-1,rng.choice((0,2,255)),3))
            else: steps.append(dict(op='render'))
            steps[-1]['inspect']=i%4==0
        case('random-'+str(seed),steps+[dict(op='flushFix'),dict(op='finish'),dict(op='render'),dict(op='archive'),dict(op='load'),dict(op='reset')],island=seed%2==1,weak=.2 if seed%2 else 0)
    fixtures=sorted((ROOT/'web/fixtures').glob('*.events.jsonl'));fixture_words=0
    for path in fixtures:
        steps=[]
        for raw in path.read_text(encoding='utf-8').splitlines():
            v=json.loads(raw);typ=v.get('t')
            if typ=='word':
                fixture_words+=1;steps.append(word(v['t0'],v['t1'],v['text'],v.get('conf',1)))
            # Checked-in JSONL files supply actual word payloads only. Their
            # `seg` rows are metadata, not stdout WordSectionBegin markers;
            # `spk_seg` rows are text paragraphs, not acoustic label windows.
            # Never fabricate those missing stdout events from JSONL metadata.
            else: continue
            steps[-1]['inspect']=len(steps)%31==0
        case(path.name,steps+[dict(op='flushFix'),dict(op='finish'),dict(op='render')],island='ko' in path.name,weak=.2 if 'ko' in path.name else 0)
    return cases,fixtures,fixture_words

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only',action='store_true');parser.add_argument('--write-reference',action='store_true')
    args=parser.parse_args()
    if args.write_reference and args.rust_only: parser.error('A reference requires live Swift')
    OUT.mkdir(parents=True,exist_ok=True)
    source=OUT/'OriginalTranscriptStore.swift'
    source.write_text(SOURCES[0].read_text(encoding='utf-8')+HOOK,encoding='utf-8')
    swift=OUT/'swift-transcript-store'
    if not args.rust_only:
        subprocess.run(['swiftc','-parse-as-library',str(source),*[str(p) for p in SOURCES[1:]],str(ROOT/'tests/parity/TranscriptStoreOracle.swift'),'-o',str(swift)],check=True)
    subprocess.run(['cargo','build','--locked','-p','madi-platform','--example','transcript_store_oracle'],cwd=ROOT,check=True)
    cases,fixtures,fixture_words=corpus();payload=json.dumps(cases,ensure_ascii=False,sort_keys=True).encode()
    suffix='.exe' if os.name=='nt' else ''
    rust=json.loads(subprocess.check_output([str(ROOT/'target/debug/examples'/('transcript_store_oracle'+suffix))],input=payload))
    if not args.rust_only:
        expected=json.loads(subprocess.check_output([str(swift)],input=payload))
        if rust!=expected:
            for case,a,b in zip(cases,expected,rust):
                if a!=b:
                    for i,(sa,sb) in enumerate(zip(a,b)):
                        if sa!=sb:
                            inspected=[j for j,s in enumerate(case['steps']) if s.get('inspect',True)]
                            report=dict(case=case,step=inspected[i],snapshot=i,swift=sa,rust=sb)
                            (OUT/'mismatch.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
                            raise SystemExit(f'Transcript store mismatch: {case["name"]} step {inspected[i]}; see {OUT}/mismatch.json')
                    raise SystemExit('Transcript store snapshot count mismatch')
            raise SystemExit('Transcript store case count mismatch')
    report=dict(schemaVersion=1,status='passed',cases=len(cases),snapshots=sum(map(len,rust)),fixtureWords=fixture_words,
                swiftComparison='not-run' if args.rust_only else 'live-unmodified-model-bodies-with-deterministic-ID-and-render-delivery-hooks',
                sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in [*SOURCES,*fixtures]},
                corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(json.dumps(rust,sort_keys=True).encode()).hexdigest(),
                scope='Finite transcript inputs plus 1566 fixture word payloads (not full stdout replay): exact line/word identity, text bytes, times/confidence, grouping, speaker fixes/numbers, overlap, edits, translation provenance, suppression, reload/reset and explicit display delivery. No wall-clock scheduling, UI pixels, translation generation or archive serialization.')
    keys=('cases','snapshots','fixtureWords','sources','corpusSHA256','resultSHA256')
    if args.write_reference: REFERENCE.write_text(json.dumps({k:report[k] for k in keys},indent=2)+'\n')
    reference=json.loads(REFERENCE.read_text())
    for key in keys: assert reference[key]==report[key],f'Transcript store reference differs: {key}'
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))

if __name__=='__main__': main()
