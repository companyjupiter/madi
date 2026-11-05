import Foundation

@main
struct TranscribeOracle {
    static func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }
    static func num(_ value: Double) -> String { String(format: "%016llx", value.bitPattern) }
    static func label(_ kind: String, _ label: SpeakerLabel) -> String {
        "\(kind):\(num(label.time)):\(label.id):\(num(label.dur)):\(num(label.margin))"
    }
    static func render(_ event: EngineEvent) -> String {
        switch event {
        case .ready: return "ready"
        case .wordSectionBegin: return "words"
        case .word(let t0, let t1, let text, let conf): return "word:\(num(t0)):\(num(t1)):\(num(conf)):\(hex(text))"
        case .speaker(let value): return label("speaker", value)
        case .speakerFix(let value): return label("fix", value)
        case .speakerOverlap(let value): return label("overlap", value)
        case .speakerOverlapReset: return "overlap-reset"
        case .speakerName(let id, let name): return "name:\(id):\(hex(name))"
        case .flushEnd: return "flush"
        case .progressTotal(let n): return "total:\(n)"
        case .progressChunk(let n): return "chunk:\(n)"
        case .languageDetected(let n): return "language:\(n)"
        case .partial(let t0, let text): return "partial:\(num(t0)):\(hex(text))"
        case .segmentEnd: return "segment"
        case .previewBegin: return "preview-begin"
        case .previewEnd: return "preview-end"
        case .previewPartial(let text): return "preview-partial:\(hex(text))"
        case .previewWord(let t0, let t1, let text): return "preview-word:\(num(t0)):\(num(t1)):\(hex(text))"
        case .other(let text): return "other:\(hex(text))"
        }
    }
    static func main() {
        if CommandLine.arguments.contains("--float-profile") {
            let upper = Double("0X1p2") != nil
            let symbolic = Double("nan(foo)") != nil
            print(upper && symbolic ? "legacy" : (!upper && !symbolic ? "current" : "unknown"))
            return
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        var cursor = 0
        func word() -> Int {
            defer { cursor += 4 }
            return data[cursor..<cursor+4].enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        }
        var output = ""
        for caseID in 0..<word() {
            let decoder = EngineProtocol.Decoder()
            for line in 0..<word() {
                let length = word()
                let text = String(decoding: data[cursor..<cursor+length], as: UTF8.self)
                cursor += length
                output += "\(caseID):\(line):\(render(decoder.decode(line: text)))\n"
            }
        }
        FileHandle.standardOutput.write(Data(output.utf8))
    }
}
