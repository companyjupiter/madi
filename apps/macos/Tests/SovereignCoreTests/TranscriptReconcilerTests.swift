import XCTest
@testable import SovereignCore

final class TranscriptReconcilerParseTests: XCTestCase {
    private let speakers: Set<Int> = [0, 1, 2, 3]
    private let lineCount = 6

    private func parse(_ s: String) -> ReconcilePlan {
        TranscriptReconciler.parse(s, speakers: speakers, lineCount: lineCount)
    }

    func testWellFormedCommands() {
        let plan = parse("MERGE 1 3\nRELABEL 5 2\nLANG 4 ja")
        XCTAssertEqual(plan.merges, [.merge(from: 1, into: 3)])       // explicit from→into
        XCTAssertEqual(plan.relabels, [.relabel(line: 4, speaker: 2)]) // 1-based → 0-based
        XCTAssertEqual(plan.languageFlags, [.language(line: 3, lang: "Japanese")])
    }

    func testOKMeansNoCorrections() {
        XCTAssertTrue(parse("OK").isEmpty)
        XCTAssertTrue(parse("  ok  ").isEmpty)
    }

    func testDropsOutOfRangeAndUnknownSpeakers() {
        // line 99 out of range, speaker 7 doesn't exist, MERGE with self
        let plan = parse("RELABEL 99 1\nMERGE 0 0\nRELABEL 2 7\nLANG 3 xx")
        XCTAssertTrue(plan.isEmpty)
    }

    func testIgnoresMalformedAndProse() {
        let plan = parse("여기 교정 사항입니다:\nMERGE one three\nMERGE 0 2\n음, 잘 모르겠네요")
        XCTAssertEqual(plan.merges, [.merge(from: 0, into: 2)])
        XCTAssertTrue(plan.relabels.isEmpty)
    }

    func testMergeChainAvoidance() {
        // once 3 is merged away it can't be a merge operand again
        let plan = parse("MERGE 1 3\nMERGE 3 2")
        XCTAssertEqual(plan.merges, [.merge(from: 1, into: 3)])
    }

    func testFirstWinsPerLine() {
        let plan = parse("RELABEL 2 1\nRELABEL 2 3")
        XCTAssertEqual(plan.relabels, [.relabel(line: 1, speaker: 1)])
    }

    func testMaxCorrectionsCap() {
        var s = ""
        for i in 1...40 { s += "LANG \((i % 6) + 1) ja\n" }   // many, but dedup by line → ≤6
        let plan = parse(s)
        XCTAssertLessThanOrEqual(plan.languageFlags.count, 6)
    }

    func testSlashDelimitedFormat() {
        // observed 4B output: it echoes the example's "/" delimiter on one line
        let plan = parse("MERGE 1 3 / RELABEL 5 2 / LANG 4 ja")
        XCTAssertEqual(plan.merges, [.merge(from: 1, into: 3)])
        XCTAssertEqual(plan.relabels, [.relabel(line: 4, speaker: 2)])
        XCTAssertEqual(plan.languageFlags, [.language(line: 3, lang: "Japanese")])
    }

    func testRelabelGateOnlyUncertainLines(){
        // S3 fusion: acoustically-confident lines cannot be flipped by the LLM
        let gated = TranscriptReconciler.parse("RELABEL 2 1\nRELABEL 5 2", speakers: speakers,
                                               lineCount: lineCount, relabelAllowed: [4])
        XCTAssertEqual(gated.relabels, [.relabel(line: 4, speaker: 2)])   // line 2(idx1) dropped
        // nil gate = legacy behavior (all lines allowed)
        let open = TranscriptReconciler.parse("RELABEL 2 1", speakers: speakers, lineCount: lineCount)
        XCTAssertEqual(open.relabels, [.relabel(line: 1, speaker: 1)])
    }

    func testUncertainMarkInPrompt() {
        let input = TranscriptReconciler.promptInput(
            lines: [(0, "안녕하세요"), (1, "네 맞아요")],
            speakerName: { "화자 \($0)" }, uncertain: [1], languageRisk: [0])
        XCTAssertTrue(input.contains("1◇ [S0"))
        XCTAssertTrue(input.contains("2△ [S1"))
    }

    func testLanguageTokens() {
        XCTAssertEqual(TranscriptReconciler.languageToken("Japanese"), 50266)
        XCTAssertEqual(TranscriptReconciler.languageToken("Korean"), 50264)
        XCTAssertNil(TranscriptReconciler.languageToken("Klingon"))
    }

    func testPromptInputNumbering() {
        let input = TranscriptReconciler.promptInput(
            lines: [(0, "안녕하세요"), (1, "のどが痛い")],
            speakerName: { $0 == 0 ? "직원" : "환자" })
        XCTAssertTrue(input.contains("1 [S0·직원] 안녕하세요"))
        XCTAssertTrue(input.contains("2 [S1·환자] のどが痛い"))
    }

    func testPromptBatchesCoverEveryGlobalLineExactlyOnce() {
        let numbered = (1...30).map { "\($0) [S0·화자 0] line-\($0)-" + String(repeating: "x", count: 35) }
            .joined(separator: "\n")
        let batches = TranscriptReconciler.promptBatches(numbered, budget: 180)
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 180 })
        let rows = batches.joined(separator: "\n").split(separator: "\n").map(String.init)
        for i in 1...30 {
            XCTAssertEqual(rows.filter { $0.hasPrefix("\(i) [S0·화자 0]") }.count, 1)
        }
    }
}

/// L2 (2026-09-13): language corrections only toward the session's fixed language.
final class ReconcilerLanguageFlagGateTests: XCTestCase {
    func testFixedKoreanSessionRefusesOtherTargets() {
        XCTAssertTrue(TranscriptReconciler.languageFlagAllowed("Korean", sessionLanguageTokenID: 50264))
        XCTAssertFalse(TranscriptReconciler.languageFlagAllowed("Japanese", sessionLanguageTokenID: 50264), "the row was Korean; a Japanese re-decode is garbage")
        XCTAssertFalse(TranscriptReconciler.languageFlagAllowed("English", sessionLanguageTokenID: 50264))
    }
    func testAutoDetectAllowsEveryFlag() {
        XCTAssertTrue(TranscriptReconciler.languageFlagAllowed("Japanese", sessionLanguageTokenID: nil))
    }
    func testUnknownLanguageNameIsRefusedWhenFixed() {
        XCTAssertFalse(TranscriptReconciler.languageFlagAllowed("Klingon", sessionLanguageTokenID: 50264))
    }
}
