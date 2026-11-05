#!/usr/bin/env python3
"""Compare review policy and navigation with the shipping Swift implementations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/review-parity'
REFERENCE = ROOT / 'design/parity/review-reference.json'
SOURCES = [ROOT / 'apps/macos/Sovereign' / p for p in ('Transcript/ReviewController.swift', 'UI/TranscriptView.swift')]

def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')

def cases():
    rng = random.Random(2026110517)
    texts = ['', ' ', '\t', '\n', '\u200b', '\u00a0', ' word ', '검토', 'cafe\u0301', ',', '.', '!', '?', '…', '!\ufe0f', ',\u0301', '🙂', '👩\u200d💻', '\t\nword\n\t']
    controllers = []
    for case in range(800):
        versions = []
        for v in range(3):
            lines = []
            for li in range(rng.randrange(4)):
                words = [dict(text=rng.choice(texts), conf=rng.choice([0, .35, .549999999999, .55, .550000000001, .8, .9, 1]), t0=li*5 + wi*.25, t1=li*5+wi*.25+rng.choice([0,.125,.25])) for wi in range(rng.randrange(7))]
                lines.append(dict(id=str(uuid.UUID(int=li+1)), words=words))
            versions.append(dict(lines=lines, threshold=[.55,.9,.35][v]))
        # Explicit empty-leading-word and strict threshold cases complement random traces.
        if case < len(texts):
            versions[0]['lines'] = [dict(id=str(uuid.UUID(int=1)), words=[dict(text='',conf=.4,t0=0,t1=.25),dict(text=texts[case],conf=.55,t0=.25,t1=.5),dict(text='last',conf=.4,t0=.5,t1=.75)])]
        actions = [dict(type='toggle',canPlay=True),dict(type='refresh',version=0),dict(type='toggle',canPlay=False),dict(type='toggle',canPlay=True)]
        for _ in range(26):
            kind = rng.choice(['refresh','toggle','advance','advance','stop','jump'])
            action = dict(type=kind)
            if kind == 'refresh': action['version'] = rng.randrange(3)
            if kind == 'toggle': action['canPlay'] = rng.choice([True,False])
            if kind == 'jump': action['delta'] = rng.choice([-11,-2,-1,0,1,2,11])
            actions.append(action)
        controllers.append(dict(versions=versions,actions=actions))
    navigation=[]
    for i in range(400):
        count=i%12
        words=[dict(lineId=str(uuid.UUID(int=j//3+1)),wordIndex=j%3,text=f'word {j} 검토') for j in range(count)]
        index=None if not count or i%17==0 else rng.randrange(count)
        navigation.append(dict(words=words,index=index,delta=rng.choice([-13,-1,0,1,13]),draft=rng.choice(['edited','', '  ', '다음'])) )
    return dict(controllers=controllers,navigation=navigation)

SWIFT = r'''
import Foundation
struct Word: Decodable { let text: String; let conf: Double; let t0: Double; let t1: Double }
struct Line: Decodable { let id: UUID; let words: [Word] }
struct Version: Decodable { let lines: [Line]; let threshold: Double }
struct Action: Decodable { let type: String; let version: Int?; let canPlay: Bool?; let delta: Int? }
struct Case: Decodable { let versions: [Version]; let actions: [Action] }
struct NavWord: Decodable { let lineId: UUID; let wordIndex: Int; let text: String }
struct NavCase: Decodable { let words:[NavWord]; let index:Int?; let delta:Int; let draft:String }
struct Input: Decodable { let controllers:[Case]; let navigation:[NavCase] }
@MainActor enum Theme { static var confThreshold = 0.55 }
@MainActor struct Refs {
    let lines:[Line]
    __REFS__
    func result() -> [[String:Any]] { flaggedRefs.map { ["lineId":$0.lineID.uuidString.lowercased(),"wordIndex":$0.wordIndex,"text":$0.text] } }
}
@MainActor final class NavProbe {
    var flaggedRefs:[(lineID:UUID,wordIndex:Int,text:String)]
    var reviewRefIndex:Int?
    var reviewDraft:String
    var onEditWord:((UUID,Int,String)->Void)? = nil
    init(_ c:NavCase) { flaggedRefs=c.words.map{($0.lineId,$0.wordIndex,$0.text)}; reviewRefIndex=c.index; reviewDraft=c.draft }
    __MOVE__
    __APPLY__
    func applyResult() -> [String:Any] { applyReview(); return ["index":reviewRefIndex as Any? ?? NSNull(),"draft":reviewDraft] }
    func moveResult(_ delta:Int) -> [String:Any] { moveReview(delta); return ["index":reviewRefIndex as Any? ?? NSNull(),"draft":reviewDraft] }
}
func span(_ s:ReviewSpan) -> [String:Any] { ["lineId":s.lineID.uuidString.lowercased(),"text":s.text,"t0":s.t0,"t1":s.t1] }
@main struct Main {
    @MainActor static func main() throws {
        let input=try JSONDecoder().decode(Input.self,from:FileHandle.standardInput.readDataToEndOfFile())
        let result:[[String:Any]]=input.controllers.map { c in
            let controller=ReviewController()
            let trace:[[String:Any]]=c.actions.map { action in
                var result:ReviewSpan? = nil
                switch action.type {
                case "refresh": let v=c.versions[action.version!]; controller.refresh(lines:v.lines,threshold:v.threshold)
                case "toggle": result=controller.toggleListening(canPlay:action.canPlay!)
                case "advance": result=controller.advance()
                case "stop": controller.stop()
                case "jump": controller.manualJump(action.delta!)
                default: fatalError("unknown action")
                }
                return ["listening":controller.isListening,"index":controller.index,"current":controller.current.map(span) as Any? ?? NSNull(),"queue":controller.queue.map(span),"result":result.map(span) as Any? ?? NSNull()]
            }
            let spacing=c.versions.map { v in v.lines.map { line in
                var spaces:[Bool]=[]
                for (i,w) in line.words.enumerated() { spaces.append(__SPACING__) }
                return spaces
            }}
            let refs=c.versions.map { v in Theme.confThreshold=v.threshold;return Refs(lines:v.lines).result() }
            return ["trace":trace,"spacing":spacing,"refs":refs]
        }
        let navigation=input.navigation.map { c in ["apply":NavProbe(c).applyResult(),"move":NavProbe(c).moveResult(c.delta)] }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:["native":result,"navigation":navigation],options:[.sortedKeys]))
    }
}
'''

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rust-only',action='store_true')
    p.add_argument('--write-reference',action='store_true')
    a=p.parse_args()
    assert not (a.rust_only and a.write_reference)
    OUT.mkdir(parents=True,exist_ok=True)
    data=cases();payload=encoded(data);(OUT/'corpus.json').write_bytes(payload)
    subprocess.run(['cargo','build','--locked','-p','madi-core','--example','review_oracle'],cwd=ROOT,check=True)
    binary=ROOT/'target/debug/examples'/('review_oracle.exe' if os.name=='nt' else 'review_oracle')
    actual=dict(native=json.loads(subprocess.check_output([str(binary)],input=payload)),navigation=json.loads(subprocess.check_output(['node','tests/parity/review_frontend_oracle.mjs'],cwd=ROOT,input=payload)))
    (OUT/'rust-and-frontend.json').write_bytes(encoded(actual))
    if not a.rust_only:
        assert platform.system()=='Darwin'
        source=SOURCES[1].read_text(encoding='utf-8')
        refs=source[source.index('    private var flaggedRefs:'):source.index('    private var currentReviewRef:')]
        move=source[source.index('    private func moveReview('):source.index('    private func applyReview(')]
        start=source.index('    private func applyReview(');apply=source[start:source.index('\n    }',start)+6]
        predicate=re.search(r'if (i > 0, w\.text\.first\.map\(\{ !".*?"\.contains\(\$0\) \}\) \?\? true) \{',source)
        assert predicate
        spacing='i > 0 && ('+predicate[1].split(', ',1)[1]+')'
        driver=OUT/'ReviewOracle.swift'
        driver.write_text(SWIFT.replace('__REFS__',refs).replace('__MOVE__',move).replace('__APPLY__',apply).replace('__SPACING__',spacing),encoding='utf-8')
        oracle=OUT/'swift-oracle'
        subprocess.run(['xcrun','swiftc','-parse-as-library',str(SOURCES[0]),str(driver),'-o',str(oracle)],check=True)
        expected=json.loads(subprocess.check_output([str(oracle)],input=payload));(OUT/'swift.json').write_bytes(encoded(expected))
        for group in ['native','navigation']:
            assert len(expected[group])==len(actual[group])
            for i,(want,got) in enumerate(zip(expected[group],actual[group],strict=True)):
                assert want==got,(group,i,want,got)
    report=dict(controllerCases=len(data['controllers']),transitions=sum(len(c['actions']) for c in data['controllers']),navigationCases=len(data['navigation']),corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(encoded(actual)).hexdigest(),sources={s.relative_to(ROOT).as_posix():hashlib.sha256(s.read_bytes()).hexdigest() for s in SOURCES})
    if a.write_reference:REFERENCE.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    else:assert report==json.loads(REFERENCE.read_text(encoding='utf-8')),'Review reference changed'
    report.update(status='passed',nativeSwiftRun=not a.rust_only,scope='Unchanged shipping ReviewController with Line/Word input scaffolding; original flaggedRefs, moveReview and applyReview bodies; original word-spacing predicate. No audio, SwiftUI geometry, focus or native interaction acceptance.')
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
