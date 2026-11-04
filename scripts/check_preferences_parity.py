#!/usr/bin/env python3
"""Original Swift initializers/AppStorage vs native Rust and portable restoration."""
import argparse, hashlib, itertools, json, os, platform, re, struct, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT/'apps/macos/Sovereign'
OUT = ROOT/'out/preferences-parity'
SOURCES = [BASE/p for p in ('SessionController.swift', 'UI/ContentView.swift', 'UI/L10n.swift', 'SovereignApp.swift', 'Audio/AudioSource.swift', 'Transcript/MeetingMode.swift')]
REFERENCE = ROOT/'design/parity/preferences-reference.json'
def digest(value): return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
def cases():
    result = [{}]
    for mode, count, diarize in itertools.product(['general','oneOnOne','standup','interview','lecture','future'],[-1,0,1,2,3,4,5,6,255],[None,False,True]):
        value = dict(meetingMode=mode,fixedSpeakerCount=count)
        if diarize is not None: value['diarizeEnabled']=diarize
        result.append(value)
    values = [False,True,-2,0,1,2,22.5,'','true','false','YES','NO','1','0','22.5','en','ja','ko','light','dark','system',[],['x'],{'x':'y'}]
    for key, value in itertools.product(['languageTokenID','fixedSpeakerCount','diarizeEnabled','audioSource','meetingMode','uiLanguage','appearance','transcriptViewMode','transcriptFontSize','translateTargets'],values):
        result.append({key:value})
    for token in [-2**63,0,1,50259,50260,50264,50266,99999,2**32,2**63-1]:
        result.append(dict(languageTokenID=token,translateTargets=['Korean','English','Japanese','Chinese'],meetingMode='lecture',fixedSpeakerCount=4,diarizeEnabled=True))
    for targets in [[],['Japanese']*3,['Korean','English','Japanese','Chinese','unknown'],['é','e\u0301','가','가','👨‍👩‍👧','🧑','a','A','😀','💡'],['e\u0301','é'],['가','가'],['',' ', 'É','E\u0301','ß','ss','𝄞','\U0001f600']]:
        result.append(dict(translateTargets=targets))
    for size in [-100,-0.0,0,1,11.5,12,16,33,34,35,100,1e100]: result.append(dict(transcriptFontSize=size))
    return result

