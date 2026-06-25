// DictationFormattingTests — the Foundation-only seams of system-wide dictation:
// (1) DictationText word-stream assembly (spacing around punctuation + CJK),
// (2) PasteboardSwap save→set→restore with the changeCount race guard.
import XCTest
@testable import SovereignCore

final class DictationFormattingTests: XCTestCase {

    // MARK: - DictationText.assemble

    func testEmptyAndWhitespaceTokens() {
        XCTAssertEqual(DictationText.assemble([]), "")
        XCTAssertEqual(DictationText.assemble(["", "   ", "\t"]), "")
        XCTAssertEqual(DictationText.assemble(["  hi  "]), "hi", "trims edge whitespace")
    }

    func testLatinWordsGetSpaces() {
        XCTAssertEqual(DictationText.assemble(["Hello", "world"]), "Hello world")
    }

    func testNoSpaceBeforeClosingPunctuation() {
        XCTAssertEqual(DictationText.assemble(["Hello", "world", "."]), "Hello world.")
        XCTAssertEqual(DictationText.assemble(["네", ",", "맞아요"]), "네, 맞아요")
        XCTAssertEqual(DictationText.assemble(["really", "?"]), "really?")
    }

    func testCJKRunHasNoInternalSpaces() {
        // Tokenizer splits Hangul into multiple tokens; reassembly must not space them.
        XCTAssertEqual(DictationText.assemble(["안녕", "하세요"]), "안녕하세요")
        XCTAssertEqual(DictationText.assemble(["회의", "내용"]), "회의내용")
    }

    func testMixedCJKAndLatinSpacing() {
        // Hangul→Latin boundary keeps a space (different scripts), Latin→Latin too.
        XCTAssertEqual(DictationText.assemble(["안녕", "하세요", ".", "Hello", "world"]),
                       "안녕하세요. Hello world")
    }

    func testOpenBracketGetsNoTrailingSpace() {
        XCTAssertEqual(DictationText.assemble(["see", "(", "note", ")"]), "see (note)")
    }

    func testIsCJKClassification() {
        XCTAssertTrue(DictationText.isCJK("가"))   // Hangul
        XCTAssertTrue(DictationText.isCJK("あ"))   // Hiragana
        XCTAssertTrue(DictationText.isCJK("漢"))   // CJK ideograph
        XCTAssertFalse(DictationText.isCJK("A"))
        XCTAssertFalse(DictationText.isCJK("1"))
        XCTAssertFalse(DictationText.isCJK(nil))
    }

    // MARK: - PasteboardSwap

    func testSaveRestoreReturnsOriginal() {
        let pb = FakePasteboard(); pb.writeString("original")
        let swap = PasteboardSwap(pb)
        swap.stash()
        swap.set("dictated")
        XCTAssertEqual(pb.readString(), "dictated", "set replaces with dictation text")
        XCTAssertTrue(swap.restore())
        XCTAssertEqual(pb.readString(), "original", "restore puts the user's clipboard back")
    }

    func testRestoreClearsWhenOriginalWasEmpty() {
        let pb = FakePasteboard()   // nothing on it
        let swap = PasteboardSwap(pb)
        swap.stash()
        swap.set("dictated")
        XCTAssertTrue(swap.restore())
        XCTAssertNil(pb.readString(), "empty original → restore clears the dictation text")
    }

    func testChangeCountGuardBacksOffOnRace() {
        let pb = FakePasteboard(); pb.writeString("original")
        let swap = PasteboardSwap(pb)
        swap.stash()
        swap.set("dictated")
        // Simulate a second dictation (or another app) writing the pasteboard.
        pb.writeString("someone else won the race")
        XCTAssertFalse(swap.isUnchangedSinceSet)
        XCTAssertFalse(swap.restore(), "must NOT clobber newer content")
        XCTAssertEqual(pb.readString(), "someone else won the race")
    }

    func testRestoreWithoutStashIsNoOp() {
        let pb = FakePasteboard(); pb.writeString("x")
        let swap = PasteboardSwap(pb)
        XCTAssertFalse(swap.restore(), "restore before stash does nothing")
        XCTAssertEqual(pb.readString(), "x")
    }

    func testSetHandlesUTF8AndEmoji() {
        let pb = FakePasteboard()
        let swap = PasteboardSwap(pb)
        swap.stash()
        swap.set("회의 요약 ✅ 完了")
        XCTAssertEqual(pb.readString(), "회의 요약 ✅ 完了")
    }
}

// MARK: - in-memory pasteboard fake

private final class FakePasteboard: PasteboardBackend {
    private var contents: String?
    private(set) var changeCount = 0
    func readString() -> String? { contents }
    func writeString(_ s: String) { contents = s; changeCount += 1 }
    func clear() { contents = nil; changeCount += 1 }
}
