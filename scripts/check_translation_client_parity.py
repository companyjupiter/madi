#!/usr/bin/env python3
"""Compare native TranslateEngine callbacks with the Rust client state machine."""
import argparse,hashlib,json,os,platform,random,subprocess
from pathlib import Path
from check_asr_config_parity import block
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'out/translation-client-parity';REFERENCE=ROOT/'design/parity/translation-client-reference.json'
SOURCES=[ROOT/'apps/macos/Sovereign'/p for p in ('Engine/TranslateEngine.swift','Engine/TranslationTurnQueue.swift','Transcript/TranslationShedPolicy.swift','Engine/TranslationStability.swift')]
def encoded(x):return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf-8')
def translate(text,targets=None,index=0,kind='committed',forced=None,time=0):return dict(op='translate',text=text,targets=targets or ['English'],id=f'00000000-0000-0000-0000-{index:012x}',kind=kind,forced=forced or {},time=time)
# TranslateStreamParser(preserveNewlines:false) flattens LF inside replies.
# Keep source-input CRLF probes intact; callbacks must obey the real transport.
def complete(text='Hello.',last=False):return dict(op='complete',text=text.replace('\n',' ') if text is not None else None,last=last)
def cases():
    config=dict(priority='English',maxPending=0,shedAt=6,guarantee=3)
    sequences=[
      [translate('안녕하세요'),dict(op='ready',fp=True),complete(),dict(op='partial',text='Hello',ns=80_000_000),dict(op='partial',text='Hello',ns=80_000_001),complete('Hello.'),translate('좋은 아침'),complete('Good morning.'),translate('시작',kind='interim',forced={'English':'Hello'}),complete('Hello tail.')],
      [dict(op='ready',fp=False),translate('oldsource'),complete(),translate('newsource'),complete('oldsource'),complete('Translated answer.')],
      [dict(op='ready',fp=True),translate('text',['Chinese','English','Japanese']),complete(None),complete('Answer.'),complete(),complete('日本語です'),complete(),complete('你好')],
      [dict(op='ready',fp=True),translate('one'),complete(),complete('one'),complete('one'),translate('two'),complete('0123456789. '+'long answer '*30),translate('three'),complete('')],
      [dict(op='ready',fp=True),translate('one',['English','French']),translate('two',['English','French'],index=1),translate('interim',['English','French'],index=2,kind='interim',forced={'English':'%%FP bad','French':'prefix\nnext'}),complete(),complete('answer'),complete('answer'),complete('answer'),complete('answer')],
    ]
    rng=random.Random(2026110503);values=['안녕하세요','你好','cafe\u0301','café','old source','new source','text\r\nnext','text\nnext','', ' \u200b ', 'ΟΣ','one => two']
    for _ in range(160):
      ops=[dict(op='ready',fp=rng.choice([True,False]))]
      for i in range(40):
        choice=rng.choice(['translate']*4+['complete']*3+['partial'])
        if choice=='translate':ops.append(translate(rng.choice(values),rng.choice([['English'],['English','Korean'],['French','Chinese','English'],['Café','Café']]),rng.randrange(3),rng.choice(['committed','interim']),{'English':rng.choice(['shown','%%FP injection','%%FP\u0301 preserved','prefix\nnext',''])},rng.choice([0,2.9,3,6,9,30])))
        elif choice=='complete':ops.append(complete(rng.choice(values+['answer.',None,'<think>oops','Yes. Yes. Yes.','long answer '*30]),rng.choice([False,True])))
        else:ops.append(dict(op='partial',text=rng.choice(values+['Answer.','Now: Hello.']).replace('\n',' '),ns=rng.choice([0,80_000_000,80_000_001,160_000_001,500_000_000,1_000_000_000])))
      sequences.append(ops)
    return [dict(config={**config,**(dict(priority=rng.choice([None,'English','French']),maxPending=rng.choice([0,2,4]),shedAt=rng.choice([0,2,6]),guarantee=rng.choice([0,3])) if i>=5 else {})},ops=ops+[dict(op='stop')]) for i,ops in enumerate(sequences)]
