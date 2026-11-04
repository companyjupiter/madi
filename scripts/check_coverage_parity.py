#!/usr/bin/env python3
"""Compare W1 coverage decisions with the unchanged shipping segment-end body."""
import argparse,hashlib,json,os,platform,random,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/coverage-parity'
REFERENCE=ROOT/'design/parity/coverage-reference.json'
SOURCE=ROOT/'apps/macos/Sovereign/SessionController.swift'
def encoded(v):return json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode('utf-8')
def cases():
 rng=random.Random(2026110531);result=[]
 for case in range(500):
  actions=[dict(type='feed',offset=0,audio='first.wav',hadSpeech=True),dict(type='previewWord'),dict(type='segmentEnd')]
  if case%2:actions.append(dict(type='word'))
  actions.append(dict(type='segmentEnd'))
  for i in range(40):
   kind=rng.choice(['feed','feed','word','word','previewWord','segmentEnd','segmentEnd','segmentEnd','retire','reset'])
   a=dict(type=kind)
   if kind=='feed':a.update(offset=rng.choice([0,.25,1.5,60.1,3601.8]),audio=f'clip-{i}.wav',hadSpeech=rng.choice([True,True,False]))
   actions.append(a)
  result.append(actions)
 return result
SWIFT=r'''
import Foundation
private struct SegJob { let offset:Double;let url:URL;let hadSpeech:Bool;var retried:Bool;var fedAt:Date }
private final class Lifecycle { var feeds:[(Double,URL)]=[];func feed(offset:Double,wav:URL) { feeds.append((offset,wav)) } }
private final class Probe {
    var segQueue:[SegJob]=[];var wordsSinceSegStart=0;var segmentsInFlight=0;var coverageGaps:[Double]=[]
    var sttTurnarounds:[Double]=[];let lifecycle=Lifecycle()
    func updatePreviewAdmission() {}
    func debugWatchdog(_ label:String,_ fields:[String:Any]) {}
    func segmentEnd() {
__SEGMENT_END__
    }
    func step(_ action:[String:Any])->[String:Any] {
        lifecycle.feeds=[]
        switch action["type"] as! String {
        case "feed":segQueue.append(SegJob(offset:(action["offset"] as! NSNumber).doubleValue,url:URL(fileURLWithPath:"/fixture/"+(action["audio"] as! String)),hadSpeech:action["hadSpeech"] as! Bool,retried:false,fedAt:Date()));segmentsInFlight=segQueue.count
        case "word":wordsSinceSegStart += 1
        case "previewWord":break
        case "segmentEnd":segmentEnd()
        case "retire":segQueue.removeAll();segmentsInFlight=0
        default:fatalError("reset must replace probe")
        }
        func job(_ j:SegJob)->[String:Any] { ["offset":j.offset,"audio":j.url.lastPathComponent,"hadSpeech":j.hadSpeech,"retried":j.retried] }
        return ["state":["queue":segQueue.map(job),"wordsSinceSegment":wordsSinceSegStart,"gaps":coverageGaps],"pending":segmentsInFlight,"retry":lifecycle.feeds.isEmpty ? NSNull():job(segQueue.last!) as Any]
    }
}
let input=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [[[String:Any]]]
let output=input.map { actions in
    var probe=Probe()
    return actions.map { a -> [String:Any] in
        if a["type"] as! String == "reset" {probe=Probe();return probe.step(["type":"previewWord"])}
        return probe.step(a)
    }
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]))
'''
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--rust-only',action='store_true');p.add_argument('--write-reference',action='store_true');a=p.parse_args();assert not(a.rust_only and a.write_reference)
 OUT.mkdir(parents=True,exist_ok=True);data=cases();payload=encoded(data);(OUT/'corpus.json').write_bytes(payload)
 subprocess.run(['cargo','build','--locked','-p','madi-core','--example','coverage_oracle'],cwd=ROOT,check=True)
 exe=ROOT/'target/debug/examples'/('coverage_oracle.exe' if os.name=='nt' else 'coverage_oracle')
 got=json.loads(subprocess.check_output([str(exe)],input=payload));(OUT/'result.json').write_bytes(encoded(got))
 if not a.rust_only:
  assert platform.system()=='Darwin'
  source=SOURCE.read_text(encoding='utf-8');start=source.index('        case .segmentEnd:',source.index('    func engine(didEmit event:'))
  body=source[source.index('\n',start)+1:source.index('        case .partial(',start)]
  driver=OUT/'CoverageOracle.swift';driver.write_text(SWIFT.replace('__SEGMENT_END__',body),encoding='utf-8')
  oracle=OUT/'swift-oracle';subprocess.run(['xcrun','swiftc',str(driver),'-o',str(oracle)],check=True)
  want=json.loads(subprocess.check_output([str(oracle)],input=payload));(OUT/'swift.json').write_bytes(encoded(want))
  assert len(want)==len(got)
  for i,(expected,actual) in enumerate(zip(want,got,strict=True)):
   for j,(left,right) in enumerate(zip(expected,actual,strict=True)):assert left==right,(i,j,data[i][:j+1],left,right)
 report=dict(cases=len(data),transitions=sum(map(len,data)),corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(encoded(got)).hexdigest(),sources={SOURCE.relative_to(ROOT).as_posix():hashlib.sha256(SOURCE.read_bytes()).hexdigest()})
 if a.write_reference:REFERENCE.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
 else:assert report==json.loads(REFERENCE.read_text(encoding='utf-8')),'Coverage reference changed'
 report.update(status='passed',nativeSwiftRun=not a.rust_only,scope='Unchanged original segmentEnd body with input enqueue/word-counter/reset scaffolding and no-op diagnostics/preview admission. Queue, one-retry decisions, gaps and counters compared; timestamps/turnaround diagnostics, capture/transport and native UI excluded.')
 (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
