import XCTest
@testable import SovereignCore

/// Live 0.3.5 (2026-09-03, EN→中·한 replay) cases where the gray hypothesis
/// repeated committed words. Each expectation is the text a reader should see
/// after the committed line — never a second copy of it.
final class InterimDedupeTests: XCTestCase {
    private func run(_ tail: String, _ hyp: String) -> String {
        InterimDedupe.continuation(committedTail: tail, hypothesis: hyp)
    }

    func testPlainAppendOnlyOverlapStillWorks() {
        XCTAssertEqual(run("The thing that I think will save", "will save us as a world"), "us as a world")
        XCTAssertEqual(run("Yeah, he got humbled though.", "yeah"), "yeah")       // new speech, not covered
        XCTAssertEqual(run("Well, and then maybe", "some amount of civic pride"), "some amount of civic pride")
    }

    func testBoundaryRewriteAtSeam() {
        // 31:26 — committed "… goes the wrong way and", preview re-decoded the seam as "way. A lot".
        let tail = "You're up in the fourth quarter of every game wendy throws it into the back of some guy misses two free throws daron fox goes the wrong way and"
        let hyp = "goes the wrong way. A lot of mistakes. Yeah. And you'd be talking about firing Mike Brown. I mean, it"
        XCTAssertEqual(run(tail, hyp), "lot of mistakes. Yeah. And you'd be talking about firing Mike Brown. I mean, it")
        // 35:37 — "… subscribers peacock gets yes" vs "subscribers peacock gets espn gets …"
        let tail2 = "what really matters is the number of subscribers peacock gets yes"
        let hyp2 = "subscribers peacock gets espn gets it's the ratings sales but it's more subscribers i mean i"
        XCTAssertEqual(run(tail2, hyp2), "gets it's the ratings sales but it's more subscribers i mean i")
    }

    func testWindowSpanningSeveralCommittedLines() {
        // 35:14 — the open window covered four short committed lines.
        let tail = "Where's your ring? They didn't give you. They didn't yet. No, I'm going to."
        let hyp = "But it is so great to be a champion. God, it was... Where's your ring? They didn't give you... They didn't yet. No, I'm gonna"
        XCTAssertEqual(run(tail, hyp), "")
        // 27:15 — hypothesis head sits in the middle of the tail.
        let tail2 = "let's start with America and then we'll go to humanity yeah no I mean you you know, like every country, we have our issues. That would be kind of insane."
        let hyp2 = "Yeah, no, I mean, you know, like every country, we have our issues. Ours just have to be kind of insane."
        XCTAssertEqual(run(tail2, hyp2), "")
        // 29:04 — previous line's last word + current line re-decoded.
        XCTAssertEqual(run("Yeah, but it's changing. What do you think about all of us",
                           "changing like what do you think about all o"), "")
    }

    func testRepeatedPhraseInTheMiddleIsSpeechNotRedecode() {
        // A trigram that recurs well before the seam must not swallow new speech.
        let tail = "I think that is right, and we should move on. Let me explain the plan."
        XCTAssertEqual(run(tail, "I think that we should try again"), "I think that we should try again")
    }
}
