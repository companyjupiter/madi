// P4 — a line whose text moves on no longer deletes its displayed translation:
// the old rendering is kept as stale display text and replaced in place.
import XCTest
@testable import SovereignCore

@MainActor
final class TranslationStaleKeepTests: XCTestCase {

    func testGrowthKeepsOldRenderingAsStale() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello", sourceRevision: rev))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "반갑습니다", conf: 1))   // line grows → new revision
        let line = s.lines.first!
        XCTAssertNil(line.translations["English"], "outdated result must leave the valid slot")
        XCTAssertEqual(line.staleTranslations["English"], "Hello",
                       "…but stay visible as a stale rendering instead of vanishing")
    }

    func testReplacementClearsStaleInPlace() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello", sourceRevision: rev))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "반갑습니다", conf: 1))
        guard let rev2 = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello, nice to meet you",
                                       sourceRevision: rev2))
        let line = s.lines.first!
        XCTAssertEqual(line.translations["English"], "Hello, nice to meet you")
        XCTAssertNil(line.staleTranslations["English"], "replaced in place — no stale leftover")
    }

    func testEditLineKeepsStaleRendering() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "소버림", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Soverim", sourceRevision: rev))
        XCTAssertTrue(s.editLine(id, "소버린", expectedRevision: rev))
        let line = s.lines.first!
        XCTAssertNil(line.translations["English"])
        XCTAssertEqual(line.staleTranslations["English"], "Soverim",
                       "user's source edit grays the old translation, doesn't erase it")
    }

    func testPruneKeepsOldRevisionButDropsUnroutedLanguage() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello", sourceRevision: rev))
        XCTAssertTrue(s.setTranslation(id, lang: "Korean", "안녕", sourceRevision: rev))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "반갑습니다", conf: 1))
        guard let rev2 = s.sourceRevision(for: id) else { return XCTFail() }
        // Routing now excludes Korean; English is merely from an older revision.
        let valid = s.pruneTranslations(id, validTargets: ["English"], sourceRevision: rev2)
        XCTAssertTrue(valid.isEmpty, "old-revision result must not count as existing")
        let line = s.lines.first!
        XCTAssertEqual(line.staleTranslations["English"], "Hello", "kept for display")
        XCTAssertNil(line.staleTranslations["Korean"], "unrouted language is gone for good")
        XCTAssertNil(line.translations["Korean"])
    }

    func testStatusStillReportsTranslatingWhileStale() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요.", conf: 1))
        s.ingest(.word(t0: 2.5, t1: 2.8, text: "다음", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello.", sourceRevision: rev))
        s.editLine(id, "안녕하세요. 여러분")
        let line = s.lines.first!
        // The slot needs a re-translation, so the STATE is still 'translating' —
        // the view suppresses the dots because the stale text is the status.
        XCTAssertEqual(line.status(activeLangs: ["English"], isLiveTail: false, translateBusy: true),
                       .translating)
        XCTAssertFalse(line.staleTranslations.isEmpty)
    }
}

/// P10-3 — split-once. A re-decode that moves punctuation must not un-split and
/// re-split live lines under the reader (each oscillation reset a translation).
@MainActor
final class SplitOnceGroupingTests: XCTestCase {

    func testPunctuationBreakSurvivesItsOwnDisappearance() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요.", conf: 1))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "오늘은", conf: 1))
        XCTAssertEqual(s.lines.count, 2, "the sentence ender starts a new line")
        // The next segment re-decodes and the period is gone — the break must hold.
        s.ingest(.wordSectionBegin)
        s.ingest(.word(t0: 1.0, t1: 1.3, text: "클라우드", conf: 1))
        XCTAssertEqual(s.lines.count, 2, "structure must not un-split under the reader")
        XCTAssertEqual(s.lines.first?.text, "안녕하세요.")
    }

    func testLineStructureOnlyGrows() {
        let s = TranscriptStore()
        var counts: [Int] = []
        for (i, t) in ["첫째.", "둘째", "셋째.", "넷째", "다섯째"].enumerated() {
            s.ingest(.word(t0: Double(i) * 0.4, t1: Double(i) * 0.4 + 0.3, text: t, conf: 1))
            counts.append(s.lines.count)
        }
        for i in 1..<counts.count {
            XCTAssertGreaterThanOrEqual(counts[i], counts[i - 1],
                                        "live line count must be monotonic: \(counts)")
        }
    }

    func testTranslationOfASplitHeadSurvivesLaterWords() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요.", conf: 1))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "오늘은", conf: 1))
        guard let head = s.lines.first?.id, let rev = s.sourceRevision(for: head) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(head, lang: "English", "Hello.", sourceRevision: rev))
        // Words keep arriving on the FOLLOWING line — the frozen head keeps its
        // translation instead of being regrouped and invalidated.
        s.ingest(.word(t0: 0.8, t1: 1.1, text: "클라우드", conf: 1))
        s.ingest(.word(t0: 1.2, t1: 1.5, text: "네이티브", conf: 1))
        XCTAssertEqual(s.lines.first?.translations["English"], "Hello.")
        XCTAssertTrue(s.lines.first?.staleTranslations.isEmpty ?? false)
    }

    func testResetClearsRecordedBreaks() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요.", conf: 1))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "오늘은", conf: 1))
        s.reset()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "오늘은", conf: 1))
        XCTAssertEqual(s.lines.count, 1, "a new session must not inherit old breaks")
    }
}

