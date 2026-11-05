import Foundation

private struct InputWord: Decodable {
    let id: UUID; let t0: Double; let t1: Double; let text: String; let conf: Double
    var word: Word { Word(id: id, t0: t0, t1: t1, text: text, conf: conf) }
}
private struct Step: Decodable {
    let op: String; let word: InputWord?; let rows: [[InputWord]]?
    let index: Int?; let text: String?; let right: String?; let flag: Bool?
}
private struct Case: Decodable { let steps: [Step] }
@main enum TextPassesOracle {
    static func lines(_ values: [Line]) -> [[String: Any]] {
        values.map { line in [
            "id": line.id.uuidString.lowercased(), "text": line.text,
            "edited": line.editedText as Any? ?? NSNull(),
            "words": line.words.map { word in ["id": word.id.uuidString.lowercased(), "text": word.text,
                "t0": word.t0, "t1": word.t1, "conf": word.conf] as [String: Any] }
        ] }
    }
    @MainActor static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        LiveFeatureWiring.joinSameSpeakerNeighbors = true
        LiveFeatureWiring.settledLedger = true
        LiveFeatureWiring.turnHeadAdoption = true
        LiveFeatureWiring.speakerIslandAbsorption = false
        LiveFeatureWiring.weakLabelContinuation = 0
        SpeakerDisplayNumber.minSecondsToNumber = 10
        var results: [[[[String: Any]]]] = []
        for c in cases {
            let harness = TextPassHarness()
            var states: [[[String: Any]]] = []
            for step in c.steps {
                let store = harness.transcript
                let index = step.index ?? 0
                let id = store.lines.indices.contains(index) ? store.lines[index].id : UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
                switch step.op {
                case "rows": store.load(step.rows!.map { row in
                    Line(id: row[0].id, speaker: 1, start: row[0].t0, end: row.last!.t1, words: row.map(\.word))
                })
                case "word": store.oracleIngestWord(step.word!.word); harness.tick(false)
                case "break": harness.livePartial = ""; store.ingest(.wordSectionBegin); harness.tick(false)
                case "targets": harness.translateTargets = step.flag! ? ["en"] : []
                case "partial": harness.livePartial = step.text!
                case "enabled": harness.glossary.enabled = step.flag!
                case "learn": harness.glossary.learn(wrong: step.text!, right: step.right!)
                case "stable": harness.tick(step.flag ?? false)
                case "all": harness.sweep()
                case "finish": store.finalize(); harness.sweep()
                case "edit": harness.userEditedLines.insert(id); _ = store.editLine(id, step.text!)
                case "editWord": _ = store.editWord(id, index: 0, to: step.text!)
                case "reset": store.reset(); harness.userEditedLines.removeAll(); harness.stablePassHash.removeAll()
                default: preconditionFailure("unknown text-pass operation")
                }
                states.append(lines(store.lines))
            }
            results.append(states)
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
    }
}
