import Foundation

// Only disabled logging is stubbed. Word and WordMerger are original source.
final class DebugLog {
    static var shared: DebugLog? { nil }
    func emit(_ category: String, _ name: String, _ data: [String: Any]) {}
}
struct InputWord: Decodable {
    let id: UUID; let t0: Double; let t1: Double; let text: String; let conf: Double
    var word: Word { Word(id: id, t0: t0, t1: t1, text: text, conf: conf) }
}
struct Step: Decodable { let op: String; let word: InputWord?; let inspect: Bool? }
struct Case: Decodable { let steps: [Step] }
@main enum WordMergerOracle {
    static func words(_ words: [Word]) -> [String] {
        words.map { word in
            let hex = word.text.utf8.map { String(format: "%02x", $0) }.joined()
            return "\(word.id.uuidString.lowercased()):\(String(format: "%016llx", word.t0.bitPattern)):\(String(format: "%016llx", word.t1.bitPattern)):\(String(format: "%016llx", word.conf.bitPattern)):\(hex)"
        }
    }
    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let results: [[[String: Any]]] = cases.map { c in
            var merger = WordMerger()
            var states: [[String: Any]] = []
            for step in c.steps {
                switch step.op {
                case "word": merger.add(step.word!.word)
                case "break": merger.segmentBreak()
                case "finish": merger.finish()
                case "snapshot": break
                default: preconditionFailure("unknown word merger operation")
                }
                if step.inspect ?? true {
                    states.append([
                        "committed": words(merger.committed), "display": words(merger.displayWords),
                        "tail": words(merger.displayWords(from: 1)), "beyond": words(merger.displayWords(from: Int.max)),
                        "since": words(merger.committed(since: 0.7)), "displayedSince": words(merger.displayed(since: 0.7)),
                        "held": merger.heldWordID?.uuidString.lowercased() as Any? ?? NSNull(),
                        "heldText": merger.heldWordText as Any? ?? NSNull(),
                        "end": String(format: "%016llx", merger.committedEnd.bitPattern),
                        "seamDropped": merger.seamDuplicatesDropped, "instantDropped": merger.sameInstantDuplicatesDropped,
                    ])
                }
            }
            return states
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
    }
}