/// P10-4 — one recluster burst must land as ONE visual recompute.
@MainActor
final class SpeakerFixCoalescingTests: XCTestCase {

    func testBurstOfFixesCoalescesIntoOneRebuild() async throws {
        let s = TranscriptStore()
        // Two speakers' worth of words with live labels at their onsets.
        s.ingest(.speaker(SpeakerLabel(time: 0.0, id: 1, dur: 2.0, margin: 0.9)))
        s.ingest(.speaker(SpeakerLabel(time: 2.0, id: 1, dur: 2.0, margin: 0.9)))
        s.ingest(.word(t0: 0.0, t1: 0.5, text: "첫", conf: 1))
        s.ingest(.word(t0: 2.1, t1: 2.5, text: "둘", conf: 1))
        // A recluster batch: both windows relabel in one burst.
        s.ingest(.speakerFix(SpeakerLabel(time: 0.0, id: 2, dur: 2.0, margin: 0.8)))
        s.ingest(.speakerFix(SpeakerLabel(time: 2.0, id: 2, dur: 2.0, margin: 0.8)))
        XCTAssertEqual(s.speakerFixRebuilds, 0, "recompute is deferred past the burst")
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(s.speakerFixRebuilds, 1, "one burst → one visual update")
        XCTAssertTrue(s.lines.allSatisfy { $0.speaker == 2 },
                      "…and the corrections all landed")
    }

    func testLabelDataUpdatesSynchronouslyEvenBeforeTheRebuild() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0.0, id: 1, dur: 1.0, margin: 0.9)))
        s.ingest(.word(t0: 0.0, t1: 0.5, text: "가", conf: 1))
        s.ingest(.speakerFix(SpeakerLabel(time: 0.0, id: 3, dur: 1.0, margin: 0.8)))
        // A word arriving right after the fix (before the coalesced rebuild)
        // must already see the corrected label — data is never deferred.
        s.ingest(.word(t0: 0.6, t1: 0.9, text: "나", conf: 1))
        XCTAssertEqual(s.lines.first?.speaker, 3)
    }
}

/// P14 — cosmetic edits (punctuation/whitespace/case) re-bind translations to
/// the new revision instead of invalidating them: no stale demotion, no
/// re-translation turn, no panel replacement.
@MainActor
final class CosmeticRebindTests: XCTestCase {

    override func setUp() async throws { TranslationStabilityMetrics.shared.reset() }

    func testCosmeticEqualityRules() {
        XCTAssertTrue(TranscriptStore.cosmeticallyEqual("안녕하세요 오늘은", "안녕하세요, 오늘은."))
        XCTAssertTrue(TranscriptStore.cosmeticallyEqual("Hello World", "hello,  world!"))
        XCTAssertTrue(TranscriptStore.cosmeticallyEqual("你好。今天", "你好 今天"))
        XCTAssertFalse(TranscriptStore.cosmeticallyEqual("소버림", "소버린"), "letter change is material")
        XCTAssertFalse(TranscriptStore.cosmeticallyEqual("오늘은 회의", "오늘은 회의를"),
                       "a particle is content, not punctuation")
    }

    func testCosmeticEditKeepsTranslationValid() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "오늘은", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello, today", sourceRevision: rev))
        // Reconcile-style re-decode: same words, new punctuation.
        XCTAssertTrue(s.editLine(id, "안녕하세요, 오늘은."))
        let line = s.lines.first!
        XCTAssertEqual(line.translations["English"], "Hello, today",
                       "translation stays VALID — no stale demotion, no dots")
        XCTAssertTrue(line.staleTranslations.isEmpty)
        XCTAssertEqual(TranslationStabilityMetrics.shared.cosmeticRebinds, 1)
        // …and the rebound revision accepts follow-up results normally.
        guard let rev2 = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello, today.", sourceRevision: rev2))
    }

    func testMaterialEditStillGoesStale() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "소버림", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Soverim", sourceRevision: rev))
        XCTAssertTrue(s.editLine(id, "소버린"))
        let line = s.lines.first!
        XCTAssertNil(line.translations["English"], "material change must invalidate")
        XCTAssertEqual(line.staleTranslations["English"], "Soverim")
        XCTAssertEqual(TranslationStabilityMetrics.shared.cosmeticRebinds, 0)
    }

    func testSuppressionVerdictSurvivesCosmeticEdit() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.suppressTranslation(id, lang: "Japanese", sourceRevision: rev))
        XCTAssertTrue(s.editLine(id, "안녕하세요."))
        XCTAssertTrue(s.lines.first?.suppressedTranslations.contains("Japanese") ?? false,
                      "the guard's verdict binds to content, not to punctuation")
    }

    func testCosmeticWordReviewKeepsTranslation() {
        let s = TranscriptStore()
        s.ingest(.word(t0: 0, t1: 0.3, text: "안녕하세요", conf: 0.4))
        s.ingest(.word(t0: 0.4, t1: 0.7, text: "오늘은", conf: 1))
        guard let id = s.lines.first?.id, let rev = s.sourceRevision(for: id) else { return XCTFail() }
        XCTAssertTrue(s.setTranslation(id, lang: "English", "Hello today", sourceRevision: rev))
        XCTAssertTrue(s.editWord(id, index: 0, to: "안녕하세요,"))
        XCTAssertEqual(s.lines.first?.translations["English"], "Hello today")
        XCTAssertEqual(TranslationStabilityMetrics.shared.cosmeticRebinds, 1)
    }
}
