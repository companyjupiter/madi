#!/usr/bin/env python3
"""Differential translation queue, prompt, cleanup and retry policy oracle."""
import argparse
from collections import Counter
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import random
import subprocess
from check_asr_config_parity import block

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/translation-parity'
REFERENCE=ROOT/'design/parity/translation-reference.json'
SOURCES=[ROOT/'apps/macos/Sovereign'/p for p in ('Engine/TranslationTurnQueue.swift','Transcript/TranslationShedPolicy.swift','Engine/TranslationStability.swift')]
def encoded(value):
    return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf-8')
def turn(index,lang,source,kind,reserved=False):
    return dict(id=f'00000000-0000-0000-0000-{index:012x}',lang=lang,source=source,prompt='prompt '+source,prefix='head',body='body '+source,retries=1,kind=kind,reserved=reserved,forced=None,exampleTarget=None,exampleSource=None)
def cases():
    values=['','Yes.','안녕하세요.','日本語ですね。','你好。','café','cafe\u0301','ΟΣ','οσ','ος','İ','i\u0307','한글','한글','\u0345','1️⃣','① Ⅳ ½','👩🏽‍💻','ᄀ\u0301',' \u0301','e\u0301 \u0301x']
    outputs=values+['原文 </think> Hello.','<think>unfinished','<think>inside</think> answer','answer </think>','<think>x</think><think>y</think>',
        'Now: No.','이제: 이제 여기에서 멈춥니다.','现在：否。 </think> 现在：否。','목표中文：','Translation： Now: . word =>','이제:；　Korean: text ->',
        'a->b A → B','A\t-> B','a  ->   b','word =>. rest','그건 ->\u0301 그대로','Now:\u0301text','=>\u0301','Yes. Yes.','Yes. Yes. Yes.','是的。 是的。 是的。','Keep this. Keep that. Keep this.',
        '<think>\u0301hidden','before <think>hi</think>\u0301tail','text </think>\u0301 tail','Translation:  \u0301 =>','a   ->    b']
    rng=random.Random(2026110502);result=[]
    for i,text in enumerate(outputs):
        for target in ['English','Korean','Japanese','Chinese','French','Other']:
            result.append(dict(kind='policy',text=text,source=rng.choice(values),target=target,example=rng.choice(values+[None]),exampleSource=rng.choice(values+[None]),limit=rng.choice([0,1,8,9,20,80])))
    for _ in range(900):
        text=rng.choice(['','Now: ','Translation: ','现在：','<think>draft</think> '])+rng.choice(outputs)+rng.choice(['',' =>','\n',' '+rng.choice(values)])
        result.append(dict(kind='policy',text=text,source=rng.choice(values)*rng.choice([1,2,40]),target=rng.choice(['English','Korean','Japanese','Chinese','French']),example=rng.choice(values+[None]),exampleSource=rng.choice(values+[None]),limit=rng.choice([0,1,8,20,80,200])))
    # Include positive replay/echo matches and boundary decisions; short random
    # strings alone cannot exercise the >=12-key replay guard.
    paragraph='말하면 말하면, 나는 그 중 아주 큰 부분이지. 그리고 추론과 데이터센터 구축으로 돌아가면서, 어떤 일이 일어날지 궁금해하는 가운데.'
    chinese='因此，移动这些点并逐渐加入噪声，使其完全变成一个球体，这是第一步；接下来再去掉噪声。'
    english='During the pandemic, we filmed how people in cities kept their distance.'
    explicit=[
        ('是的。因为你被放到了29号位，对吧?',"Cause you're up put aside to 29, right?",'Chinese','是的。','Yeah.'),
        (paragraph+' 알지, 아침 3시에 화장실 갈 때 이 약을 복용해.','You know, when you get up to pee at three in the morning, take this medication.','Korean',paragraph,'an earlier source'),
        ('哇。太疯狂了。好吧，听着，这就是你和马克·库班45分钟的对话，独一无二。','only.','Chinese','哇。太疯狂了。好吧，听着，这就是你和马克·库班45分钟的对话，独一无二。','earlier source'),
        (chinese.replace('再去掉','去掉'),'그리고 얘는 노이즈를 계속 없애요.','Chinese',chinese,'그럼 이 점들을 옮기고 노이즈를 조금씩 넣어서 완전히 공처럼 만드는 게 첫 단계고'),
        (english,'코로나 때 사회적 거리두기 같은 걸 하기 위해서 도시에서 사람들이 어떻게','English',english,'코로나 때 사회적 거리두기 같은 걸 하기 위해서 도시에서 사람들이'),
        ('是的。','Yes.','Chinese','是的。','Yeah.'),
        ('是的。因','new source','Chinese','是的。因为','earlier source'),
        ('abcdefghijXY','other source','English','abcdefghijAB','earlier source'),
        ('abcdefghij','abcdefghij','English','abcdefghij','abcdefghij'),
        ('cafe\u0301 cafe\u0301. tail','other source','English','CAFÉ CAFÉ','earlier source'),
        ('01234567. More and more text.','input','English',None,None),
        ('012345678. More and more text.','input','English',None,None),
        ('Yes. Yes. Yes!','Yes.','English',None,None),
    ]
    for text,source,target,example,example_source in explicit:
        for limit in [0,8,9,10,20,80,200]:
            result.append(dict(kind='policy',text=text,source=source,target=target,example=example,exampleSource=example_source,limit=limit))
    whitespace='\t\r\n\u0085\u00a0\u1680\u200b\u2028\u2029\u202f\u205f\u3000'
    for space in whitespace:
        for text in [space+'Translation: answer'+space,space+'<think>hidden</think>'+space,space+'=>'+space,space+'x'+space]:
            result.append(dict(kind='policy',text=text,source='input',target='English',example=None,exampleSource=None,limit=8))
    for _ in range(512):
        scalar=rng.choice([rng.randrange(0xd800),rng.randrange(0xe000,0x110000)])
        text=chr(scalar)+rng.choice(['','\u0301','\u0345','\ufe0f','\u20e3'])
        result.append(dict(kind='policy',text=text,source='input',target='English',example=text,exampleSource='another source',limit=1))
    for source,text in [('Hello world','Hello world again'),('Hello world again','Hello world'),('hello!!!','HELLO?'),('한글','한글'),('café','cafe\u0301'),('example','other'),('', 'other'),('one\ntwo','other'),('one\rtwo','other'),('one\r\ntwo','other'),('x'*201,'other')]+list(itertools.product(values,values)):
        for maximum in [0,2,200]:
            result.append(dict(kind='prompt',example=dict(source=source,target='target'),text=text,maxChars=maximum,anchor='안녕하세요'))
    for target in ['', 'x'*199, 'x'*200, 'x'*201, 'one\ntwo', 'one\r\ntwo', 'one\rtwo', '한글', '한글']:
        result.append(dict(kind='prompt',example=dict(source='example source',target=target),text='other source',maxChars=200,anchor='Hello'))
    result.append(dict(kind='prompt',example=None,text='other source',maxChars=200,anchor='こんにちは'))
    for targets,p,backlog,threshold in itertools.product([[],['Chinese'],['Chinese','Korean'],['Korean','Korean','English']],[None,'Korean','English'],[0,2,3,6,7,20],[0,6]):
        result.append(dict(kind='shed',requested=targets,priority=p,backlog=backlog,threshold=threshold,base=3 if backlog!=20 else 0))
    for bits,backlog in itertools.product(['0000000000000000','8000000000000000','c008000000000000','4008000000000000','0000000000000001','7fefffffffffffff','7ff0000000000000','fff0000000000000','7ff8000000000000'],[0,2,3,6,7]):
        result.append(dict(kind='guarantee',baseBits=bits,backlog=backlog))
    for _ in range(180):
        ops=[]
        for index in range(35):
            operation=rng.choices(['enqueue','pop','shed','reset'],[8,2,2,1])[0]
            if operation=='enqueue':ops.append(dict(op=operation,turn=turn(rng.randrange(4),rng.choice(['English','Korean','Café','Café']),f'revision {index}',rng.choice(['committed','interim']),rng.choice([False,False,True])),block=rng.choice([False,True]),replace=rng.choice([True,True,False])))
            elif operation=='shed':ops.append(dict(op=operation,cap=rng.choice([0,1,2,5])))
            else:ops.append(dict(op=operation))
        result.append(dict(kind='queue',operations=ops))
    return result

