#!/usr/bin/env python3
"""Check native name conflicts and the pinned portable Foundation case folding."""
import argparse,hashlib,json,os,platform,random,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/reconcile-names-parity'
TABLE=ROOT/'crates/madi-core/src/reconcile/name_fold.rs'
REFERENCE=ROOT/'design/parity/reconcile-names-reference.json'
def encoded(x):return json.dumps(x,ensure_ascii=False,separators=(',',':'),sort_keys=True).encode()
def corpus():
 rows=[]
 for line in TABLE.read_text(encoding='utf-8').splitlines():
  match=re.fullmatch(r'\s*\(\'\\u\{([0-9a-f]+)\}\', "(.*?)"\),',line)
  if match:rows.append((chr(int(match[1],16)),''.join(chr(int(n,16)) for n in re.findall(r'\\u\{([0-9a-f]+)\}',match[2]))))
 assert len(rows)>1000
 candidates=[(chr(r['scalar']),r['fold']) for r in json.loads((ROOT/'design/parity/reconcile-name-candidates.json').read_text(encoding='utf-8'))]
 pairs=[]
 for a,b in dict.fromkeys(candidates+rows):pairs.extend([(a,b),(a,'#'+b),('A'+a+'ß','a'+b+'SS'),(a+'\u0301',b+'\u0301')])
 names=['Alice','ALICE','alice','Bob','Straße','STRASSE','é','e\u0301','É','e','E','İ','i','I','ı','ΟΣ','οσ','ος','ὈΣ','ﬃ','FFI','K','k','K','Ａ','A','김','김','\u200b','', 'a\u200b','a','Å','A\u030a','A\u0301\u0323','a\u0323\u0301','Σ\u0345','σ\u0345','ᾈ','ἀι','👩\u200d💻','👩💻']
 pairs.extend((a,b) for a in names for b in names)
 pairs.extend([('ᾀ','α\u0313\u0345'),('α\u0313\u0345','ἀι'),('A\u0345','aι'),('Σ\u0345','σι'),('\u0345\u0301','\u0301\u0345')])
 for n in [1,2,62,63,64,65,66,100]:
  pairs.extend([('A'+'\u0301'*n,'a'+'\u0301'*n),('A'+'\u0301'*n+'\u0345','a'+'\u0301'*n+'ι')])
 rng=random.Random(20261105)
 mapping=dict(candidates)
 pool=[a for a,b in candidates]+names+['\u0301','\u0345','\0','\u0323']
 for i in range(4000):
  left=''.join(rng.choices(pool,k=1+i%7))
  right=''.join(mapping.get(c,c) for c in left)
  pairs.append((left,right))
  if i%2==0:pairs.append((left+'\u0301',right+'\u0301'))
 return pairs,rows
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--rust-only',action='store_true');p.add_argument('--write-reference',action='store_true');a=p.parse_args();assert not(a.rust_only and a.write_reference)
 OUT.mkdir(parents=True,exist_ok=True);pairs,rows=corpus();payload=encoded(pairs);(OUT/'corpus.json').write_bytes(payload)
 subprocess.run(['cargo','build','--locked','-p','madi-platform','--example','reconcile_names_oracle'],cwd=ROOT,check=True)
 exe=ROOT/'target/debug/examples'/('reconcile_names_oracle.exe' if os.name=='nt' else 'reconcile_names_oracle')
 actual=json.loads(subprocess.check_output([str(exe)],input=payload));(OUT/'result.json').write_bytes(encoded(actual))
 native=None;fold_rows=None
 if not a.rust_only:
  assert platform.system()=='Darwin';swift=OUT/'swift-oracle'
  subprocess.run(['xcrun','swiftc','-parse-as-library',str(ROOT/'tests/parity/ReconcileNames.swift'),'-o',str(swift)],check=True)
  native=json.loads(subprocess.check_output([str(swift)],input=payload));(OUT/'swift.json').write_bytes(encoded(native))
  assert actual['native']==native,'Native Foundation name conflict comparison changed'
  if a.write_reference:
   fold_rows=json.loads(subprocess.check_output([str(swift),'--fold']))
   assert [(chr(r['scalar']),r['fold']) for r in fold_rows]==rows,'Generated Foundation folding table is stale'
   native_extend=json.loads(subprocess.check_output([str(swift),'--extend']))
   table_extend=[int(n) for n in re.findall(r'\d+',TABLE.read_text(encoding='utf-8').split('const EXTEND: &[u32] = &[',1)[1])]
   assert native_extend==table_extend,'Grapheme-extend table is stale'
   mismatches=[(i,pairs[i],want,actual['portable'][i]) for i,want in enumerate(native) if want!=actual['portable'][i]]
   assert not mismatches,mismatches[:20]
 report={'cases':len(pairs),'foldMappings':len(rows),'corpusSHA256':hashlib.sha256(payload).hexdigest(),'portableResultSHA256':hashlib.sha256(encoded(actual['portable'])).hexdigest(),'foldTableSHA256':hashlib.sha256(TABLE.read_bytes()).hexdigest(),'controllerSHA256':hashlib.sha256((ROOT/'apps/macos/Sovereign/SessionController.swift').read_bytes()).hexdigest()}
 if a.write_reference:REFERENCE.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
 else:assert report==json.loads(REFERENCE.read_text(encoding='utf-8')),'Portable Foundation reference changed'
 report.update(status='passed',nativeSwiftRun=native is not None,hostUnicodeDifferences=None if native is None else sum(x!=y for x,y in zip(native,actual['portable'],strict=True)),scope='Native host matches its unchanged Foundation comparison. Portable names match the pinned macOS baseline, including canonical equivalence and case expansions. Host Unicode version differences are reported, not mistaken for native behavior drift.')
 (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
