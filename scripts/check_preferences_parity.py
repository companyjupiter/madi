#!/usr/bin/env python3
"""Original Swift initializers/AppStorage vs native Rust and portable restoration."""
import argparse, hashlib, itertools, json, os, platform, re, struct, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT/'apps/macos/Sovereign'
OUT = ROOT/'out/preferences-parity'
SOURCES = [BASE/p for p in ('SessionController.swift', 'UI/ContentView.swift', 'UI/L10n.swift', 'SovereignApp.swift', 'Audio/AudioSource.swift', 'Transcript/MeetingMode.swift', 'UI/SettingsView.swift', 'UI/ClinicDisplaySupport.swift')]
REFERENCE = ROOT/'design/parity/preferences-reference.json'
def digest(value): return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
def cases():
    result = [{}]
    for mode, count, diarize in itertools.product(['general','oneOnOne','standup','interview','lecture','future'],[-1,0,1,2,3,4,5,6,255],[None,False,True]):
        value = dict(meetingMode=mode,fixedSpeakerCount=count)
        if diarize is not None: value['diarizeEnabled']=diarize
        result.append(value)
    values = [False,True,-2,0,1,2,22.5,'','true','false','YES','NO','1','0','22.5','en','ja','ko','light','dark','system',[],['x'],{'x':'y'}]
    for key, value in itertools.product(['languageTokenID','fixedSpeakerCount','diarizeEnabled','audioSource','meetingMode','uiLanguage','appearance','transcriptViewMode','transcriptFontSize','translateTargets','liveWindowSeconds','translateTailSeconds','livePreviewEnabled','aiReconcileEnabled','debugCapture','vadConfThreshold','captionSettings.v1'],values):
        result.append({key:value})
    for token in [-2**63,0,1,50259,50260,50264,50266,99999,2**32,2**63-1]:
        result.append(dict(languageTokenID=token,translateTargets=['Korean','English','Japanese','Chinese'],meetingMode='lecture',fixedSpeakerCount=4,diarizeEnabled=True))
    for targets in [[],['Japanese']*3,['Korean','English','Japanese','Chinese','unknown'],['é','e\u0301','가','가','👨‍👩‍👧','🧑','a','A','😀','💡'],['e\u0301','é'],['가','가'],['',' ', 'É','E\u0301','ß','ss','𝄞','\U0001f600']]:
        result.append(dict(translateTargets=targets))
    for size in [-100,-0.0,0,1,11.5,12,16,33,34,35,100,1e100]: result.append(dict(transcriptFontSize=size))
    caption=dict(staffFontSize=26,patientFontSize=46,panelWidth=760,minScaleFactor=0.9,patientPanelEnabled=False)
    blobs=[{},dict(caption),dict(caption,patientScreenIndex=2,patientLangOverride="Japanese"),dict(caption,staffFontSize=-50,patientFontSize=150,panelWidth=100,minScaleFactor=2)]
    for key in caption:
        for value in [None,"bad",True,-0.0,-1,0,1,14,24,48,96,480,1400]: blobs.append(dict(caption,**{key:value}))
        value=dict(caption);value.pop(key);blobs.append(value)
    for key in ('patientScreenIndex','patientLangOverride'):
        for value in [None,True,False,0,1,-1,2.5,'','Japanese','unknown',[],{},-2**63,2**63-1,2**63]: blobs.append(dict(caption,**{key:value}))
    result += [{'__captionJSON':json.dumps(value,ensure_ascii=False)} for value in blobs]
    result += [{'__captionJSON':'invalid JSON'}]
    for targets,window in itertools.product([[],['Korean'],['Korean','Japanese'],['English','Japanese'],['Korean','English','Japanese']],[5,7,10,4.5]): result.append(dict(translateTargets=targets,liveWindowSeconds=window))
    return result

def block(source,signature):
    start=source.index(signature);position=source.index('{',start)+1;depth=1
    while depth:
        depth += (source[position]=='{')-(source[position]=='}');position+=1
    return source[start:position]

def compact_legacy(value):
    # Omit only Legacy's exact default values, retaining explicit false/zero
    # for optional getters and every caption field. This keeps pinned fixtures
    # reviewable without changing absence-sensitive restoration.
    result={key:item for key,item in value.items() if key!='settings' and item is not None and item!='' and item!=[]}
    for key in ('languageTokenId','fixedSpeakerCount'):
        if result.get(key)==0: result.pop(key,None)
    settings={key:item for key,item in value['settings'].items() if item is not None}
    if settings: result['settings']=settings
    return result