DRIVER=r'''
// Internal keys have Swift Character equality (canonical equivalence). Only
// this diagnostic projection is normalized; all product text stays byte-exact.
extension TranslationOutputPolicy { static func oracleKeys(_ text:String)->[String] {echoKeys(text).map{String($0).precomposedStringWithCanonicalMapping}} }
@main enum Main {
 static func serialize(_ t:TranslationTurn)->[String:Any] {
  ["id":t.id.uuidString.lowercased(),"lang":t.lang,"source":t.source,"prompt":t.prompt,"prefix":t.prefix as Any? ?? NSNull(),"body":t.body as Any? ?? NSNull(),"retries":t.retries,"kind":t.kind == .committed ? "committed":"interim","reserved":t.reserved,"forced":t.forced as Any? ?? NSNull(),"exampleTarget":t.exampleTarget as Any? ?? NSNull(),"exampleSource":t.exampleSource as Any? ?? NSNull()]
 }
 static func turn(_ t:[String:Any])->TranslationTurn {
  TranslationTurn(id:UUID(uuidString:t["id"] as! String)!,lang:t["lang"] as! String,source:t["source"] as! String,prompt:t["prompt"] as! String,prefix:t["prefix"] as? String,body:t["body"] as? String,retries:t["retries"] as! Int,kind:t["kind"] as! String == "committed" ? .committed:.interim,reserved:t["reserved"] as! Bool,forced:t["forced"] as? String,exampleTarget:t["exampleTarget"] as? String,exampleSource:t["exampleSource"] as? String)
 }
 static func main() throws {
  let cases=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [[String:Any]]
  var results:[Any]=[]
  for c in cases {
   switch c["kind"] as! String {
   case "policy":
    let source=c["source"] as! String,text=c["text"] as! String,target=c["target"] as! String,example=c["example"] as? String
    results.append(["clean":TranslationOutputPolicy.clean(text),"markers":TranslationOutputPolicy.stripPromptMarkerEcho(text),"arrows":TranslationOutputPolicy.stripInlineArrows(text),"stripped":TranslationOutputPolicy.stripExampleEcho(text,exampleTarget:example,source:source),"mayEcho":TranslationOutputPolicy.mayBeExampleEcho(text,exampleTarget:example),"replay":TranslationOutputPolicy.isExampleReplay(text,exampleTarget:example,source:source,exampleSource:c["exampleSource"] as? String),"retry":TranslationOutputPolicy.shouldRetry(text,source:source,target:target),"cap":TranslationOutputPolicy.tokenCap(source:source),"limit":TranslationOutputPolicy.runawayLimit(source:source,target:target),"factor":TranslationOutputPolicy.expansionFactor(source:source,target:target),"cut":TranslationOutputPolicy.truncateRunaway(text,limit:c["limit"] as! Int),"language":TranslationOutputPolicy.sourceLanguageName(for:source),"keys":TranslationOutputPolicy.oracleKeys(text),"similarityBits":String(format:"%016llx",TranslationOutputPolicy.similarity(text,source).bitPattern)])
   case "prompt":
    let ex=(c["example"] as? [String:String]).map{TranslatePrompt.Example(source:$0["source"]!,target:$0["target"]!)}
    let usable=TranslatePrompt.usableExample(ex,for:c["text"] as! String,maxChars:c["maxChars"] as! Int)
    results.append(["usable":usable.map{["source":$0.source,"target":$0.target]} as Any? ?? NSNull(),"body":TranslatePrompt.body(text:c["text"] as! String,example:usable,anchor:c["anchor"] as! String)])
   case "shed":
    let decision=TranslationShedPolicy.committedTargets(requested:c["requested"] as! [String],priority:c["priority"] as? String,committedBacklog:c["backlog"] as! Int,threshold:c["threshold"] as! Int)
    results.append(["send":decision.send,"shed":decision.shed,"guarantee":InterimTuning.adaptiveGuarantee(base:c["base"] as! Double,committedBacklog:c["backlog"] as! Int) as Any? ?? NSNull()])
   case "guarantee":
    let base=Double(bitPattern:UInt64(c["baseBits"] as! String,radix:16)!)
    let interval=InterimTuning.adaptiveGuarantee(base:base,committedBacklog:c["backlog"] as! Int)
    results.append(["bits":interval.map{String(format:"%016llx",$0.bitPattern)} as Any? ?? NSNull()])
   default:
    var queue=TranslationTurnQueue();var rows:[[String:Any]]=[]
    for op in c["operations"] as! [[String:Any]] {
     var result:Any=NSNull()
     switch op["op"] as! String {
      case "enqueue":let value=queue.enqueue(turn(op["turn"] as! [String:Any]),blockInterim:op["block"] as! Bool,replaceExisting:op["replace"] as! Bool);result=["accepted":value.accepted,"displaced":value.displaced.map(serialize)]
      case "pop":result=queue.popNext().map(serialize) as Any? ?? NSNull()
      case "shed":result=queue.shedOldest(to:op["cap"] as! Int).map(serialize)
      default:queue.removeAll()
     }
     rows.append(["result":result,"turns":queue.turns.map(serialize),"next":queue.next.map(serialize) as Any? ?? NSNull(),"hasCommitted":queue.hasCommitted])
    }
    results.append(rows)
   }
  }
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys,.fragmentsAllowed]))
 }
}
'''
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--rust-only',action='store_true');p.add_argument('--write-reference',action='store_true');args=p.parse_args()
    if args.write_reference and args.rust_only:p.error('Native Swift required')
    if not args.rust_only and platform.system()!='Darwin':p.error('Native Swift requires macOS')
    OUT.mkdir(parents=True,exist_ok=True);corpus=cases();payload=encoded(corpus);(OUT/'cases.json').write_bytes(payload)
    subprocess.run([os.environ.get('CARGO','cargo'),'build','--locked','-p','madi-core','--example','translation_oracle'],cwd=ROOT,check=True)
    binary=ROOT/'target/debug/examples'/('translation_oracle.exe' if os.name=='nt' else 'translation_oracle')
    actual=json.loads(subprocess.check_output([str(binary)],input=payload));(OUT/'result.json').write_bytes(encoded(actual))
    if not args.rust_only:
        tuning=block(SOURCES[2].read_text(encoding='utf-8'),'    static func adaptiveGuarantee(')
        driver=OUT/'TranslationOracle.swift';driver.write_text(SOURCES[0].read_text(encoding='utf-8')+'\nenum InterimTuning {\n'+tuning+'\n}\n'+DRIVER,encoding='utf-8')
        native=OUT/'swift-oracle';subprocess.run(['xcrun','swiftc','-parse-as-library',str(driver),str(SOURCES[1]),'-o',str(native)],check=True)
        expected=json.loads(subprocess.check_output([str(native)],input=payload));(OUT/'swift.json').write_bytes(encoded(expected))
        for index,(case,want,got) in enumerate(zip(corpus,expected,actual,strict=True)):
            assert want==got,json.dumps(dict(index=index,case=case,swift=want,rust=got),ensure_ascii=False,indent=2)
    kinds=dict(Counter(c['kind'] for c in corpus))
    decisions={key:sum(bool(row[key]) for case,row in zip(corpus,actual,strict=True) if case['kind']=='policy') for key in ('replay','mayEcho','retry')}
    assert all(decisions.values()),'Policy corpus must include positive retry and echo/replay decisions'
    report=dict(cases=len(corpus),caseKinds=kinds,queueOperations=sum(len(c['operations']) for c in corpus if c['kind']=='queue'),positivePolicyDecisions=decisions,corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(encoded(actual)).hexdigest(),sources={s.relative_to(ROOT).as_posix():hashlib.sha256(s.read_bytes()).hexdigest() for s in SOURCES})
    if args.write_reference:REFERENCE.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    else:assert report==json.loads(REFERENCE.read_text(encoding='utf-8')),'Translation reference changed'
    report.update(status='passed',nativeSwiftRun=not args.rust_only)
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
