#!/usr/bin/env python3
"""Compare the unchanged Swift reconciliation grammar and reply aggregation."""
import argparse,hashlib,json,os,platform,random,subprocess,struct
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/reconcile-parity'
REFERENCE=ROOT/'design/parity/reconcile-reference.json'
SOURCES=[ROOT/'apps/macos/Sovereign'/p for p in ['Transcript/TranscriptReconciler.swift','Engine/SummaryEngine.swift','Audio/WavWriter.swift','Session/SessionOneShotTranscriber.swift']]
def encoded(x): return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf-8')
def cases():
 rng=random.Random(2026110522)
 corpus=[]
 texts=['','plain text','한국어 대화','cafe\u0301','👩\u200d💻','🇰🇷','\r\n','\n','\t','\u200b',' /\u0301 ','नमस्ते','a\r\nb\nc','🏳️\u200d🌈']
 commands=['MERGE 3 1','MERGE 1 3','MERGE 2 1','MERGE 3 2','RELABEL 1 3','RELABEL 1 2','RELABEL 2 2','LANG 1 ko','LANG 1 ja','LANG 2 korean','LANG 3 한국어','RELABEL +0001 +2','RELABEL 0 1','LANG -1 en','MERGE -1 2','RELABEL 9223372036854775808 1','MERGE 1 1','RELABEL 1 999','LANG 1 fr','MERGE\u00a01 2','MERGE \u03011 2','merge\t1\t2','RELABEL 1 2 ignored','OK','OK','lang 1 Korean','LANG 1 한국어','not a command','/\u0301RELABEL 1 2']
 seps=[' / ','\n','\r\n','\u0085','\v','\f','\u2028','\u2029',' /\ufe0f ','\t/\t']
 for i in range(360):
  lines=[[rng.choice([-1,1,2,3]),rng.choice(texts)*rng.randrange(1,8)] for _ in range(i%13)]
  reply=rng.choice(seps).join(rng.choices(commands,k=i%38))
  if i<len(commands):reply=commands[i]
  corpus.append(dict(lines=lines,names={'1':'김','2':'Name\nTwo'},uncertain=[n for n in range(len(lines)) if n%2],risk=[n for n in range(len(lines)) if n%3==0],numbered=('\n'.join(f'{n+1} [S{s}] {t}' for n,(s,t) in enumerate(lines)) if i%2 else '\r\n'.join(rng.choices(texts,k=i%9))),budget=rng.choice([-1,0,1,2,3,9,20,800]),reply=reply,speakers=rng.choice([[],[1,2,3],[-1,1,2,3],[1,3]]),lineCount=rng.choice([0,1,4,10,99]),maxCorrections=rng.choice([-1,0,1,2,24]),allowed=rng.choice([None,[],[0],[0,1,3]]),language=rng.choice(['Korean','English','Japanese','Chinese','korean','Korean','한국어','']),sessionToken=rng.choice([None,50264,50259,50266,50260,999]),replies=[rng.choice([None,'',' \u200b ','OK',' ok ','OK','LANG 1 ja','MERGE 2 1\nRELABEL 1 2']) for _ in range(i%7)]))
 # Directed sequence proves direction, shared targets, no chains/cycles and first wins.
 corpus[0].update(reply='MERGE 3 1 / MERGE 2 1 / MERGE 1 3 / RELABEL 1 2 / RELABEL 1 3 / LANG 1 ja / LANG 1 ko',speakers=[1,2,3],lineCount=4,maxCorrections=24,allowed=[0])
 for i,c in enumerate(corpus):
  samples=struct.pack('<128h',*[j*511-32768 for j in range(128)])
  wav=bytearray(b'RIFF'+struct.pack('<I',36+len(samples))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,1,1,16000,32000,2,16)+b'data'+struct.pack('<I',len(samples))+samples)
  if i%13==0:wav=wav[:i%45]
  elif i%13==1:wav[24:28]=struct.pack('<I',44100)
  elif i%13==2:wav[40:44]=struct.pack('<I',10000)
  elif i%13==3:wav[40:44]=struct.pack('<I',37)
  elif i%13==4:wav[12:16]=b'junk'
  elif i%13==5:wav[28:34]=b'xxxxxx' # Original crop validates selected header fields only.
  output=rng.choice(['noise\n=== TRANSCRIPTION ===\n\n  hello  \n world \n\nignored', '=== TRANSCRIPTION\n\u200b\n한국어\n[perf] end',' === TRANSCRIPTION\nignored','=== TRANSCRIPTION\n','=== TRANSCRIPTION\r\nline\r\n\r\n=== WORD TIMESTAMPS ===','=== TRANSCRIPTION\n \u0301first\nsecond\n=== end','=== TRANSCRIPTION\n[skip]\nnot used','banner\nno header'])
  c.update(wav=list(wav),cropStart=rng.choice([-1.,0.,.0000625,.00008,.003,1.]),cropEnd=rng.choice([0.,.002,.004,.008,1.]),cropPad=rng.choice([0.,.0000625,.2,-.001]),output=output)
 return corpus
