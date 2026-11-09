#!/usr/bin/env python3
"""Compare caption projection with unchanged computed bodies of CaptionView."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out/caption-parity'
REFERENCE = ROOT / 'design/parity/caption-reference.json'
SOURCES = [ROOT / 'apps/macos/Sovereign' / name for name in (
    'UI/CaptionOverlay.swift', 'UI/ClinicDisplaySupport.swift',
    'SessionController.swift', 'Transcript/SpeakerID.swift')]

def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')

def cases():
    rng = random.Random(2026110511)
    rows = []
    targets = [[], ['Korean'], ['English', 'Korean'], ['Korean', 'Japanese'],
               ['Japanese', 'Chinese', 'English', 'Korean']]
    texts = ['', 'source', '새로 인식한 문장', 'before\nnext', 'cafe\u0301', '  ']
    for i in range(1500):
        settings = dict(staffFontSize=26, patientFontSize=46, panelWidth=760,
                        minScaleFactor=0.9, patientPanelEnabled=False,
                        patientScreenIndex=None, patientLangOverride=rng.choice([None, '', 'Japanese', 'English', 'French']))
        row = dict(audience=['staff', 'patient'][i % 2], targets=targets[i % len(targets)],
                   settings=settings, uiLanguage=['ko', 'en', 'ja'][i % 3],
                   partial=rng.choice(texts), source=rng.choice(texts), names=rng.choice([{}, {'7': ''}, {'7': '이름'}, {'3': '다른 화자'}]),
                   numbers=rng.choice([{}, {'7': 2}]), level=rng.choice([0, .19999999, .2, .20000001, .6, 1]),
                   lines=[])
        ordered = sorted(row['targets'])
        lang = (settings['patientLangOverride'] if settings['patientLangOverride'] is not None else next((t for t in ordered if t != 'Korean'), ordered[0] if ordered else None)) if row['audience'] == 'patient' else (ordered[0] if ordered else None)
        # Swift Dictionary.values.first has no stable winner. Cover zero/single
        # fallback values and multi-language dictionaries with a selected key;
        # do not pretend an arbitrary fallback winner is a parity contract.
        values = [{}, {'Korean': '번역'}, {'English': ''}]
        if lang is not None:
            values += [{lang: '선택 번역', 'other': '다른 번역'}, {lang: '', 'other': '다른 번역'}]
        row['interim'] = rng.choice(values)
        for j in range(rng.randrange(5)):
            row['lines'].append(dict(text=f'committed {j}', end=j * rng.choice([10, 299, 300, 301]),
                                     speaker=rng.choice([7, 255, -1]), margin=rng.choice([.34, .35, 1]),
                                     translations=rng.choice(values)))
        rows.append(row)
    return rows

SWIFT = r'''
enum CaptionAudience { case staff, patient }
struct InputLine: Decodable { let text: String; let end: Double; let speaker: Int; let margin: Double; let translations: [String:String]; var speakerMargin: Double { margin } }
struct Transcript { let displayLines: [InputLine] }
struct Case: Decodable {
    let audience: String; let targets: [String]; let settings: CaptionSettings; let uiLanguage: String
    let partial: String; let interim: [String:String]; let source: String
    let names: [Int:String]; let numbers: [Int:Int]; let level: Float; let lines: [InputLine]
}
struct Session {
    let c: Case
    var captionSettings: CaptionSettings { c.settings }
    var translateTargets: Set<String> { Set(c.targets) }
    var livePartial: String { c.partial }
    var livePartialTranslations: [String:String] { c.interim }
    var livePartialSource: String { c.source }
    var transcript: Transcript { Transcript(displayLines: c.lines) }
    __PATIENT__
}
struct ViewProjection {
    let session: Session; let audience: CaptionAudience
    private var settings: CaptionSettings { session.captionSettings }
    __COMPUTED__
    func result() -> [String:Any] {
        let c = session.c
        let v = caption
        var label: String? = nil
        if let v, let id = v.speaker, !c.names.isEmpty {
            let diarizing = c.uiLanguage == "ko" ? "화자분리중…" : c.uiLanguage == "ja" ? "話者分離中…" : "Separating speakers…"
            label = SpeakerID.display(id, names:c.names, number:c.numbers[id] ?? id, margin:v.margin, age:v.age,
                diarizing:diarizing, fallback:{ "\(c.uiLanguage == "ko" ? "화자" : c.uiLanguage == "ja" ? "話者" : "Speaker") \($0)" })
        }
        let value: Any = v.map { ["translation":$0.trans, "original":$0.orig, "provisional":$0.live,
            "speaker":$0.speaker as Any? ?? NSNull(), "margin":$0.margin, "age":$0.age] as [String:Any] } as Any? ?? NSNull()
        return ["language": lang as Any? ?? NSNull(), "caption":value,
            "status": statusKind == .live ? "live" : statusKind == .translating ? "translating" : "waiting",
            "statusText":statusKind.text(for:lang), "waitingText":CaptionStatus.waiting.text(for:lang),
            "header":(c.uiLanguage == "ko" ? "실시간 자막" : "Live captions") + (lang.map { " · \($0)" } ?? ""),
            "speakerLabel":label as Any? ?? NSNull(),
            "preview":v == nil && !c.partial.isEmpty ? c.partial as Any : NSNull(),
            "meter":(0..<5).map { Double(c.level) * 5 > Double($0) }]
    }
}
@main struct Main {
    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from:FileHandle.standardInput.readDataToEndOfFile())
        let results = cases.map { ViewProjection(session:Session(c:$0), audience:$0.audience == "staff" ? .staff : .patient).result() }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:results, options:[.sortedKeys]))
    }
}
'''

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rust-only', action='store_true')
    p.add_argument('--write-reference', action='store_true')
    a = p.parse_args()
    if a.rust_only and a.write_reference:
        p.error('Native Swift required to pin references')
    if not a.rust_only and platform.system() != 'Darwin':
        p.error('Native Swift requires macOS')
    OUT.mkdir(parents=True, exist_ok=True)
    payload = encoded(cases()); (OUT/'cases.json').write_bytes(payload)
    subprocess.run([os.environ.get('CARGO', 'cargo'), 'build', '--locked', '-p', 'madi-core', '--example', 'caption_oracle'], cwd=ROOT, check=True)
    binary = ROOT/'target/debug/examples'/('caption_oracle.exe' if os.name == 'nt' else 'caption_oracle')
    actual = json.loads(subprocess.check_output([str(binary)], input=payload))
    (OUT/'result.json').write_bytes(encoded(actual))
    if not a.rust_only:
        view = SOURCES[0].read_text(encoding='utf-8')
        computed = view[view.index('    private var lang:'):view.index('    var body: some View {')]
        session = SOURCES[2].read_text(encoding='utf-8')
        start = session.index('    var patientCaptionLang:')
        patient = session[start:session.index('\n    }', start)+6]
        driver = OUT/'CaptionOracle.swift'
        driver.write_text('import Foundation\n'+SWIFT.replace('__COMPUTED__', computed).replace('__PATIENT__', patient), encoding='utf-8')
        oracle = OUT/'swift-oracle'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(driver), str(SOURCES[1]), str(SOURCES[3]), '-o', str(oracle)], check=True)
        expected = json.loads(subprocess.check_output([str(oracle)], input=payload))
        (OUT/'swift.json').write_bytes(encoded(expected))
        assert len(expected) == len(actual)
        for i, (want, got) in enumerate(zip(expected, actual, strict=True)):
            assert want == got, (i, want, got)
    report = dict(cases=len(actual), corpusSHA256=hashlib.sha256(payload).hexdigest(),
                  resultSHA256=hashlib.sha256(encoded(actual)).hexdigest(),
                  sources={s.relative_to(ROOT).as_posix():hashlib.sha256(s.read_bytes()).hexdigest() for s in SOURCES})
    if a.write_reference:
        REFERENCE.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    else:
        assert report == json.loads(REFERENCE.read_text(encoding='utf-8')), 'Caption reference changed'
    report.update(status='passed', nativeSwiftRun=not a.rust_only,
                  scope='Original CaptionView lang/pick/caption/statusKind bodies and patientCaptionLang; original CaptionStatus/SpeakerID helpers. Ambiguous multi-value fallback and native window/UI geometry are not acceptance claims.')
    (OUT/'report.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
