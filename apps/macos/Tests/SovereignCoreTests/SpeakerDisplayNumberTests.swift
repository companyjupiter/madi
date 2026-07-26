// Stable display numbering: the property the user actually feels is that the
// person they saw as Speaker 1 is STILL Speaker 1 after the clusterer has merged,
// split and renumbered underneath. These pin that down.

import XCTest
@testable import SovereignCore

final class SpeakerDisplayNumberTests: XCTestCase {

    func testFirstSeenOrderRegardlessOfEngineID() {
        var d = SpeakerDisplayNumber()
        // The engine minted sparse, out-of-order ids — a live recluster does this.
        d.assignAll([7, 7, 0, 7, 12])
        XCTAssertEqual(d.number(7), 1, "first speaker heard is number 1, id 7 or not")
        XCTAssertEqual(d.number(0), 2)
        XCTAssertEqual(d.number(12), 3)
    }

    func testNumberIsNeverReassignedWhenNewSpeakersArrive() {
        var d = SpeakerDisplayNumber()
        d.assign(3)
        XCTAssertEqual(d.number(3), 1)
        // Six more speakers are born later. The regression this guards: the main
        // speaker drifting to a high number as the count grows.
        d.assignAll([4, 5, 6, 8, 9, 11])
        XCTAssertEqual(d.number(3), 1, "Speaker 1 must not become Speaker 8")
        XCTAssertEqual(d.number(11), 7)
    }

    func testRepeatedAssignIsIdempotent() {
        var d = SpeakerDisplayNumber()
        d.assignAll([2, 5])
        let before = d.numbers
        // rebuildLive() runs on every word event and re-walks every line.
        for _ in 0..<50 { d.assignAll([2, 5, 2, 5]) }
        XCTAssertEqual(d.numbers, before)
    }

    func testUnknownBucketNeverGetsANumber() {
        var d = SpeakerDisplayNumber()
        d.assignAll([SpeakerID.unknown, 4])
        XCTAssertNil(d.number(SpeakerID.unknown))
        XCTAssertEqual(d.number(4), 1, "미확인 must not consume number 1")
    }

    func testMergeKeepsTheLowerNumberInBothDirections() {
        var a = SpeakerDisplayNumber()
        a.assignAll([0, 1, 2])          // → 1, 2, 3
        a.merge(from: 2, into: 0)       // clusterer folded the late one into the first
        XCTAssertEqual(a.number(0), 1)
        XCTAssertEqual(a.number(2), 1, "the folded id resolves to the survivor's number")

        var b = SpeakerDisplayNumber()
        b.assignAll([0, 1, 2])
        // Direction is the clusterer's choice, not the user's: folding the FIRST
        // speaker into a later one must still leave the pair showing number 1.
        b.merge(from: 0, into: 2)
        XCTAssertEqual(b.number(2), 1)
        XCTAssertEqual(b.number(0), 1)
    }

    func testMergeIntoAnUnseenIDInheritsTheNumber() {
        var d = SpeakerDisplayNumber()
        d.assign(5)
        d.merge(from: 5, into: 9)
        XCTAssertEqual(d.number(9), 1)
    }

    func testResetClearsNumbering() {
        var d = SpeakerDisplayNumber()
        d.assignAll([4, 6])
        d.reset()
        XCTAssertNil(d.number(4))
        d.assign(6)
        XCTAssertEqual(d.number(6), 1, "a new session starts numbering at 1 again")
    }

    // ── the "화자분리중…" label ────────────────────────────────────────────────

    func testUnsettledMarginRendersAsDiarizingInsteadOfANumber() {
        let s = SpeakerID.display(3, names: [:], number: 1, margin: 0.28,
                                  diarizing: "화자분리중…", fallback: { "Speaker \($0)" })
        XCTAssertEqual(s, "화자분리중…")
    }

    func testSettledMarginRendersTheStableNumber() {
        let s = SpeakerID.display(3, names: [:], number: 1, margin: 0.9,
                                  diarizing: "화자분리중…", fallback: { "Speaker \($0)" })
        XCTAssertEqual(s, "Speaker 1", "the number shown is the display number, not the id")
    }

    func testANamedSpeakerIsNeverShownAsUndecided() {
        let s = SpeakerID.display(3, names: [3: "김 부장"], number: 1, margin: 0.1,
                                  diarizing: "화자분리중…", fallback: { "Speaker \($0)" })
        XCTAssertEqual(s, "김 부장")
    }