SWIFT=r'''
import Foundation
struct C:Decodable { let lines:[Row];let names:[String:String];let uncertain:[Int];let risk:[Int];let numbered:String;let budget:Int;let reply:String;let speakers:[Int];let lineCount:Int;let maxCorrections:Int;let allowed:[Int]?;let language:String;let sessionToken:Int?;let replies:[String?];let wav:[UInt8];let cropStart:Double;let cropEnd:Double;let cropPad:Double;let output:String }
struct Row:Decodable { let speaker:Int;let text:String;init(from d:Decoder)throws { var c=try d.unkeyedContainer();speaker=try c.decode(Int.self);text=try c.decode(String.self) } }
final class Replies {
 var reconcileRemaining:Int;var reconcileAcc:[String]=[];var onResult:((String,String?)->Void)?
 init(_ n:Int){reconcileRemaining=n}
 __COMPLETE__
 func finish(_ text:String?)->Any {var result:Any=NSNull();onResult={_,t in result=t as Any? ?? NSNull()};complete("reconcile-part",text);return result}
}
enum OneShot {
 __PARSE__
 static func result(_ output:String)->String? {parse(output)}
}
@main struct Main {
 static func main()throws {
 let cases=try JSONDecoder().decode([C].self,from:FileHandle.standardInput.readDataToEndOfFile())
 let result:[[String:Any]]=cases.map{c in
 let prompt=TranscriptReconciler.promptInput(lines:c.lines.map{($0.speaker,$0.text)},speakerName:{c.names[String($0)] ?? "화자 \($0)"},uncertain:Set(c.uncertain),languageRisk:Set(c.risk))
 let plan=TranscriptReconciler.parse(c.reply,speakers:Set(c.speakers),lineCount:c.lineCount,maxCorrections:c.maxCorrections,relabelAllowed:c.allowed.map{Set($0)})
 let merges=plan.merges.map{v->[String:Int] in if case let .merge(a,b)=v{return ["from":a,"into":b]};fatalError()}
 let relabels=plan.relabels.map{v->[String:Int] in if case let .relabel(a,b)=v{return ["line":a,"speaker":b]};fatalError()}
 let flags=plan.languageFlags.map{v->[String:Any] in if case let .language(a,b)=v{return ["line":a,"lang":b]};fatalError()}
 let replies=Replies(c.replies.count)
 let source=FileManager.default.temporaryDirectory.appendingPathComponent("madi-crop-oracle-"+UUID().uuidString+".wav")
 var crop:[String:Any]
 do {
 try Data(c.wav).write(to:source)
 let clip=try WavWriter.crop16kMonoPCM(source:source,start:c.cropStart,end:c.cropEnd,pad:c.cropPad)
 crop=["bytes":Array(try Data(contentsOf:clip))]
 try FileManager.default.removeItem(at:clip)
 }catch{crop=["error":(error as NSError).code]}
 try? FileManager.default.removeItem(at:source)
 return ["prompt":prompt,"batches":TranscriptReconciler.promptBatches(c.numbered,budget:c.budget),"instruction":TranscriptReconciler.instruction(),"plan":["merges":merges,"relabels":relabels,"languageFlags":flags],"empty":plan.isEmpty,"languageToken":TranscriptReconciler.languageToken(c.language) as Any? ?? NSNull(),"languageAllowed":TranscriptReconciler.languageFlagAllowed(c.language,sessionLanguageTokenID:c.sessionToken),"completions":c.replies.map{replies.finish($0)},"crop":crop,"transcription":OneShot.result(c.output) as Any? ?? NSNull()]
 }
 FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]))
 }
}
'''
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--rust-only',action='store_true');p.add_argument('--write-reference',action='store_true');a=p.parse_args()
 assert not(a.rust_only and a.write_reference)
 OUT.mkdir(parents=True,exist_ok=True);data=cases();payload=encoded(data);(OUT/'corpus.json').write_bytes(payload)
 subprocess.run(['cargo','build','--locked','-p','madi-core','--example','reconcile_oracle'],cwd=ROOT,check=True)
 binary=ROOT/'target/debug/examples'/('reconcile_oracle.exe' if os.name=='nt' else 'reconcile_oracle')
 actual=json.loads(subprocess.check_output([str(binary)],input=payload));(OUT/'result.json').write_bytes(encoded(actual))
 if not a.rust_only:
  assert platform.system()=='Darwin'
  source=SOURCES[1].read_text(encoding='utf-8');start=source.index('    private func complete(');end=source.index('        if tag == "fold"',start)
  parse_source=SOURCES[3].read_text(encoding='utf-8');parse_start=parse_source.index('    private static func parse(');parse_end=parse_source.index('    /// Cancellation',parse_start)
  driver=OUT/'ReconcileOracle.swift';driver.write_text(SWIFT.replace('__COMPLETE__',source[start:end]+'\n    }').replace('__PARSE__',parse_source[parse_start:parse_end]),encoding='utf-8')
  oracle=OUT/'swift-oracle';subprocess.run(['xcrun','swiftc','-parse-as-library',str(SOURCES[0]),str(SOURCES[2]),str(driver),'-o',str(oracle)],check=True)
  expected=json.loads(subprocess.check_output([str(oracle)],input=payload));(OUT/'swift.json').write_bytes(encoded(expected))
  assert len(expected)==len(actual)
  for i,(want,got) in enumerate(zip(expected,actual,strict=True)):assert want==got,(i,data[i],want,got)
 report=dict(cases=len(data),corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(encoded(actual)).hexdigest(),sources={s.relative_to(ROOT).as_posix():hashlib.sha256(s.read_bytes()).hexdigest() for s in SOURCES})
 if a.write_reference:REFERENCE.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
 else:
  expected_report=json.loads(REFERENCE.read_text(encoding='utf-8'))
  if report!=expected_report:
   (OUT/'report.json').write_text(json.dumps(dict(report,status='failed',expected=expected_report),indent=2)+'\n',encoding='utf-8')
   raise AssertionError({k:{'expected':expected_report.get(k),'actual':v} for k,v in report.items() if v!=expected_report.get(k)})
 report.update(status='passed',nativeSwiftRun=not a.rust_only,scope='Unchanged TranscriptReconciler and SummaryEngine reconcile-part completion body. Prompt characters, grammar validation, language gates, ordered replies, canonical PCM cropping and one-shot output parsing; no model, native correction ownership, transcript mutation or UI acceptance.')
 (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
