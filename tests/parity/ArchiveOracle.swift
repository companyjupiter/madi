import Foundation

struct InputWord: Decodable {
    let id: UUID; let t0: Double; let t1: Double; let text: String; let conf: Double
    var word: Word { Word(id: id, t0: t0, t1: t1, text: text, conf: conf) }
}
struct InputLine: Decodable {
    let id: UUID; let speaker: Int; let start: Double; let end: Double
    let words: [InputWord]; let overlapSpeakers: [Int]; let speakerMargin: Double
    let translations: [String: String]; let staleTranslations: [String: String]
    let editedTranslations: Set<String>; let suppressedTranslations: Set<String>; let editedText: String?
    var line: Line {
        Line(id: id, speaker: speaker, start: start, end: end, words: words.map(\.word),
             overlapSpeakers: overlapSpeakers, speakerMargin: speakerMargin, translations: translations,
             staleTranslations: staleTranslations, editedTranslations: editedTranslations,
             suppressedTranslations: suppressedTranslations, editedText: editedText)
    }
}
struct Case: Decodable {
    let lines: [InputLine]; let names: [Int: String]; let summary: String?; let archive: String?
}
@main enum ArchiveOracle {
    static func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }
    static func bits(_ value: Double) -> String { String(format: "%016llx", value.bitPattern) }
    static func pairs(_ values: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { (hex($0.key), hex($0.value)) })
    }
    static func parsed(_ text: String) -> Any {
        guard let parsed = TranscriptArchive.parse(text: text) else { return NSNull() }
        var ids = Set<UUID>()
        let unique = parsed.lines.allSatisfy { line in
            line.words.isEmpty ? ids.insert(line.id).inserted : line.words.allSatisfy { ids.insert($0.id).inserted }
        }
        let lines: [[String: Any]] = parsed.lines.map { line in
            ["speaker": line.speaker, "start": bits(line.start), "end": bits(line.end),
             "text": hex(line.text), "overlap": line.overlapSpeakers, "margin": bits(line.speakerMargin),
             "translations": pairs(line.translations), "stale": pairs(line.staleTranslations),
             "edited": line.editedTranslations.map(hex).sorted(), "suppressed": line.suppressedTranslations.map(hex).sorted(),
             "editedText": line.editedText.map(hex) as Any? ?? NSNull(),
             "firstWordIdentity": line.words.first.map { $0.id == line.id } ?? true,
             "words": line.words.map { "\(bits($0.t0)):\(bits($0.t1)):\(bits($0.conf)):\(hex($0.text))" }]
        }
        return ["lines": lines, "names": Dictionary(uniqueKeysWithValues: parsed.names.map { (String($0.key), hex($0.value)) }), "uniqueIdentities": unique] as [String: Any]
    }
    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let results: [[String: Any]] = cases.map { c in
            let lines = c.lines.map(\.line)
            let markdown = Exporters.markdown(lines, names: c.names, summary: c.summary)
            return ["markdown": hex(markdown), "plain": hex(Exporters.plainText(lines, names: c.names)),
                    "reopened": parsed(markdown), "archive": c.archive.map(parsed) ?? NSNull()]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
    }
}
