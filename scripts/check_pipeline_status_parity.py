#!/usr/bin/env python3
"""Compare pipeline priority and localized transcript status with shipping Swift."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/pipeline-status-parity'
REFERENCE=ROOT/'design/parity/pipeline-status-reference.json'
SOURCES=[ROOT/'apps/macos/Sovereign'/p for p in ['SessionController.swift','UI/ContentView.swift','UI/StatusLine.swift']]
def encode(v):return json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode('utf-8')
def cases():
    rng=random.Random(2026110508)
    phases=['idle','countingDown','engineStarting','ready','recording','paused','processing','flushing','done','error']
    results=[]
    for i in range(1000):
        kind=phases[i%len(phases)]
        phase=dict(kind=kind)
        if kind=='error':phase['message']='오류 · failure'
        if kind=='countingDown':phase['remaining']=3
        s=dict(phase=phase,languageCorrectionsPending=rng.choice([0,0,0,0,2]),reconciling=rng.random()<.15,chunksDone=rng.choice([0,1,2,3,11]),chunksTotal=rng.choice([0,3,7,12]),translateBacklog=rng.choice([0,0,0,4]),translateQueuedLines=rng.choice([0,0,0,1,2,7]),translateQueueDepth=rng.choice([0,0,0,1,2,12]),micSilent=rng.choice([False,False,True]),segmentsInFlight=rng.choice([0,0,1,4]),backfillRemaining=rng.choice([0,0,1,6]),captureEndedReason=rng.choice([None,None,'','capture ended']),coverageGaps=rng.choice([[],[],[0.9,59.9,60.1],[93.9,9.2,3661.9,9.2]]),hangRecoveries=rng.choice([0,0,1,7]))
        if i<40:
            for key in ['languageCorrectionsPending','translateBacklog','translateQueuedLines','translateQueueDepth','backfillRemaining']:s[key]=0
            s['reconciling']=False;s['micSilent']=False
            if i>=10:s['translateQueueDepth']=1
            if i>=20:s['translateBacklog']=4
            if i>=30:s['languageCorrectionsPending']=2
        results.extend(dict(signals=s,language=lang) for lang in ['ko','en','ja'])
    return results
SWIFT=r'''
import Foundation
private enum Phase: Equatable { case idle, countingDown(Int), engineStarting, ready, recording, paused, processing, flushing, done, error(String) }
private struct Session {
    var phase:Phase
    var languageCorrectionsPending:Int;var reconciling:Bool;var chunksDone:Int;var chunksTotal:Int
    var translateBacklog:Int;var translateQueuedLines:Int;var translateQueueDepth:Int
    var micSilent:Bool;var segmentsInFlight:Int;var backfillRemaining:Int
    var captureEndedReason:String?;var coverageGaps:[Double];var hangRecoveries:Int
    init(_ s:[String:Any]) {
        let p=s["phase"] as! [String:Any]
        switch p["kind"] as! String {
        case "idle":phase = .idle
        case "countingDown":phase = .countingDown(p["remaining"] as! Int)
        case "engineStarting":phase = .engineStarting
        case "ready":phase = .ready
        case "recording":phase = .recording
        case "paused":phase = .paused
        case "processing":phase = .processing
        case "flushing":phase = .flushing
        case "done":phase = .done
        case "error":phase = .error(p["message"] as! String)
        default:fatalError()
        }
        languageCorrectionsPending=s["languageCorrectionsPending"] as! Int;reconciling=s["reconciling"] as! Bool
        chunksDone=s["chunksDone"] as! Int;chunksTotal=s["chunksTotal"] as! Int
        translateBacklog=s["translateBacklog"] as! Int;translateQueuedLines=s["translateQueuedLines"] as! Int;translateQueueDepth=s["translateQueueDepth"] as! Int
        micSilent=s["micSilent"] as! Bool;segmentsInFlight=s["segmentsInFlight"] as! Int;backfillRemaining=s["backfillRemaining"] as! Int
        captureEndedReason=s["captureEndedReason"] as? String;coverageGaps=(s["coverageGaps"] as! [NSNumber]).map(\.doubleValue);hangRecoveries=s["hangRecoveries"] as! Int
    }
    __PIPELINE__
    func value() -> [String:Any] {
        switch pipeline {
        case .idle:return ["kind":"idle"]
        case .listening:return ["kind":"listening"]
        case .transcribing:return ["kind":"transcribing"]
        case .fileTranscribing(let p):return ["kind":"fileTranscribing","percent":p as Any? ?? NSNull()]
        case .diarizing:return ["kind":"diarizing"]
        case .correcting(let n):return ["kind":"correcting","count":n]
        case .translating(let n):return ["kind":"translating","count":n]
        case .translatingBacklogged(let n):return ["kind":"translatingBacklogged","count":n]
        case .completed:return ["kind":"completed"]
        case .backfilling(let n):return ["kind":"backfilling","count":n]
        case .error(let e):return ["kind":"error","message":e]
        }
    }
}
private struct ViewProbe {
    let session:Session;let language:String
    func uiLang(_ ko:String,_ en:String,_ ja:String?=nil)->String {language=="ko" ? ko : language=="ja" ? (ja ?? en):en}
    __PRESENTATION__
    func value()->[String:Any] { ["pipeline":session.value(),"warning":transcriptWarning as Any? ?? NSNull(),"gapTimes":coverageGapTimes,"activity":transcriptActivity as Any? ?? NSNull()] }
}
let input=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [[String:Any]]
let output=input.map{ ViewProbe(session:Session($0["signals"] as! [String:Any]),language:$0["language"] as! String).value() }
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]))
'''
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--rust-only',action='store_true');p.add_argument('--write-reference',action='store_true');a=p.parse_args()
    assert not (a.rust_only and a.write_reference)
    OUT.mkdir(parents=True,exist_ok=True)
    corpus=cases();payload=encode(corpus);(OUT/'corpus.json').write_bytes(payload)
    subprocess.run(['cargo','build','--locked','-p','madi-core','--example','pipeline_status_oracle'],cwd=ROOT,check=True)
    exe=ROOT/'target/debug/examples'/('pipeline_status_oracle.exe' if os.name=='nt' else 'pipeline_status_oracle')
    got=json.loads(subprocess.check_output([str(exe)],input=payload));(OUT/'result.json').write_bytes(encode(got))
    if not a.rust_only:
        assert platform.system()=='Darwin'
        session=SOURCES[0].read_text(encoding='utf-8');view=SOURCES[1].read_text(encoding='utf-8')
        pipeline=session[session.index('    enum PipelineState:'):session.index('    var level: Float')]
        presentation=view[view.index('    private var transcriptWarning:'):view.index('    // accept anything the system recognizes as audio')]
        driver=OUT/'PipelineStatusOracle.swift';driver.write_text(SWIFT.replace('__PIPELINE__',pipeline).replace('__PRESENTATION__',presentation),encoding='utf-8')
        oracle=OUT/'swift-oracle';subprocess.run(['xcrun','swiftc',str(driver),'-o',str(oracle)],check=True)
        want=json.loads(subprocess.check_output([str(oracle)],input=payload));(OUT/'swift.json').write_bytes(encode(want))
        assert len(want)==len(got)
        for i,(expected,actual) in enumerate(zip(want,got,strict=True)):assert expected==actual,(i,corpus[i],expected,actual)
    report=dict(cases=len(corpus),pipelineKinds=sorted(set(v['pipeline']['kind'] for v in got)),languages=['ko','en','ja'],corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(encode(got)).hexdigest(),sources={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in SOURCES})
    # POSIX source names make the reference independent of the Windows checkout path.
    report['sources']={s.relative_to(ROOT).as_posix():hashlib.sha256(s.read_bytes()).hexdigest() for s in SOURCES}
    if a.write_reference:REFERENCE.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    else:assert report==json.loads(REFERENCE.read_text(encoding='utf-8')),'Pipeline status reference changed'
    report.update(status='passed',nativeSwiftRun=not a.rust_only,scope='Unchanged extracted pipeline, warning, gap formatting and localized activity computations. StatusLine source is pinned, not executed; no native UI, timer scheduling, coverage retry or AI producer acceptance.')
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
