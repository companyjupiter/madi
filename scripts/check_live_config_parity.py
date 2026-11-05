#!/usr/bin/env python3
"""Compare native live launch and capture settings with extracted shipping Swift."""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import subprocess
from check_asr_config_parity import block, KEYS

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/live-config-parity'
REFERENCE=ROOT/'design/parity/live-config-reference.json'
ENGINE=ROOT/'apps/macos/Sovereign/Engine/EngineProcess.swift'
SESSION=ROOT/'apps/macos/Sovereign/SessionController.swift'
PATH_POLICY=ROOT/'apps/macos/Sovereign/Engine/EnginePathPolicy.swift'


def encoded(value):
    return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rust-only',action='store_true')
    parser.add_argument('--write-reference',action='store_true')
    args=parser.parse_args()
    if args.write_reference and args.rust_only: parser.error('Live Swift required to pin a reference')
    if not args.rust_only and platform.system()!='Darwin': parser.error('Live Swift requires macOS')
    OUT.mkdir(parents=True,exist_ok=True)
    engine=ENGINE.read_text(encoding='utf-8'); session=SESSION.read_text(encoding='utf-8')
    assert 'static let voiceprintsEnabled = false' in session, 'Voiceprint product gate changed'
    config=block(engine,'    struct Config {')
    launch=engine[engine.index('        process.executableURL = config.binaryURL'):engine.index('        process.environment = env')+len('        process.environment = env')]
    speakers=session[session.index('enum SpeakerCount:'):]
    properties='\n'.join(block(speakers,'    var '+name) for name in ('maxSpeakers: Int','fixedK: Int?','vadProb: Double'))
    policy='\n'.join(block(session,signature) for signature in ('    private var langCandidatePair: [Int] {','    var multiTranslateForcesAccurate: Bool {','    var effectiveWindowSeconds: Double {'))
    start=session.index('        let win = effectiveWindowSeconds')
    end=session.index('        capture.onSegment =',start)
    capture_settings=session[start:end]
    driver=OUT/'LiveConfigOracle.swift'
    driver.write_text('''import Foundation
enum SpeakerCount: Int { case auto = 0, two = 2, three = 3, four = 4, fivePlus = 5
'''+properties+'''
}
struct LaunchOracle {
'''+config+'''
    let config:Config; let process=Process()
    let eventsURL=URL(fileURLWithPath:"/madi/owned/events.jsonl")
    func build() {
'''+launch+'''
    }
}
final class CaptureValues { var segmentSeconds=10.0; var firstSegmentSeconds=1.5; var overlapSeconds=3.0 }
struct Policy {
    let translateTargets:Set<String>; let languageTokenID:Int?; let liveWindowSeconds:Double
'''+policy+'''
    var candidates:[Int] { langCandidatePair }
    func apply(_ capture:CaptureValues) {
'''+capture_settings+'''
    }
}
struct Case:Decodable {
    let speakerCount:Int; let diarize:Bool; let osd:Bool; let inputLanguage:String?; let restoredLanguage:Int?
    let targets:[String]; let physicalMemory:UInt64; let biasTerms:[String]; let window:Double; let preview:Bool; let source:String
}
@main enum Driver {
    static func main() throws {
        let cases=try JSONDecoder().decode([Case].self,from:FileHandle.standardInput.readDataToEndOfFile())
        let keys=Set('''+json.dumps(KEYS)+''')
        let tokens=["English":50259,"Chinese":50260,"Korean":50264,"Japanese":50266]
        var results:[[String:Any]]=[]
        for c in cases {
            let language=c.inputLanguage.flatMap { tokens[$0] } ?? c.restoredLanguage
            let policy=Policy(translateTargets:Set(c.targets),languageTokenID:language,liveWindowSeconds:c.window)
            var config=LaunchOracle.Config(binaryURL:URL(fileURLWithPath:"/madi/engine"),modelURL:URL(fileURLWithPath:"/madi/model"),bpeURL:URL(fileURLWithPath:"/madi/bpe"),assetsDir:URL(fileURLWithPath:"/madi/assets"))
            let speakers=SpeakerCount(rawValue:c.speakerCount)!
            config.diarize=c.diarize;config.osd=c.osd;config.languageTokenID=language
            config.maxSpeakers=speakers.maxSpeakers;config.fixedK=speakers.fixedK;config.vadProb=speakers.vadProb
            config.encoderF16Cache=c.physicalMemory>=24*(1<<30);config.biasTerms=c.biasTerms
            config.langCandidates=policy.candidates;config.streamWavRoots=[URL(fileURLWithPath:"/madi/owned")]
            // The checked shipping voiceprintsEnabled gate is false.
            let oracle=LaunchOracle(config:config);oracle.build()
            let capture=CaptureValues();policy.apply(capture)
            results.append(["executable":oracle.process.executableURL!.path,"cwd":oracle.process.currentDirectoryURL!.path,"arguments":oracle.process.arguments!,"environment":oracle.process.environment!.filter { keys.contains($0.key) },
                            "capture":["source":c.source,"segmentSeconds":capture.segmentSeconds,"firstSegmentSeconds":capture.firstSegmentSeconds,"overlapSeconds":capture.overlapSeconds,"previewSeconds":1.0,"previewEnabled":c.preview]])
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]))
    }
}
''',encoding='utf-8')
    cases=[]
    targets=[[],['Korean'],['English'],['Korean','Japanese'],['English','Japanese'],['Korean','English','Japanese'],['English','Chinese','Japanese','Korean'],['Other','Korean']]
    for i,(speaker,language,target,memory,window,preview) in enumerate(itertools.product((0,2,3,4,5),(None,'English','Chinese','Korean','Japanese'),targets,(24*(1<<30)-1,24*(1<<30)),(5,7,10),(True,False))):
        cases.append(dict(speakerCount=speaker,inputLanguage=language,restoredLanguage=None,targets=target,physicalMemory=memory,window=window,preview=preview,source=('mic','system','both')[i%3],diarize=i%4<2,osd=i%2==0,biasTerms=[] if i%3==0 else ['마디','Rust/Tauri','two words','line\nbreak']))
    for language in (None,'English'):
        for token in (50265,50264,99999): cases.append(dict(cases[0],inputLanguage=language,restoredLanguage=token,targets=['Korean','Japanese']))
    payload=encoded(cases)
    subprocess.run([os.environ.get('CARGO','cargo'),'build','--locked','-p','madi-platform','--example','live_config_oracle'],cwd=ROOT,check=True)
    binary=ROOT/'target/debug/examples'/('live_config_oracle.exe' if os.name=='nt' else 'live_config_oracle')
    env={k:v for k,v in os.environ.items() if k not in KEYS}
    rust=json.loads(subprocess.check_output([str(binary)],input=payload,env=env))
    (OUT/'rust.json').write_bytes(encoded(rust))
    if not args.rust_only:
        swift_binary=OUT/'swift-oracle'
        subprocess.run(['xcrun','swiftc','-parse-as-library',str(driver),str(PATH_POLICY),'-o',str(swift_binary)],check=True)
        swift=json.loads(subprocess.check_output([str(swift_binary)],input=payload,env=env))
        (OUT/'swift.json').write_bytes(encoded(swift))
        for case,expected,actual in zip(cases,swift,rust,strict=True):
            assert expected==actual,json.dumps(dict(case=case,swift=expected,rust=actual),ensure_ascii=False,indent=2)
    report=dict(cases=len(cases),corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(encoded(rust)).hexdigest(),extractedSourceSHA256=hashlib.sha256((config+launch+properties+policy+capture_settings).encode()).hexdigest(),sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (ENGINE,SESSION,PATH_POLICY)})
    if args.write_reference: REFERENCE.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    else: assert report==json.loads(REFERENCE.read_text(encoding='utf-8')),'Pinned live configuration changed'
    report.update(status='passed',nativeSwiftRun=not args.rust_only,scope='Live launch options, language candidates, multi-target window and preview settings; no engine, capture hardware or UI execution',intentionalDifference='Rust clears unset engine-owned keys and validates the canonical owned stream root')
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))


if __name__=='__main__': main()
