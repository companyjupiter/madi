#!/usr/bin/env python3
"""Compare live-preview scheduling, text policy and UI progression to shipping Swift."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import subprocess
from check_asr_config_parity import block

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/preview-parity'
REFERENCE = ROOT / 'design/parity/preview-reference.json'
SWIFT = ROOT / 'apps/macos/Sovereign'


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def cases():
    values = ['', 'hello world', '별이 파편이 사방', '별 파편이 사방으로', 'Hello, world!',
              '日本語の字幕。', 'café', 'cafe\u0301', '한글', '한글', '👩🏽‍💻 family 👨‍👩‍👧‍👦',
              'a  b c', ' a\tb\nc ', '\u200bhello\u200b', 'a \u0301b c', '  ', '?! …', 'İ ΣΟΣ']
    result = []
    rng = random.Random(51322)
    for _ in range(350):
        text, gate, forced = rng.choices(values, k=3)
        result.append(dict(kind='trim', committed=rng.choices(values, k=rng.randrange(4)),
                           gate=gate, words=rng.choices(values+['.', ',', '!', '?', '…'], k=rng.randrange(6)),
                           forced=forced, text=text, count=rng.randrange(6)))
    for n in (0, 1, 511, 512, 513):
        for unit in ('한', '👩🏽‍💻', 'e\u0301'):
            result.append(dict(kind='trim', committed=[], gate='', words=[unit*n], forced='', text=unit*n, count=0))
    for fast in (True, False):
        for stall in (0, 1, 3, 5):
            sequences = [
                ['Hello. today is cloud', 'hello today is clear', 'new one', 'new two', 'new three four five', None, 'reset window'],
                ['café 한글', 'cafe\u0301 한글 more', 'café 한글 more tail', '', None, ''],
            ] + [rng.choices(values, k=20) for _ in range(25)]
            result += [dict(kind='gate', maxStall=stall, fastFirst=fast, sequence=sequence) for sequence in sequences]
    feed = lambda n: dict(op='feed', id=str(n), offset=n/2)
    event = lambda name, text='': dict(op='event', event=name, text=text)
    start = dict(op='start'); stop = dict(op='stop')
    operations = [feed(0), start, dict(op='admit', value=False), feed(1), feed(2),
                  dict(op='admit', value=True), feed(3), feed(4), event('begin'), event('word',' forced '),
                  event('word','0'), event('word','tail'), event('partial'), event('segment'), event('end'),
                  event('begin'), event('word','next'), event('end'), stop, feed(5), event('flush'), start, feed(6)]
    result.append(dict(kind='scheduler', operations=operations))
    options = [start, stop, dict(op='admit', value=False), dict(op='admit', value=True),
               event('begin'), event('end'), event('partial'), event('word',' 한글 '), event('word','!'), event('segment'), event('flush')]
    for _ in range(35):
        result.append(dict(kind='scheduler', operations=[rng.choice(options+[feed(i)]) for i in range(60)]))
    dedupes = [
        ('The thing that I think will save', 'will save us as a world'),
        ('goes the wrong way and', 'goes the wrong way. A lot of mistakes.'),
        ("Where's your ring? They didn't give you. They didn't yet. No, I'm going to.", "But it is so great. Where's your ring? They didn't give you... They didn't yet. No, I'm gonna"),
        ('I think that is right, and we should move on. Let me explain the plan.', 'I think that we should try again'),
    ] + [(rng.choice(values), rng.choice(values)) for _ in range(250)]
    result += [dict(kind='dedupe', tail=tail, hypothesis=hypothesis, minAnchor=anchor) for tail, hypothesis in dedupes for anchor in (1,3,6)]
    for n in (1,2,3,40,41,120,121,512):
        for unit in ('한', '👩🏽‍💻', 'e\u0301'):
            result.append(dict(kind='typing', shown='', target=unit*n))
    result += [dict(kind='typing', shown=a, target=b) for a,b in [('', ''), ('abc',''), ('abc','ab'), ('abc','abd'), ('cafe\u0301','café'), ('café','cafe\u0301 next')]]
    return result


DRIVER = r'''
@MainActor final class Typer {
    var frames:[String]=[]
    var shownInterim:String { didSet { if oldValue != shownInterim { frames.append(shownInterim) } } }
    var typerTask:Task<Void,Never>? = nil
    init(_ shown:String) { shownInterim=shown }
    TYPEWRITER
}
@main enum Driver {
    @MainActor static func main() async throws {
        let cases=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [[String:Any]]
        var results:[Any]=[]
        for c in cases {
            switch c["kind"] as! String {
            case "trim":
                let text=c["text"] as! String
                let words=(c["words"] as! [String]).map { PreviewTrim.TimedWord(t0:0,t1:0.1,text:$0) }
                results.append(["forced":PreviewTrim.forcedPrefix(committed:c["committed"] as! [String],gate:c["gate"] as! String),"tail":PreviewTrim.visibleTail(words:words,forced:c["forced"] as! String),"counted":PreviewTrim.trimByCount(text,dropping:c["count"] as! Int),"bounded":!text.isEmpty && text.count <= 512])
            case "gate":
                var gate=InterimSourceGate(maxStall:c["maxStall"] as! Int,fastFirst:c["fastFirst"] as! Bool)
                var rows:[[String:String]]=[]
                for v in c["sequence"] as! [Any] {
                    let shown:String
                    if let text=v as? String {shown=gate.commit(text)} else {gate.reset();shown=""}
                    rows.append(["shown":shown,"committed":gate.committedText])
                }
                results.append(rows)
            case "scheduler":
                let lane=PreviewEngine();var submitted:[[String:Any]]=[];var shown:[String]=[];var rows:[[String:Any]]=[]
                lane.onWords={words,_,forced in shown.append(PreviewTrim.visibleTail(words:words,forced:forced))}
                for op in c["operations"] as! [[String:Any]] {
                    var consumed:Any=NSNull()
                    switch op["op"] as! String {
                    case "start":lane.start { url,offset in let forced="forced \(submitted.count)";submitted.append(["id":url.lastPathComponent,"offset":offset,"forced":forced]);return forced }
                    case "stop":lane.stop()
                    case "admit":lane.setAdmitted(op["value"] as! Bool)
                    case "feed":lane.feed(wav:URL(fileURLWithPath:"/owned/"+(op["id"] as! String)),offset:op["offset"] as! Double)
                    default:
                        let event:EngineEvent
                        switch op["event"] as! String {
                        case "begin":event = .previewBegin
                        case "end":event = .previewEnd
                        case "partial":event = .previewPartial("ignored")
                        case "word":event = .previewWord(t0:0,t1:0.1,text:op["text"] as! String)
                        case "segment":event = .segmentEnd
                        default:event = .flushEnd
                        }
                        consumed=lane.consume(event)
                    }
                    rows.append(["submitted":submitted,"shown":shown,"consumed":consumed])
                }
                results.append(rows)
            case "dedupe":results.append(InterimDedupe.continuation(committedTail:c["tail"] as! String,hypothesis:c["hypothesis"] as! String,minAnchor:c["minAnchor"] as! Int))
            case "typing":
                let typer=Typer(c["shown"] as! String);typer.syncInterim(c["target"] as! String)
                await typer.typerTask?.value
                results.append(typer.frames)
            default:fatalError("unknown case")
            }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]))
    }
}
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only',action='store_true')
    parser.add_argument('--write-reference',action='store_true')
    args=parser.parse_args()
    if args.write_reference and args.rust_only: parser.error('Native Swift required to write reference')
    if not args.rust_only and platform.system()!='Darwin': parser.error('Native Swift requires macOS')
    OUT.mkdir(parents=True,exist_ok=True)
    sources=[SWIFT/p for p in ('Engine/PreviewEngine.swift','Transcript/PreviewTrim.swift','Engine/TranslationStability.swift','Transcript/InterimDedupe.swift','UI/TranscriptView.swift','Engine/EngineProtocol.swift')]
    source_gate=block(sources[2].read_text(encoding='utf-8'), 'struct InterimSourceGate {')
    typing=block(sources[4].read_text(encoding='utf-8'), '    private func syncInterim(_ target: String) {').replace('private func','func',1)
    assert 'try? await Task.sleep(nanoseconds: 24_000_000)' in typing
    # Preserve every state transition; yield instead of sleeping between frames.
    typing=typing.replace('try? await Task.sleep(nanoseconds: 24_000_000)', 'await Task.yield()')
    payload=encoded(cases())
    (OUT/'cases.json').write_bytes(payload)
    subprocess.run([os.environ.get('CARGO','cargo'),'build','--locked','-p','madi-core','--example','preview_oracle'],cwd=ROOT,check=True)
    exe=ROOT/'target/debug/examples'/('preview_oracle.exe' if os.name=='nt' else 'preview_oracle')
    rust=json.loads(subprocess.check_output([str(exe)],input=payload))
    frontend=json.loads(subprocess.check_output(['node',str(ROOT/'tests/parity/preview_frontend_oracle.mjs')],input=payload))
    actual=[a if c['kind'] in ('trim','gate','scheduler') else b for c,a,b in zip(cases(),rust,frontend,strict=True)]
    (OUT/'result.json').write_bytes(encoded(actual))
    if not args.rust_only:
        driver=OUT/'PreviewOracle.swift'
        driver.write_text('import Foundation\n'+source_gate+'\n'+DRIVER.replace('TYPEWRITER',typing),encoding='utf-8')
        binary=OUT/'swift-oracle'
        subprocess.run(['xcrun','swiftc','-parse-as-library',str(driver),*[str(sources[i]) for i in (0,1,3,5)],'-o',str(binary)],check=True)
        expected=json.loads(subprocess.check_output([str(binary)],input=payload))
        (OUT/'swift.json').write_bytes(encoded(expected))
        for i,(case,want,got) in enumerate(zip(cases(),expected,actual,strict=True)):
            assert want==got,json.dumps(dict(index=i,case=case,swift=want,actual=got),ensure_ascii=False,indent=2)
    report=dict(cases=len(cases()),corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(encoded(actual)).hexdigest(),sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},typewriterTickMilliseconds=24)
    if args.write_reference: REFERENCE.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    else: assert report==json.loads(REFERENCE.read_text(encoding='utf-8')),'Preview reference changed'
    report.update(status='passed',nativeSwiftRun=not args.rust_only,frontendRun=True)
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))


if __name__=='__main__':main()
