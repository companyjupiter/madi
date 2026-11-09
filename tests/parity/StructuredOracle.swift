import Foundation

@main enum StructuredOracle {
    static func main() {
        if CommandLine.arguments.contains("--json-profile") {
            let data = Data(#"{"t":"first","t":"last"}"#.utf8)
            let value = try! JSONSerialization.jsonObject(with: data) as! [String: String]
            print(value["t"]!)
            return
        }
        let input = [UInt8](FileHandle.standardInput.readDataToEndOfFile())
        var offset = 0
        func word() -> Int {
            defer { offset += 4 }
            return (0..<4).reduce(0) { $0 | (Int(input[offset + $1]) << ($1 * 8)) }
        }
        func h(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }
        func n(_ d: Double) -> String { String(format: "%016llx", d.bitPattern) }
        func render(_ event: StructuredEvent?) -> String {
            guard let event else { return "nil" }
            switch event {
            case .meta(let model, let lang, let sr, let v): return "meta:\(h(model)):\(lang):\(sr):\(v)"
            case .ready: return "ready"
            case .partial(let t0, let text): return "partial:\(n(t0)):\(h(text))"
            case .word(let t0, let t1, let conf, let spk, let text): return "word:\(n(t0)):\(n(t1)):\(n(conf)):\(spk):\(h(text))"
            case .speakerSegment(let t0, let spk, let text): return "speaker:\(n(t0)):\(spk):\(h(text))"
            case .segment(let s): return ["seg", String(s.idx), n(s.t0), n(s.t1), n(s.avgLogprob), h(s.fallback), n(s.tokS), n(s.encMs), n(s.decMs), String(s.passes), s.dropped ? "true" : "false", h(s.text), s.biasHits.map(h).joined(separator: ",")].joined(separator: ":")
            case .diarization(let d): return "diar:\(d.speakers):\(n(d.silhouette)):\(n(d.sep)):\(n(d.tau)):\(d.segments)"
            case .segEnd: return "segment"
            case .flushEnd: return "flush"
            case .unknown(let t): return "unknown:\(h(t))"
            }
        }
        for index in 0..<word() {
            let count = word()
            let raw = String(bytes: input[offset..<offset+count], encoding: .utf8)!
            offset += count
            print("\(index):\(render(EngineEvents.decode(line: raw)))")
        }
    }
}
