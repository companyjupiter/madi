#!/usr/bin/env python3
"""Compare FAQ and interim reuse with unchanged shipping Swift cache bodies."""
import argparse, hashlib, json, os, platform, random, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/translation-cache-parity'
REFERENCE = ROOT / 'design/parity/translation-cache-reference.json'
SOURCES = [ROOT / 'apps/macos/Sovereign/Transcript' / name for name in ('FAQTranslationStore.swift', 'InterimTranslationCache.swift')]
def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')
def case(text='', entries=None, queries=None, ops=None, capacity=15):
    return dict(text=text,entries=entries,queries=queries or [],ops=ops or [],capacity=capacity)
def cases():
    rows = []
    # Every Unicode scalar goes through native normalization: this detects
    # Foundation/Unicode-version category differences rather than assuming them.
    for first in range(0, 0x110000, 4096):
        text = ''.join(chr(i) for i in range(first, min(first+4096,0x110000)) if not 0xd800 <= i <= 0xdfff)
        rows.append(case(text))
    seed = json.loads((ROOT/'crates/madi-core/src/translation/faq_starter.json').read_text(encoding='utf-8'))
    queries = [text for entry in seed for text in entry.values()]
    queries += ['시술후 3일간 사우나와 격한 운동은 피해주세요','시술 후 5일간 사우나와 격한 운동은 피해 주세요.','네.','痛みはありますか','아픈가요','xxxx']
    seed_case=case(queries[0],queries=queries);seed_case['includeSeed']=True;rows.append(seed_case)
    entries = [{'English':'CAFÉ here!','Korean':'여기에서 말합니다.'},{'English':'abcd','Japanese':'あいうえ'},{'English':'same source','Japanese':'old answer'},{'English':'SAME source!','Japanese':'new answer'}]
    rows.append(case('cafe\u0301 here?', entries=entries, queries=['cafe\u0301 here?','CAFÉ HERE','여기에서말합니다','same source','old answer','abcd','ABC','あいうえ']))
    values = ['', ' \u200b ', 'a\nb','a b','a\r\nb',' a\r\nb ', 'café source','cafe\u0301 source','ΟΣ word','οσ word','abc.','ab\u0301cd','👩🏽\u200d💻abcd','hello world','안녕하세요','你好世界','日本語です']
    rng = random.Random(2026110505)
    for index in range(120):
        ops=[]
        for _ in range(60):
            op=rng.choice(['put']*4+['get']*3+['peek']*2+['clear'])
            row=dict(op=op,source=rng.choice(values))
            if op=='put':row['translations']=rng.choice([{}, {'English':'answer'}, {'Japanese':'日本語です'},{'English':'','Korean':'번역'},{'English':'updated','Japanese':'更新'}])
            ops.append(row)
        rows.append(case(values[index%len(values)],ops=ops,capacity=rng.choice([-1,0,1,3,15])))
    return rows
SWIFT = r'''
struct Case: Decodable {
    struct Op: Decodable { let op: String; let source: String?; let translations: [String:String]? }
    let text: String; let entries: [[String:String]]?; let queries: [String]; let ops: [Op]; let capacity: Int; let includeSeed: Bool?
}
@main struct Main {
    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let result: [[String:Any]] = cases.map { c in
            let faq = FAQTranslationStore(entries: c.entries ?? FAQTranslationStore.starterPack)
            var cache = InterimTranslationCache(capacity: c.capacity)
            var states: [[String:Any]] = []
            for op in c.ops {
                var hit: [String:String]? = nil
                switch op.op {
                case "put": cache.put(op.source ?? "", op.translations ?? [:])
                case "get": hit = cache.get(op.source ?? "")
                case "peek": hit = cache.peek(op.source ?? "")
                case "clear": cache.clear()
                default: fatalError("unknown op")
                }
                states.append(["hit": hit as Any? ?? NSNull(), "count": cache.count, "empty": cache.isEmpty])
            }
            return ["starterEntries": c.includeSeed == true ? FAQTranslationStore.starterPack as Any : NSNull(), "faqNormalized": FAQTranslationStore.normalize(c.text) as Any? ?? NSNull(), "interimNormalized": InterimTranslationCache.normalize(c.text) as Any? ?? NSNull(), "queries":c.queries.map { faq.lookup($0) as Any? ?? NSNull() }, "states":states]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]))
    }
}
'''
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--rust-only',action='store_true');p.add_argument('--write-reference',action='store_true');a=p.parse_args()
    if a.rust_only and a.write_reference:p.error('Native Swift is required to write references')
    if not a.rust_only and platform.system()!='Darwin':p.error('Native Swift requires macOS')
    OUT.mkdir(parents=True,exist_ok=True);corpus=cases();payload=encoded(corpus);(OUT/'cases.json').write_bytes(payload)
    subprocess.run([os.environ.get('CARGO','cargo'),'build','--locked','-p','madi-platform','--example','translation_cache_oracle'],cwd=ROOT,check=True)
    binary=ROOT/'target/debug/examples'/('translation_cache_oracle.exe' if os.name=='nt' else 'translation_cache_oracle')
    actual=json.loads(subprocess.check_output([str(binary)],input=payload));(OUT/'result.json').write_bytes(encoded(actual))
    native_result = None
    if not a.rust_only:
        native_result=json.loads(subprocess.check_output([str(binary),'--native-foundation'],input=payload));(OUT/'native-result.json').write_bytes(encoded(native_result))
        driver=OUT/'CacheOracle.swift';driver.write_text('import Foundation\n'+SWIFT,encoding='utf-8')
        binary=OUT/'swift-oracle';subprocess.run(['xcrun','swiftc','-parse-as-library',str(driver),*(str(s) for s in SOURCES),'-o',str(binary)],check=True)
        expected=json.loads(subprocess.check_output([str(binary)],input=payload));(OUT/'swift.json').write_bytes(encoded(expected))
        for i,(want,got) in enumerate(zip(expected,native_result,strict=True)):
            if want!=got:
                differences={k:dict(swift=str(want[k])[:240],rust=str(got[k])[:240]) for k in want if want[k]!=got[k]}
                raise AssertionError(json.dumps(dict(case=i,differences=differences),ensure_ascii=False))
    report=dict(cases=len(corpus),unicodeScalars=0x110000-2048,operations=sum(len(c['ops']) for c in corpus),corpusSHA256=hashlib.sha256(payload).hexdigest(),resultSHA256=hashlib.sha256(encoded(actual)).hexdigest(),sources={s.relative_to(ROOT).as_posix():hashlib.sha256(s.read_bytes()).hexdigest() for s in SOURCES},starterSHA256=hashlib.sha256((ROOT/'crates/madi-core/src/translation/faq_starter.json').read_bytes()).hexdigest())
    if a.write_reference:
        assert actual==native_result,'Portable baseline must match the original native platform when pinning'
        REFERENCE.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    else:assert report==json.loads(REFERENCE.read_text(encoding='utf-8')),'Cache reference changed'
    report.update(status='passed',nativeSwiftRun=not a.rust_only,nativeResultSHA256=hashlib.sha256(encoded(native_result)).hexdigest() if native_result is not None else None,nativeVsPortableDifferenceCases=sum(a!=b for a,b in zip(native_result,actual,strict=True)) if native_result is not None else None,scope='Unchanged FAQTranslationStore and InterimTranslationCache; filesystem persistence tested separately; ambiguous same-normalized columns are not in this corpus')
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