MOCK=r'''
@MainActor enum ContinuousClock { static var now:Duration = .zero }
@MainActor final class DebugLog { static var shared:DebugLog?;func emit(_ a:String,_ b:String,_ c:[String:Any]) {} }
@MainActor final class TranslationStabilityMetrics { static let shared=TranslationStabilityMetrics();var interimForcedTurns=0;var interimForcedChars=0 }
@MainActor final class DNAEngineBroker {
 static let shared=DNAEngineBroker()
 enum Priority:Int {case committedCaption=100,interimCaption=80}
 var supportsForcedPrefix=false;var pressure=0;var sequence=0
 var onReady:(()->Void)?;var events:[[String:Any]]=[]
 var completions:[Int:(String?)->Void]=[:];var partials:[Int:(String)->Void]=[:]
 func reset(){supportsForcedPrefix=false;pressure=0;sequence=0;onReady=nil;events=[];completions=[:];partials=[:]}
 func attach(client:UUID,engine:URL,model:URL,onReady:@escaping ()->Void)->Bool{self.onReady=onReady;return true}
 func detach(client:UUID){completions=[:];partials=[:];onReady=nil}
 func reportCaptionPressure(_ depth:Int){pressure=depth}
 func registerPrefix(client:UUID,slot:Int,text:String,completion:@escaping (Bool)->Void){
  sequence+=1;let ticket=sequence;completions[ticket]={completion($0 != nil)}
  events.append(["event":"submit","ticket":ticket,"kind":"prefix","slot":slot,"text":text,"priority":100])
 }
 func submit(client:UUID,prompt:String,priority:Priority,onPartial:@escaping (String)->Void,completion:@escaping (String?)->Void){
  sequence+=1;let ticket=sequence;completions[ticket]=completion;partials[ticket]=onPartial
  events.append(["event":"submit","ticket":ticket,"kind":"turn","text":prompt,"priority":priority.rawValue])
 }
}
@main @MainActor enum Main {
 static func main() throws {
  let cases=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [[String:Any]]
  var results:[Any]=[]
  for c in cases {
   let b=DNAEngineBroker.shared;b.reset();ContinuousClock.now = .zero
   let engine=TranslateEngine();let config=c["config"] as! [String:Any]
   engine.priorityLang=config["priority"] as? String;engine.maxPending=config["maxPending"] as! Int;engine.shedSecondaryTargetsAt=config["shedAt"] as! Int;engine.interimGuarantee=config["guarantee"] as! Double
   var uptime=0.0;engine.clock={uptime};var turns=0
   engine.onQueueChange={turns=$0};engine.onLineDepthChange={b.events.append(["event":"depth","turns":turns,"lines":$0])}
   engine.onResult={id,lang,text,source in b.events.append(["event":"result","id":id.uuidString.lowercased(),"language":lang,"text":text,"source":source])}
   engine.onPartial={id,lang,text,source in b.events.append(["event":"partial","id":id.uuidString.lowercased(),"language":lang,"text":text,"source":source])}
   engine.onDrop={id,lang,source in b.events.append(["event":"drop","id":id.uuidString.lowercased(),"language":lang,"source":source])}
   engine.onDiscard={id,lang,source in b.events.append(["event":"discard","id":id.uuidString.lowercased(),"language":lang,"source":source])}
   _=engine.start(engine:URL(fileURLWithPath:"/oracle-engine"),model:URL(fileURLWithPath:"/oracle-model"))
   var rows:[[String:Any]]=[]
   for op in c["ops"] as! [[String:Any]] {
    b.events=[];var accepted:Any=NSNull()
    switch op["op"] as! String {
    case "ready":b.supportsForcedPrefix=op["fp"] as! Bool;b.onReady?()
    case "translate":uptime=op["time"] as! Double;accepted=engine.translate(op["text"] as! String,into:op["targets"] as! [String],id:UUID(uuidString:op["id"] as! String)!,kind:op["kind"] as! String == "interim" ? .interim:.committed,forced:op["forced"] as! [String:String])
    case "complete":
     let keys=b.completions.keys.sorted();let ticket=(op["last"] as! Bool) ? keys.last:keys.first
     if let ticket,let callback=b.completions.removeValue(forKey:ticket){b.partials.removeValue(forKey:ticket);callback(op["text"] as? String)}
    case "partial":ContinuousClock.now = .nanoseconds(op["ns"] as! Int64);if let ticket=b.completions.keys.sorted().first{b.partials[ticket]?(op["text"] as! String)}
    default:engine.stop()
    }
    rows.append(["accepted":accepted,"events":b.events,"pressure":b.pressure,"runaways":engine.runawayTruncations])
   }
   results.append(rows)
  }
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]))
 }
}
'''
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--rust-only',action='store_true');p.add_argument('--write-reference',action='store_true');a=p.parse_args()
 if a.write_reference and a.rust_only:p.error('Native Swift required')
 if not a.rust_only and platform.system()!='Darwin':p.error('Native Swift requires macOS')
 OUT.mkdir(parents=True,exist_ok=True);corpus=cases();payload=encoded(corpus);(OUT/'cases.json').write_bytes(payload)
 subprocess.run([os.environ.get('CARGO','cargo'),'build','--locked','-p','madi-core','--example','translation_client_oracle'],cwd=ROOT,check=True)
 binary=ROOT/'target/debug/examples'/('translation_client_oracle.exe' if os.name=='nt' else 'translation_client_oracle')
 actual=json.loads(subprocess.check_output([str(binary)],input=payload));(OUT/'result.json').write_bytes(encoded(actual))
 if not a.rust_only:
  tuning=block(SOURCES[3].read_text(encoding='utf-8'),'    static func adaptiveGuarantee(')
  driver=OUT/'ClientOracle.swift';driver.write_text('import Foundation\nenum InterimTuning {\n'+tuning+'\n}\n'+MOCK,encoding='utf-8')
  native=OUT/'swift-oracle';subprocess.run(['xcrun','swiftc','-parse-as-library',str(driver),*(str(s) for s in SOURCES[:3]),'-o',str(native)],check=True)
  expected=json.loads(subprocess.check_output([str(native)],input=payload));(OUT/'swift.json').write_bytes(encoded(expected))
  for i,(case,want,got) in enumerate(zip(corpus,expected,actual,strict=True)):
   for step,(sw,rs) in enumerate(zip(want,got,strict=True)):
    assert sw==rs,json.dumps(dict(case=i,step=step,input=case['ops'][:step+1],swift=sw,rust=rs),ensure_ascii=False,indent=2)
 report=dict(cases=len(corpus),operations=sum(len(c['ops']) for c in corpus),corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(encoded(actual)).hexdigest(),sources={s.relative_to(ROOT).as_posix():hashlib.sha256(s.read_bytes()).hexdigest() for s in SOURCES})
 if a.write_reference:REFERENCE.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
 else:assert report==json.loads(REFERENCE.read_text(encoding='utf-8')),'Translation client reference changed'
 report.update(status='passed',nativeSwiftRun=not a.rust_only,scope='Unchanged TranslateEngine with deterministic broker callbacks and clocks; actual process transport checked separately')
 (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