def source():
    session, view, lang, app, audio, meeting = [p.read_text(encoding="utf-8") for p in SOURCES]
    def enum(text,name):
        start=text.index('enum '+name+':');end=text.index('    var ',start)
        prefix=text[start:end].rstrip()
        return prefix.split('{',1)[0].split(', CaseIterable')[0]+' {\n'+prefix.split('{',1)[1]+'\n}\n'
    definitions='import Foundation\nimport SwiftUI\n'+''.join(enum(text,name) for text,name in [(lang,'UILanguage'),(app,'Appearance'),(audio,'AudioSource'),(meeting,'MeetingMode'),(session,'SpeakerCount')])
    declarations=[]
    for name in ['diarize','languageTokenID','audioSource','speakerCount','meetingMode','translateTargets']:
        start=session.index('    var '+name+':')
        end=session.index('}()',start)+3 if name in ['diarize','languageTokenID'] else session.index(' {\n',start)
        declarations.append(session[start:end].replace('var '+name+':','let '+name+':',1).replace('UserDefaults.standard','defaults'))
    app_storage=[]
    for text, field in [(view,'contentMode'),(view,'fontSize'),(app,'appearance'),(app,'uiLang')]:
        line=next(line.strip() for line in text.splitlines() if '@AppStorage(' in line and re.search(r'var '+field+r'\b',line))
        key=re.search(r'@AppStorage\("(.*?)"\)',line)[1]
        initial=line.split(' = ',1)[1].split('//',1)[0].strip()
        app_storage.append(f'let {field} = AppStorage(wrappedValue: {initial}, "{key}", store: defaults).wrappedValue')
    smaller=re.search(r'Button \{ (fontSize = max\(12, fontSize - 2\)) \}',view)[1]
    larger=re.search(r'Button \{ (fontSize = min\(34, fontSize \+ 2\)) \}',view)[1]
    return definitions+'''\n@main enum Driver { static func main() throws {
let cases = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String:Any]]
let defaults = UserDefaults(suiteName: "madi-preferences-oracle-\\(UUID().uuidString)")!
var outputs: [[String:Any]] = []; var normalized: [[String:Any]] = []
for raw in cases {
 defaults.setVolatileDomain(raw, forName: UserDefaults.argumentDomain)
'''+ '\n'.join(declarations+app_storage)+'''
 let none = NSNull()
 let restored: [String:Any] = ["schema":1,"languageTokenId":languageTokenID as Any? ?? none,"translateTargets":translateTargets.sorted(),"meetingMode":meetingMode.rawValue,"diarize":diarize,"speakerCount":speakerCount.rawValue,"audioSource":audioSource.rawValue,"presentation":["uiLanguage":uiLang.rawValue,"appearance":appearance.rawValue,"contentMode":contentMode,"fontSize":fontSize]]
 func fontSteps(_ initial:Double)->[String] {
 var fontSize = initial
 var steps = [String(format:"%016llx",fontSize.bitPattern)]
 for small in [true,true,false,false,false,true] {
 if small { '''+smaller+''' } else { '''+larger+''' }
 steps.append(String(format:"%016llx",fontSize.bitPattern))
 }
 return steps
 }
 let steps = fontSteps(fontSize)
 let names = [50259:"English",50260:"Chinese",50264:"Korean",50266:"Japanese"]
 outputs.append(["restored":restored,"fontSteps":steps,"inputLanguage":languageTokenID.flatMap { names[$0] } as Any? ?? none,"engineToken":languageTokenID as Any? ?? none,"nonEnglishFeatures":languageTokenID != nil && languageTokenID != 50259])
 func bool(_ key:String)->Any {defaults.object(forKey:key) == nil ? none : defaults.bool(forKey:key)}
 normalized.append(["languageTokenId":defaults.integer(forKey:"languageTokenID"),"translateTargets":defaults.stringArray(forKey:"translateTargets") ?? [],"meetingMode":defaults.string(forKey:"meetingMode") ?? "","diarizeEnabled":bool("diarizeEnabled"),"fixedSpeakerCount":defaults.integer(forKey:"fixedSpeakerCount"),"audioSource":defaults.string(forKey:"audioSource") ?? "","uiLanguage":defaults.string(forKey:"uiLanguage") ?? "","appearance":defaults.string(forKey:"appearance") ?? "","transcriptViewMode":bool("transcriptViewMode"),"transcriptFontSize":defaults.object(forKey:"transcriptFontSize") == nil ? none : defaults.double(forKey:"transcriptFontSize")])
 defaults.removeVolatileDomain(forName:UserDefaults.argumentDomain)
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:["results":outputs,"normalized":normalized],options:[.sortedKeys,.fragmentsAllowed]))
}}
'''

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--rust-only',action='store_true');parser.add_argument('--update-reference',action='store_true');args=parser.parse_args()
    if args.rust_only and args.update_reference: raise SystemExit('A live Swift run is required to update the reference')
    OUT.mkdir(parents=True,exist_ok=True)
    corpus=cases(); sources={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
    subprocess.run(['cargo','build','--locked','-p','madi-platform','--example','preferences_oracle'],cwd=ROOT,check=True)
    exe=ROOT/('target/debug/examples/preferences_oracle'+('.exe' if os.name=='nt' else ''))
    def rust(values,normalized=False):return json.loads(subprocess.check_output([str(exe)]+(['--normalized'] if normalized else []),input=json.dumps(values,ensure_ascii=False).encode()))
    if args.rust_only:
        reference=json.loads(REFERENCE.read_text(encoding="utf-8"));assert reference['sources']==sources and reference['corpusSHA256']==digest(corpus)
        result=rust(reference['normalized'],True)
        assert digest(result)==reference['resultSHA256'],'portable preference restoration mismatch'
        report={k:v for k,v in reference.items() if k!='normalized'}
    else:
        if platform.system()!='Darwin':raise SystemExit('Live AppStorage comparison requires macOS')
        driver=OUT/'OriginalPreferences.swift';driver.write_text(source(),encoding="utf-8")
        executable=OUT/'swift-preferences'
        subprocess.run(['swiftc','-parse-as-library',str(driver),'-o',str(executable)],check=True)
        swift=json.loads(subprocess.check_output([str(executable)],input=json.dumps(corpus,ensure_ascii=False).encode()))
        # Foundation JSON prints negative zero as 0. Carry the observed Swift
        # Double bits into the portable fixture instead of erasing its sign.
        for value, expected in zip(swift['normalized'],swift['results']):
            if value['transcriptFontSize'] is not None:
                value['transcriptFontSize']=struct.unpack('>d',bytes.fromhex(expected['fontSteps'][0]))[0]
        native=rust(corpus);portable=rust(swift['normalized'],True)
        if swift['results']!=native or native!=portable:
            (OUT/'mismatch.json').write_text(json.dumps(dict(swift=swift,native=native,portable=portable),ensure_ascii=False,indent=2),encoding="utf-8")
            raise SystemExit('Preference parity mismatch: out/preferences-parity/mismatch.json')
        report=dict(schemaVersion=1,status='passed',cases=len(corpus),fontStepSnapshots=len(corpus)*7,sources=sources,corpusSHA256=digest(corpus),resultSHA256=digest(native))
        reference=dict(**report,normalized=swift['normalized'])
        if args.update_reference:
            REFERENCE.write_text(json.dumps(reference,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        else:
            assert json.loads(REFERENCE.read_text(encoding="utf-8"))==reference, 'Pinned preference reference differs; review source/corpus changes before updating'
    report['comparison']='pinned-swift' if args.rust_only else 'live-swift-and-native-foundation'
    report['nativeFoundationBridgeRun']=not args.rust_only
    report['scope']='Original Swift initializers and SwiftUI AppStorage getters, read-only native Foundation bridge, portable restoration and font buttons. Volatile synthetic domains only. No original preferences changed; real-user migration and native UI NOT_RUN.'
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