def source():
    session, view, lang, app, audio, meeting, settings, clinic = [p.read_text(encoding="utf-8") for p in SOURCES]
    def enum(text,name):
        start=text.index('enum '+name+':');end=text.index('    var ',start)
        prefix=text[start:end].rstrip()
        return prefix.split('{',1)[0].split(', CaseIterable')[0]+' {\n'+prefix.split('{',1)[1]+'\n}\n'
    definitions='import Foundation\nimport SwiftUI\n'+''.join(enum(text,name) for text,name in [(lang,'UILanguage'),(app,'Appearance'),(audio,'AudioSource'),(meeting,'MeetingMode'),(session,'SpeakerCount')])
    caption=block(clinic,'struct CaptionSettings:')
    caption=caption.replace(block(caption,'    func save()'), '')
    caption=caption.replace('static func load()','static func load(_ defaults:UserDefaults)').replace('UserDefaults.standard','defaults')
    definitions+=caption+'\nstruct LiveSettings {let translateTargets:Set<String>;let liveWindowSeconds:Double\n'+block(session,'    var multiTranslateForcesAccurate:')+'\n'+block(session,'    var effectiveWindowSeconds:')+'\n}\n'
    declarations=[]
    for name in ['diarize','languageTokenID','audioSource','speakerCount','meetingMode','translateTargets','liveWindowSeconds','translateTailSeconds','livePreviewEnabled','aiReconcileEnabled']:
        start=session.index('    var '+name+':')
        end=session.index('}()',start)+3 if name in ['diarize','languageTokenID'] else session.index(' {\n',start)
        declarations.append(session[start:end].replace('var '+name+':','let '+name+':',1).replace('UserDefaults.standard','defaults'))
    app_storage=[]
    for text, field in [(view,'contentMode'),(view,'fontSize'),(app,'appearance'),(app,'uiLang'),(settings,'debugCapture'),(settings,'vadThreshold')]:
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
 var raw = raw
 if let blob=raw.removeValue(forKey:"__captionJSON") as? String { raw[CaptionSettings.key]=Data(blob.utf8) }
 defaults.setVolatileDomain(raw, forName: UserDefaults.argumentDomain)
