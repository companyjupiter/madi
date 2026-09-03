import XCTest
@testable import SovereignCore

final class TranslationCoalescerTests: XCTestCase {
    private func line(_ text: String, _ start: Double, _ end: Double, speaker: Int = 0) -> TranslationCoalescer.Input {
        TranslationCoalescer.Input(id: UUID(), speaker: speaker, text: text, start: start, end: end)
    }

    func testFragmentDetection() {
        XCTAssertTrue(TranslationCoalescer.isFragment("And"))
        XCTAssertTrue(TranslationCoalescer.isFragment("tools."))
        XCTAssertTrue(TranslationCoalescer.isFragment("So yeah"))
        XCTAssertTrue(TranslationCoalescer.isFragment(""))
        XCTAssertFalse(TranslationCoalescer.isFragment("That was it."))
        XCTAssertFalse(TranslationCoalescer.isFragment("We delete code in the harness all the time."))
    }

    func testFragmentsFoldIntoTheNextLineOfTheSameSpeaker() {
        let a = line("And", 0, 0.3)
        let b = line("tools.", 0.5, 0.9)
        let c = line("we delete code in the harness all the time.", 1.0, 3.5)
        let d = line("That was a new idea.", 4.0, 5.0)
        let runs = TranslationCoalescer.runs([a, b, c, d])
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].anchor, c.id)
        XCTAssertEqual(runs[0].members, [a.id, b.id])
        XCTAssertEqual(runs[0].text, "And tools. we delete code in the harness all the time.")
        XCTAssertEqual(runs[1].anchor, d.id)
        XCTAssertEqual(runs[1].members, [])
    }

    func testSpeakerChangeOrLongGapKeepsFragmentsSeparate() {
        let a = line("And", 0, 0.3, speaker: 1)
        let b = line("What if we get rid of all this scaffolding?", 0.5, 3.0, speaker: 2)
        let c = line("So", 10.0, 10.2, speaker: 2)
        let d = line("That was the product overhang at the time.", 20.0, 22.0, speaker: 2)
        let runs = TranslationCoalescer.runs([a, b, c, d])
        XCTAssertEqual(runs.map(\.anchor), [a.id, b.id, c.id, d.id])
        XCTAssertTrue(runs.allSatisfy { $0.members.isEmpty })
    }

    func testJoinedTextIsCappedSoLongLinesDoNotAbsorbFragments() {
        let frag = line("So", 0, 0.2)
        let long = line(String(repeating: "these companies keep raising capital ", count: 7) + "again.", 0.4, 6)
        let runs = TranslationCoalescer.runs([frag, long])
        XCTAssertEqual(runs.count, 2, "a fragment does not fold into a line that would exceed the joined cap")
        XCTAssertEqual(runs[0].anchor, frag.id); XCTAssertEqual(runs[1].members, [])
    }

    func testTrailingFragmentFlushesAloneOrIsDeferred() {
        let a = line("It's kind of like C.", 0, 1)
        let b = line("It's", 1.2, 1.4)
        let runs = TranslationCoalescer.runs([a, b])
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[1].anchor, b.id)
        XCTAssertEqual(runs[1].text, "It's")
        // live: the trailing fragment waits for the next stable line
        let deferred = TranslationCoalescer.runs([a, b], deferTrailing: true)
        XCTAssertEqual(deferred.map(\.anchor), [a.id])
        // ... and folds into it once it arrives
        let c = line("very low level.", 1.5, 2.5)
        let later = TranslationCoalescer.runs([a, b, c], deferTrailing: true)
        XCTAssertEqual(later.count, 2)
        XCTAssertEqual(later[1].anchor, c.id); XCTAssertEqual(later[1].members, [b.id])
        XCTAssertEqual(later[1].text, "It's very low level.")
    }
}

/// P4 (live 0.3.6): a single presenter was clustered as up to 10 churning ids,
/// and each churn between two fragments forced them into their own DNA turns.
extension TranslationCoalescerTests {
    private func inp(_ i: Int, _ spk: Int, _ text: String, _ t: Double, undecided: Bool) -> TranslationCoalescer.Input {
        TranslationCoalescer.Input(id: UUID(uuidString: "0000000\(i)-0000-0000-0000-000000000000")!,
                                   speaker: spk, text: text, start: t, end: t + 1, undecided: undecided)
    }

    func testUndecidedLabelsDoNotSplitRuns() {
        // 07:20–07:25 live shape: an anchor, then two 2-word fragments the
        // clustering assigned to three different ids while still "화자분리중".
        let churned = [inp(1, 4, "수중 발굴하는 거죠.", 0, undecided: true),
                       inp(2, 6, "그럼 물이", 2, undecided: true),
                       inp(3, 9, "갑자기 폭포가 쏟아졌습니다.", 3, undecided: true)]
        let runs = TranslationCoalescer.runs(churned)
        XCTAssertEqual(runs.count, 2, "the two fragments fold into the following line")
        XCTAssertEqual(runs.last?.members.count, 1)
        XCTAssertTrue(runs.last?.text.contains("그럼 물이") == true)
    }

    func testSettledLabelsStillSplitRuns() {
        let settled = [inp(1, 4, "그럼 물이", 0, undecided: false),
                       inp(2, 6, "갑자기 폭포가 쏟아졌습니다.", 1, undecided: false)]
        let runs = TranslationCoalescer.runs(settled)
        XCTAssertEqual(runs.count, 2, "a believed speaker change still separates the turns")
        XCTAssertTrue(runs.allSatisfy { $0.members.isEmpty })
    }

    func testGapStillSeparatesUndecidedLines() {
        let far = [inp(1, 4, "그럼 물이", 0, undecided: true),
                   inp(2, 6, "갑자기 폭포가 쏟아졌습니다.", 20, undecided: true)]
        XCTAssertEqual(TranslationCoalescer.runs(far).count, 2, "maxGap still bounds a run")
    }
}
