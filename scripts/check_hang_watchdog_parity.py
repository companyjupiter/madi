#!/usr/bin/env python3
"""Compare W2 restart and retained-queue behavior to unchanged shipping bodies."""
import argparse
import hashlib
import json
import os
import platform
import random
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/hang-watchdog-parity'
SOURCE = ROOT / 'apps/macos/Sovereign/SessionController.swift'
REFERENCE = ROOT / 'design/parity/hang-watchdog-reference.json'


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def cases():
    rng = random.Random(2026110542)
    result = []
    for case in range(600):
        now = 0.0
        actions = []
        for i in range(60):
            now += rng.choice([-10, 0, .1, 5, 44.9, 45, 45.1, 90])
            kind = rng.choice(['feed', 'feed', 'activity', 'word', 'end', 'tick', 'tick', 'tick', 'retire', 'reset'])
            action = dict(type=kind, now=now)
            if kind == 'feed':
                action.update(offset=i / 4, audio=f'{case}-{i}.wav', speech=rng.choice([True, False]))
            if kind == 'tick':
                action.update(phase=rng.choice(['recording', 'recording', 'paused', 'flushing', 'done', 'idle']), replace=rng.choice([True, True, False]))
            actions.append(action)
        result.append(actions)
    return result


SWIFT = r'''
import Foundation
private enum Clock { static var now:Double=0 }
// Inject only Date's clock; all production decision statements are unchanged.
private struct Date:Comparable {
    let value:Double
    init(){value=Clock.now}
    static func <(a:Self,b:Self)->Bool{a.value<b.value}
    func timeIntervalSince(_ other:Self)->Double{value-other.value}
}
private enum Phase { case recording,paused,flushing,done,idle }
private struct SegJob {let offset:Double;let url:URL;let hadSpeech:Bool;var retried:Bool;var fedAt:Date}
private final class Transcript {var broken=false;func markDiarNamespaceBroken(){broken=true}}
private enum LiveFeatureWiring {
    static var speakerIslandAbsorption=false;static var weakLabelContinuation=0.0
    static func islandAbsorption(for token:Int?)->Bool{false}
    static func weakLabelContinuation(for token:Int?)->Double{0}
}
private struct SessionEngineAdapter {init(config:Int){}}
private final class Lifecycle {
    var replacement=true;var feeds:[(Double,URL)]=[]
    func replaceEngine(_ value:SessionEngineAdapter)->Bool{replacement}
    func feed(offset:Double,wav:URL){feeds.append((offset,wav))}
}
private final class Probe {
    var segQueue:[SegJob]=[];var wordsSinceSegStart=0;var segmentsInFlight=0;var coverageGaps:[Double]=[]
    var lastEngineActivityAt=Date();var hangRecoveries=0;var phase=Phase.idle;let languageTokenID:Int?=nil
    var sttTurnarounds:[Double]=[];let lifecycle=Lifecycle();let transcript=Transcript()
    func makeConfig()->Int{0}
    func debugWatchdog(_ label:String,_ fields:[String:Any]){}
    func updatePreviewAdmission(){}
    func idleBackfillTick(){}
    func segmentEnd(){
__SEGMENT_END__
    }
__WATCHDOG__
    func step(_ a:[String:Any])->[String:Any]{
        Clock.now=(a["now"] as! NSNumber).doubleValue;lifecycle.feeds=[]
        switch a["type"] as! String {
        case "feed":segQueue.append(SegJob(offset:(a["offset"] as! NSNumber).doubleValue,url:URL(fileURLWithPath:"/fixture/"+(a["audio"] as! String)),hadSpeech:a["speech"] as! Bool,retried:false,fedAt:Date()))
        case "activity":lastEngineActivityAt=Date()
        case "word":lastEngineActivityAt=Date();wordsSinceSegStart += 1
        case "end":lastEngineActivityAt=Date();segmentEnd()
        case "retire":segQueue=[]
        case "reset":segQueue=[];wordsSinceSegStart=0;coverageGaps=[];hangRecoveries=0;transcript.broken=false
        case "tick":
            switch a["phase"] as! String {case "recording":phase = .recording;case "paused":phase = .paused;case "flushing":phase = .flushing;case "done":phase = .done;default:phase = .idle}
            lifecycle.replacement=a["replace"] as! Bool;tickWatchdog()
        default:fatalError("unknown action")
        }
        func job(_ j:SegJob)->[String:Any]{["offset":j.offset,"audio":j.url.lastPathComponent,"hadSpeech":j.hadSpeech,"retried":j.retried]}
        let feeds=lifecycle.feeds.map{ offset,url in job(segQueue.first{$0.offset==offset && $0.url==url}!) }
        return ["state":["queue":segQueue.map(job),"wordsSinceSegment":wordsSinceSegStart,"gaps":coverageGaps],"fedAt":segQueue.map{$0.fedAt.value},"recoveries":hangRecoveries,"broken":transcript.broken,"feeds":feeds]
    }
}
let input=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [[[String:Any]]]
let output=input.map { actions in Clock.now=0;let probe=Probe();return actions.map{probe.step($0)} }
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]))
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--rust-only', action='store_true')
    group.add_argument('--write-reference', action='store_true')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    data = cases()
    payload = encoded(data)
    (OUT / 'corpus.json').write_bytes(payload)
    subprocess.run(['cargo', 'build', '--locked', '-p', 'madi-core', '--example', 'hang_watchdog_oracle'], cwd=ROOT, check=True)
    exe = ROOT / 'target/debug/examples' / ('hang_watchdog_oracle.exe' if os.name == 'nt' else 'hang_watchdog_oracle')
    result = json.loads(subprocess.check_output([str(exe)], input=payload))
    (OUT / 'result.json').write_bytes(encoded(result))
    if not args.rust_only:
        assert platform.system() == 'Darwin'
        source = SOURCE.read_text(encoding='utf-8')
        start = source.index('        case .segmentEnd:', source.index('    func engine(didEmit event:'))
        segment = source[source.index('\n', start) + 1:source.index('        case .partial(', start)]
        start = source.index('    private func tickWatchdog() {')
        watchdog = source[start:source.index('\n    private var pendingFinalReconcile', start)]
        driver = OUT / 'WatchdogOracle.swift'
        driver.write_text(SWIFT.replace('__SEGMENT_END__', segment).replace('__WATCHDOG__', watchdog), encoding='utf-8')
        oracle = OUT / 'swift-oracle'
        subprocess.run(['xcrun', 'swiftc', str(driver), '-o', str(oracle)], check=True)
        expected = json.loads(subprocess.check_output([str(oracle)], input=payload))
        (OUT / 'swift.json').write_bytes(encoded(expected))
        for i, (want, got) in enumerate(zip(expected, result, strict=True)):
            for j, (left, right) in enumerate(zip(want, got, strict=True)):
                assert left == right, (i, j, data[i][:j + 1], left, right)
    report = dict(cases=len(data), transitions=sum(map(len, data)), corpusSHA256=hashlib.sha256(payload).hexdigest(), resultSHA256=hashlib.sha256(encoded(result)).hexdigest(), sources={SOURCE.relative_to(ROOT).as_posix():hashlib.sha256(SOURCE.read_bytes()).hexdigest()})
    if args.write_reference:
        REFERENCE.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    else:
        assert report == json.loads(REFERENCE.read_text(encoding='utf-8')), 'Hang-watchdog reference changed'
    report.update(status='passed', nativeSwiftRun=not args.rust_only, scope='Unchanged tickWatchdog and W1 segment-end bodies with injected Date clock; replacement result, feed collection and input reset scaffolding. Queue timestamps, retry flags, word counter, recovery count, namespace-break signal and ordered feeds compared. No process, live settings, scheduling, capture or UI acceptance.')
    (OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