    func testUnknownWinsOverEveryOtherState() {
        let s = SpeakerID.display(SpeakerID.unknown, names: [:], number: 1, margin: 0.1,
                                  diarizing: "화자분리중…", fallback: { "Speaker \($0)" })
        XCTAssertEqual(s, SpeakerID.unknownLabel)
    }
}

// The wiring, not just the struct: numbering happens inside rebuildLive(), so
// these drive real engine events through TranscriptStore.
@MainActor
final class SpeakerDisplayNumberStoreTests: XCTestCase {

    /// Sparse, out-of-order engine ids still number 1, 2, 3 in transcript order.
    func testStoreNumbersInTranscriptOrderNotIDOrder() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0.0, id: 7, dur: 1.5)))
        s.ingest(.word(t0: 0.1, t1: 0.4, text: "먼저", conf: 1))
        s.ingest(.speaker(SpeakerLabel(time: 4.0, id: 2, dur: 1.5)))
        s.ingest(.word(t0: 4.1, t1: 4.4, text: "다음", conf: 1))
        XCTAssertEqual(s.speakerNumbers.number(7), 1, "id 7 spoke first → Speaker 1")
        XCTAssertEqual(s.speakerNumbers.number(2), 2, "lower id, later turn → Speaker 2")
    }

    /// The reported bug: five more speakers are born while the session runs, and
    /// the person who was Speaker 1 must still be Speaker 1 at the end.
    func testMainSpeakerKeepsNumberOneAsSpeakersAccumulate() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0.0, id: 0, dur: 1.5)))
        s.ingest(.word(t0: 0.1, t1: 0.4, text: "주화자", conf: 1))
        var t = 4.0
        for id in [3, 5, 6, 9, 12] {
            s.ingest(.speaker(SpeakerLabel(time: t, id: id, dur: 1.5)))
            s.ingest(.word(t0: t + 0.1, t1: t + 0.4, text: "말", conf: 1))
            t += 4.0
        }
        XCTAssertEqual(s.speakerNumbers.number(0), 1, "Speaker 1 must not drift as the count grows")
        XCTAssertEqual(s.speakerNumbers.number(12), 6)
    }

    /// A mid-session merge (over-split fix) keeps the lower number, so the pair
    /// the user has been watching as Speaker 1 stays Speaker 1.
    func testMergeThroughTheStoreKeepsTheLowerNumber() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0.0, id: 4, dur: 1.5)))
        s.ingest(.word(t0: 0.1, t1: 0.4, text: "가", conf: 1))
        s.ingest(.speaker(SpeakerLabel(time: 4.0, id: 1, dur: 1.5)))
        s.ingest(.word(t0: 4.1, t1: 4.4, text: "나", conf: 1))
        XCTAssertEqual(s.speakerNumbers.number(4), 1)
        XCTAssertEqual(s.speakerNumbers.number(1), 2)
        // They turn out to be the same person; the clusterer folds 4 into 1.
        s.mergeSpeaker(from: 4, into: 1)
        XCTAssertEqual(s.speakerNumbers.number(1), 1, "survivor shows the earlier number")
        XCTAssertEqual(s.speakerNumbers.number(4), 1)
    }

    /// A low acoustic margin reaches the store as the line's speakerMargin, which
    /// is what the UI turns into "화자분리중…".
    func testUnsettledMarginReachesTheLine() {
        let s = TranscriptStore()
        s.ingest(.speaker(SpeakerLabel(time: 0.0, id: 0, dur: 1.5, margin: 0.24)))
        s.ingest(.word(t0: 0.1, t1: 0.4, text: "애매", conf: 1))
        guard let line = s.lines.first else { return XCTFail("no line") }
        XCTAssertLessThan(line.speakerMargin, SpeakerID.settledMargin)
    }

    /// Re-opening an archived transcript numbers it in file order, so the same
    /// session reads identically live and after re-open.
    func testLoadedArchiveIsNumberedInFileOrder() {
        let s = TranscriptStore()
        let mk: (Double, Int) -> Line = { t, spk in
            Line(id: UUID(), speaker: spk, start: t, end: t + 0.5,
                 words: [Word(t0: t, t1: t + 0.5, text: "x", conf: 1)])
        }
        s.load([mk(0, 11), mk(2, 4), mk(4, 11)])
        XCTAssertEqual(s.speakerNumbers.number(11), 1)
        XCTAssertEqual(s.speakerNumbers.number(4), 2)
    }
}
