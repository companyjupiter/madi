import Foundation
struct InputSpec: Decodable {
    let maxCharsPerLine: Int?; let maxLines: Int?; let maxCPS: Double?; let minDur: Double?; let maxDur: Double?; let gapBreak: Double?; let speakerLabels: Bool?
    var spec: Exporters.CaptionSpec {
        var s=Exporters.CaptionSpec()
        if let v=maxCharsPerLine{s.maxCharsPerLine=v};if let v=maxLines{s.maxLines=v};if let v=maxCPS{s.maxCPS=v}
        if let v=minDur{s.minDur=v};if let v=maxDur{s.maxDur=v};if let v=gapBreak{s.gapBreak=v};s.speakerLabels=speakerLabels
        return s
    }
}
struct ExportCase: Decodable {let lines:[InputLine];let names:[Int:String];let spec:InputSpec?;let settings:EditorSettings?}
@main enum ExportOracle {
    static func hex(_ text:String)->String {text.utf8.map{String(format:"%02x",$0)}.joined()}
    static func main() throws {
        let cases=try JSONDecoder().decode([ExportCase].self,from:FileHandle.standardInput.readDataToEndOfFile())
        let output:[[String:Any]]=try cases.map { c in
            let lines=c.lines.map(\.line),spec=c.spec?.spec ?? .init(),settings=c.settings ?? .init()
            let cues=Exporters.captionCues(lines,names:c.names,spec:spec).map { cue -> [String:Any] in
                ["start":String(format:"%016llx",cue.start.bitPattern),"end":String(format:"%016llx",cue.end.bitPattern),"lines":cue.lines.map(hex)]
            }
            return ["srt":hex(Exporters.srt(lines,names:c.names,spec:spec)),"vtt":hex(Exporters.vtt(lines,names:c.names,spec:spec)),"cues":cues,
                    "json":try JSONSerialization.jsonObject(with:Data(Exporters.json(lines,names:c.names,settings:settings).utf8)),
                    "jsonUtf8":hex(Exporters.json(lines,names:c.names,settings:settings)),
                    "settings":try JSONSerialization.jsonObject(with:JSONEncoder().encode(settings))]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]))
    }
}
