import Foundation

// Only disabled diagnostics/telemetry are stubbed. Production model bodies
// are compiled unchanged; deterministic word IDs and timer delivery use the
// extension appended beside the original file by the comparison driver.
final class DebugLog {
    static var shared: DebugLog? { nil }
    func emit(_ category: String, _ name: String, _ data: [String: Any]) {}
}
@MainActor final class TranslationStabilityMetrics {
    static let shared = TranslationStabilityMetrics()
    enum ShowCause { case stream, revision }
    enum Surface { case panel }
    var cosmeticRebinds = 0
    func recordShown(_ surface: Surface, key: String, text: String?, cause: ShowCause = .stream) {}
}
struct InputWord: Decodable {
    let id: UUID; let t0: Double; let t1: Double; let text: String; let conf: Double
    var word: Word { Word(id: id, t0: t0, t1: t1, text: text, conf: conf) }
}
struct InputLabel: Decodable {
    let time: Double; let id: Int; let duration: Double; let margin: Double
    var label: SpeakerLabel { SpeakerLabel(time: time, id: id, dur: duration, margin: margin) }
}
struct Step: Decodable {
    let op: String; let word: InputWord?; let label: InputLabel?; let inspect: Bool?
    let index: Int?; let wordIndex: Int?; let text: String?; let lang: String?
    let revision: String?; let saved: Bool?; let userEdited: Bool?
    let from: Int?; let into: Int?; let targets: [String]?
}
struct Features: Decodable {
    let join: Bool; let ledger: Bool; let turnHead: Bool; let island: Bool
    let weak: Double; let minSeconds: Double
}
struct Case: Decodable { let features: Features; let steps: [Step] }
@main enum TranscriptStoreOracle {
    static func hex(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }
    static func bits(_ d: Double) -> String { String(format: "%016llx", d.bitPattern) }
    static func words(_ words: [Word]) -> [String] {
        words.map { "\($0.id.uuidString.lowercased()):\(bits($0.t0)):\(bits($0.t1)):\(bits($0.conf)):\(hex($0.text))" }
    }
    static func status(_ s: SegmentStatus) -> String {
        switch s { case .transcribing: return "transcribing"; case .translating: return "translating"; case .completed: return "completed" }
    }
    static func lines(_ lines: [Line]) -> [[String: Any]] {
        lines.map { l in [
            "id": l.id.uuidString.lowercased(), "speaker": l.speaker,
            "start": bits(l.start), "end": bits(l.end), "margin": bits(l.speakerMargin),
            "words": words(l.words), "text": hex(l.text), "joined": hex(l.joinedText),
            "editedText": l.editedText.map(hex) as Any? ?? NSNull(), "edited": l.isEdited,
            "overlaps": l.overlapSpeakers, "translations": l.translations.mapValues(hex),
            "stale": l.staleTranslations.mapValues(hex), "editedTranslations": l.editedTranslations.sorted(),
            "suppressed": l.suppressedTranslations.sorted(), "revision": String(TextRevision.of(l.text)),
            "statuses": [status(l.status(activeLangs: ["en", "ja"], isLiveTail: true, translateBusy: true)),
                         status(l.status(activeLangs: ["en", "ja"], isLiveTail: false, translateBusy: true)),
                         status(l.status(activeLangs: [], isLiveTail: false, translateBusy: true)),
                         status(l.status(activeLangs: ["en"], isLiveTail: false, translateBusy: false))]
        ] }
    }
    @MainActor static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        var results: [[[String: Any]]] = []
        for c in cases {
            LiveFeatureWiring.joinSameSpeakerNeighbors = c.features.join
            LiveFeatureWiring.settledLedger = c.features.ledger
            LiveFeatureWiring.turnHeadAdoption = c.features.turnHead
            LiveFeatureWiring.speakerIslandAbsorption = c.features.island
            LiveFeatureWiring.weakLabelContinuation = c.features.weak
            SpeakerDisplayNumber.minSecondsToNumber = c.features.minSeconds
            let store = TranscriptStore()
            var states: [[String: Any]] = []
            var savedID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
            var savedRevision: UInt64 = 0
            var archive: [Line] = []
            for step in c.steps {
                let index = step.index ?? 0
                let id = step.saved == true ? savedID : (store.lines.indices.contains(index) ? store.lines[index].id : UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!)
                let revision: UInt64? = step.revision == "current" ? store.sourceRevision(for: id) : step.revision == "saved" ? savedRevision : step.revision == "bad" ? 0 : nil
                var result: Any = NSNull()
                switch step.op {
                case "word": store.oracleIngestWord(step.word!.word)
                case "break": store.ingest(.wordSectionBegin)
                case "speaker": store.ingest(.speaker(step.label!.label))
                case "fix": store.ingest(.speakerFix(step.label!.label))
                case "overlap": store.ingest(.speakerOverlap(step.label!.label))
                case "overlapReset": store.ingest(.speakerOverlapReset)
                case "flushFix": store.flushPendingSpeakerFixRebuild()
                case "render": store.oracleDeliverRender()
                case "finish": store.finalize()
                case "reset": store.reset()
                case "broken": store.markDiarNamespaceBroken()
                case "remember": savedID = id; savedRevision = store.sourceRevision(for: id) ?? 0
                case "archive": archive = store.lines
                case "load": store.load(archive)
                case "translate": result = store.setTranslation(id, lang: step.lang!, step.text!, sourceRevision: revision, userEdited: step.userEdited ?? false)
                case "suppress": result = store.suppressTranslation(id, lang: step.lang!, sourceRevision: revision)
                case "prune": result = store.pruneTranslations(id, validTargets: Set(step.targets!), sourceRevision: revision ?? 0).sorted()
                case "edit": result = store.editLine(id, step.text!, expectedRevision: revision)
                case "editWord": result = store.editWord(id, index: step.wordIndex!, to: step.text!)
                case "merge": store.mergeSpeaker(from: step.from!, into: step.into!)
                case "relabel": store.relabelSpeaker(lineID: id, to: step.into!)
                case "revert": store.revertSpeakerCorrections()
                case "join": store.joinSameSpeakerNeighbors()
                case "snapshot": break
                default: preconditionFailure("unknown transcript store operation")
                }
                if step.inspect ?? true {
                    states.append([
                        "lines": lines(store.lines), "display": lines(store.displayLines),
                        "lastDisplayID": store.displayLastLineID?.uuidString.lowercased() as Any? ?? NSNull(),
                        "displayRevision": String(store.oracleDisplayRevision), "renderPending": store.oracleRenderPending,
                        "fixPending": store.oracleFixPending, "numbers": store.speakerNumbers.numbers.reduce(into: [String: Int]()) { $0[String($1.key)] = $1.value },
                        "held": words(store.heldWord.map { [$0] } ?? []), "end": bits(store.committedEnd),
                        "committedSince": words(store.committedWords(since: 0.7)), "displayedSince": words(store.displayedWords(since: 0.7)),
                        "corrections": store.hasSpeakerCorrections, "joins": store.sameSpeakerJoins,
                        "fixRebuilds": store.speakerFixRebuilds, "islands": store.islandAbsorptions,
                        "weak": store.weakLabelContinuations, "result": result
                    ])
                }
            }
            results.append(states)
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
    }
}
