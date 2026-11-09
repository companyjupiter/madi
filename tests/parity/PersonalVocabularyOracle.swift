import Foundation
struct Pair: Decodable { let before: String; let after: String }
struct InputWord: Decodable {
    let id: UUID; let t0: Double; let t1: Double; let text: String; let conf: Double
    var word: Word { Word(id: id, t0: t0, t1: t1, text: text, conf: conf) }
}
struct Case: Decodable {
    let glossary: Glossary; let queries: [String]; let pairs: [Pair]
    let words: [InputWord]; let editedText: String?
}
@main enum PersonalVocabularyOracle {
    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let results: [[String: Any]] = cases.map { c in
            let line = Line(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, speaker: 7, start: 0, end: 100,
                            words: c.words.map(\.word), editedText: c.editedText)
            let rules = c.glossary.activeEntries
            return [
                "normalize": c.queries.map(PersonalVocabulary.normalize),
                "surface": c.queries.map(PersonalVocabulary.surfaceForm),
                "keys": c.queries.map(PersonalVocabulary.normalizeKeys),
                "script": c.queries.map(PersonalVocabulary.isBiasScript),
                "match": c.queries.map { PersonalVocabulary.match($0, rules: rules, glossary: c.glossary) as Any? ?? NSNull() },
                "diff": c.pairs.map { PersonalVocabulary.diff(before: $0.before, after: $0.after).map { ["wrong": $0.wrong, "right": $0.right] } },
                "scores": c.pairs.map { String(format: "%016llx", PersonalVocabulary.jaroWinkler($0.before, $0.after).bitPattern) },
                "bias": PersonalVocabulary.biasTerms(c.glossary),
                "incoming": c.words.map { PersonalVocabulary.correctIncomingText($0.text, conf: $0.conf, c.glossary) },
                "line": PersonalVocabulary.correctedLineText(line, c.glossary) as Any? ?? NSNull(),
            ]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
    }
}