'''+ '\n'.join(declarations+app_storage)+'''
 let none = NSNull()
 func captionJSON(_ value:CaptionSettings) throws -> [String:Any] {
 var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
 object["patientScreenIndex"] = value.patientScreenIndex as Any? ?? NSNull()
 object["patientLangOverride"] = value.patientLangOverride as Any? ?? NSNull()
 return object
 }
 let caption = CaptionSettings.load(defaults)
 let sessionSettings:[String:Any] = ["liveWindowSeconds":liveWindowSeconds,"translateTailSeconds":translateTailSeconds,"livePreviewEnabled":livePreviewEnabled,"aiReconcileEnabled":aiReconcileEnabled,"debugCapture":debugCapture,"vadConfThreshold":vadThreshold,"caption":try captionJSON(caption)]
 let restored: [String:Any] = ["settings":sessionSettings,"schema":2,"languageTokenId":languageTokenID as Any? ?? none,"translateTargets":translateTargets.sorted(),"meetingMode":meetingMode.rawValue,"diarize":diarize,"speakerCount":speakerCount.rawValue,"audioSource":audioSource.rawValue,"presentation":["uiLanguage":uiLang.rawValue,"appearance":appearance.rawValue,"contentMode":contentMode,"fontSize":fontSize]]
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
 let live = LiveSettings(translateTargets:translateTargets,liveWindowSeconds:liveWindowSeconds)
 let settingsNumericBits = [liveWindowSeconds,translateTailSeconds,vadThreshold,caption.staffFontSize,caption.patientFontSize,caption.panelWidth,caption.minScaleFactor].map {String(format:"%016llx",$0.bitPattern)}
 outputs.append(["settingsNumericBits":settingsNumericBits,"effectiveWindow":live.effectiveWindowSeconds,"multiTranslateForcesAccurate":live.multiTranslateForcesAccurate,"clampedCaption":try captionJSON(caption.clamped),"restored":restored,"fontSteps":steps,"inputLanguage":languageTokenID.flatMap { names[$0] } as Any? ?? none,"engineToken":languageTokenID as Any? ?? none,"nonEnglishFeatures":languageTokenID != nil && languageTokenID != 50259])
 func bool(_ key:String)->Any {defaults.object(forKey:key) == nil ? none : defaults.bool(forKey:key)}
 let importedCaption = defaults.data(forKey:CaptionSettings.key).flatMap { try? JSONDecoder().decode(CaptionSettings.self,from:$0) }
 let normalizedSettings:[String:Any] = ["liveWindowSeconds":defaults.object(forKey:"liveWindowSeconds") as? Double as Any? ?? none,"translateTailSeconds":defaults.object(forKey:"translateTailSeconds") as? Double as Any? ?? none,"livePreviewEnabled":defaults.object(forKey:"livePreviewEnabled") as? Bool as Any? ?? none,"aiReconcileEnabled":defaults.object(forKey:"aiReconcileEnabled") as? Bool as Any? ?? none,"debugCapture":bool("debugCapture"),"vadConfThreshold":defaults.object(forKey:"vadConfThreshold") == nil ? none : defaults.double(forKey:"vadConfThreshold"),"caption":try importedCaption.map { try captionJSON($0) } as Any? ?? none]
 normalized.append(["settings":normalizedSettings,"languageTokenId":defaults.integer(forKey:"languageTokenID"),"translateTargets":defaults.stringArray(forKey:"translateTargets") ?? [],"meetingMode":defaults.string(forKey:"meetingMode") ?? "","diarizeEnabled":bool("diarizeEnabled"),"fixedSpeakerCount":defaults.integer(forKey:"fixedSpeakerCount"),"audioSource":defaults.string(forKey:"audioSource") ?? "","uiLanguage":defaults.string(forKey:"uiLanguage") ?? "","appearance":defaults.string(forKey:"appearance") ?? "","transcriptViewMode":bool("transcriptViewMode"),"transcriptFontSize":defaults.object(forKey:"transcriptFontSize") == nil ? none : defaults.double(forKey:"transcriptFontSize")])
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
        reference=json.loads(REFERENCE.read_text(encoding="utf-8"))
        assert reference['sources']==sources, 'Preference source hashes/paths differ: '+json.dumps(sources,sort_keys=True)
        assert reference['corpusSHA256']==digest(corpus), 'Preference corpus differs from the pinned Swift corpus'
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
            bits=expected['settingsNumericBits']
            for index,key in enumerate(('liveWindowSeconds','translateTailSeconds','vadConfThreshold')):
                if value['settings'][key] is not None: value['settings'][key]=struct.unpack('>d',bytes.fromhex(bits[index]))[0]
            if value['settings']['caption'] is not None:
                for index,key in enumerate(('staffFontSize','patientFontSize','panelWidth','minScaleFactor')):
                    value['settings']['caption'][key]=struct.unpack('>d',bytes.fromhex(bits[index+3]))[0]
        native=rust(corpus);portable=rust(swift['normalized'],True)
        if swift['results']!=native or native!=portable:
            (OUT/'mismatch.json').write_text(json.dumps(dict(swift=swift,native=native,portable=portable),ensure_ascii=False,indent=2),encoding="utf-8")
            raise SystemExit('Preference parity mismatch: out/preferences-parity/mismatch.json')
        report=dict(schemaVersion=1,status='passed',cases=len(corpus),fontStepSnapshots=len(corpus)*7,captionBlobCases=sum('__captionJSON' in case for case in corpus),captionClampSnapshots=len(corpus),effectiveWindowSnapshots=len(corpus),sources=sources,corpusSHA256=digest(corpus),resultSHA256=digest(native))
        reference=dict(**report,normalized=[compact_legacy(value) for value in swift['normalized']])
        if args.update_reference:
            REFERENCE.write_text(json.dumps(reference,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        else:
            assert json.loads(REFERENCE.read_text(encoding="utf-8"))==reference, 'Pinned preference reference differs; review source/corpus changes before updating'
    report['comparison']='pinned-swift' if args.rust_only else 'live-swift-and-native-foundation'
    report['nativeFoundationBridgeRun']=not args.rust_only
    report['scope']='Original Swift initializers and SwiftUI AppStorage getters, read-only native Foundation bridge, portable restoration, font buttons, response-speed floors and caption decoding/clamps. Volatile synthetic domains only. No original preferences changed; real-user migration and native UI NOT_RUN.'
    (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
