#!/usr/bin/env python3
"""Word identity, display and commit comparison against original WordMerger.swift."""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/word-merger-parity'
REFERENCE = ROOT / 'design/parity/word-merger-reference.json'
STORE = ROOT / 'apps/macos/Sovereign/Transcript/TranscriptStore.swift'
MERGER = ROOT / 'apps/macos/Sovereign/Transcript/WordMerger.swift'

def word(t0, t1, text, conf=1.0, inspect=True):
    return dict(op='word', word=dict(t0=t0, t1=t1, text=text, conf=conf), inspect=inspect)

def corpus():
    cases = []
    def case(name, steps):
        for index, step in enumerate(steps):
            if 'word' in step: step['word']['id'] = str(uuid.UUID(int=index + 1))
        cases.append(dict(name=name, steps=steps))
    case('held-redecode', [word(0, .4, 'A'), word(.5, .9, 'B'), dict(op='break'), word(.5, .9, 'B2'), word(1, 1.4, 'C'), dict(op='break'), dict(op='finish'), dict(op='finish')])
    case('empty', [dict(op='snapshot'), dict(op='break'), dict(op='finish')])
    case('only-held', [word(0, .4, 'only'), dict(op='break'), dict(op='finish')])
    for duration, confidence, gap in itertools.product((.059, .06, .061), (.349, .35, .351), (.049, .05, .051, .299, .3, .301)):
        case(f'stub-{duration}-{confidence}-{gap}', [word(0, .3, 'before'), word(.5, .5+duration, 'AI.', confidence), dict(op='break'), word(.5+duration+gap, 1.5, 'the'), word(1.6, 1.9, 'next'), dict(op='break'), dict(op='finish')])
    pairs = [('that.', 'THAT!'), ('네', '네'), ('é', 'e\u0301'), ('Å', 'A\u030a'), ('가', '가'), ('ΟΣ', 'ος'), ('İ', 'i\u0307'), ('㊈', '㊈'), ('⑩', '⑩'), ('9️⃣', '9'), ('👩‍👩‍👧‍👦', '👩‍👩‍👧‍👦'), ('.', '.'), ('', ''), ('Ⅷ', 'ⅷ'), ('᠑', '᠑')]
    for (before, after), gap in itertools.product(pairs, (.0, .05, .099, .1, .599, .6, .601)):
        case(f'seam-{before}-{gap}', [word(0, .4, before), dict(op='finish'), word(.4+gap, 1.6, after), word(1.7, 2.0, 'next'), dict(op='break'), dict(op='finish')])
        case(f'instant-{before}-{gap}', [word(0, .4, before), word(gap, 1.6, after), dict(op='finish')])
    for final in (False, True):
        case(f'held-only-strays-{final}', [word(.5, .9, 'held'), dict(op='break'), word(.2, .54, 'stray'), dict(op='finish' if final else 'break'), dict(op='snapshot')])
    for width, repeats in itertools.product(range(1, 7), (2, 4, 5, 9)):
        steps=[]
        for i in range(width*repeats): steps.append(word(i*.3, i*.3+.25, f'word{i%width}'))
        steps.append(dict(op='finish')); case(f'phrase-{width}-{repeats}', steps)
    for text in ('\u200bRepeat\u200b', '\u0085Repeat\u2028', ' é ', ' e\u0301 ', '\t네\n'):
        steps=[word(i*.3, i*.3+.25, text) for i in range(15)] + [dict(op='finish')]
        case('normalized-phrase-'+text, steps)
    fixture_words=0
    fixtures=sorted((ROOT / 'web/fixtures').glob('*.events.jsonl'))
    for path in fixtures:
        steps=[]
        for raw in path.read_text(encoding='utf-8').splitlines():
            value=json.loads(raw)
            if value.get('t')=='word':
                fixture_words += 1
                steps.append(word(value['t0'], value['t1'], value['text'], value.get('conf',1), inspect=len(steps)%16==0))
            # Fixture `seg` rows are metadata, not WordSectionBegin markers.
        steps.append(dict(op='finish')); case(path.name, steps)
    return cases, fixtures, fixture_words

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only',action='store_true');parser.add_argument('--write-reference',action='store_true')
    args=parser.parse_args()
    if args.write_reference and args.rust_only: parser.error('A reference requires live Swift')
    OUT.mkdir(parents=True,exist_ok=True)
    text=STORE.read_text(encoding='utf-8')
    original_word=text[text.index('struct Word:'):text.index('\nstruct Line:')]
    source=OUT/'OriginalWord.swift';source.write_text('import Foundation\n'+original_word,encoding='utf-8')
    swift=OUT/'swift-word-merger'
    if not args.rust_only:
        subprocess.run(['swiftc','-parse-as-library',str(source),str(MERGER),str(ROOT/'tests/parity/WordMergerOracle.swift'),'-o',str(swift)],check=True)
    subprocess.run(['cargo','build','--locked','-p','madi-platform','--example','word_merger_oracle'],cwd=ROOT,check=True)
    cases,fixtures,fixture_words=corpus();payload=json.dumps(cases,ensure_ascii=False,sort_keys=True).encode()
    suffix='.exe' if os.name=='nt' else ''
    rust=json.loads(subprocess.check_output([str(ROOT/'target/debug/examples'/('word_merger_oracle'+suffix))],input=payload))
    if not args.rust_only:
        expected=json.loads(subprocess.check_output([str(swift)],input=payload))
        if rust!=expected:
            for case,a,b in zip(cases,expected,rust):
                if a!=b:
                    report=dict(case=case,swift=a,rust=b)
                    (OUT/'mismatch.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
                    raise SystemExit('Word merger mismatch: '+case['name']+'; see out/word-merger-parity/mismatch.json')
            raise SystemExit('Word merger result count mismatch')
    report=dict(schemaVersion=1,status='passed',cases=len(cases),snapshots=sum(map(len,rust)),fixtureWords=fixture_words,
                swiftComparison='not-run' if args.rust_only else 'live-unmodified-merger-and-word-source',
                sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in [STORE,MERGER,*fixtures]},
                corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(json.dumps(rust,sort_keys=True).encode()).hexdigest(),
                scope='Finite word inputs: committed/display/suffix/since snapshots, exact times/confidence/text/UUID identity, held word, watermark and duplicate counters; not full transcript grouping or UI')
    keys=('cases','snapshots','fixtureWords','sources','corpusSHA256','resultSHA256')
    if args.write_reference: REFERENCE.write_text(json.dumps({k:report[k] for k in keys},indent=2)+'\n')
    reference=json.loads(REFERENCE.read_text())
    for key in keys: assert reference[key]==report[key],f'Word merger reference differs: {key}'
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__': main()
