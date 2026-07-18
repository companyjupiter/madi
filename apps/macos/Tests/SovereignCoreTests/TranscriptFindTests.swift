// TranscriptFindTests — the pure ⌘F match list (case-insensitive substring,
// document order, blank query = nothing). GUI-free.
import XCTest
@testable import SovereignCore

final class TranscriptFindTests: XCTestCase {

    func testMatchesInDocumentOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let lines: [(id: UUID, text: String)] = [
            (a, "부하 테스트를 다음 주에 진행"),
            (b, "예산은 확정됐습니다"),
            (c, "테스트 결과를 공유"),
        ]
        XCTAssertEqual(TranscriptFind.matchingLineIDs(lines, query: "테스트"), [a, c])
    }

    func testCaseInsensitiveLatin() {
        let a = UUID(), b = UUID()
        let lines: [(id: UUID, text: String)] = [(a, "Load Test passed"), (b, "budget OK")]
        XCTAssertEqual(TranscriptFind.matchingLineIDs(lines, query: "test"), [a])
        XCTAssertEqual(TranscriptFind.matchingLineIDs(lines, query: "OK"), [b])
        XCTAssertEqual(TranscriptFind.matchingLineIDs(lines, query: "xyz"), [])
    }

    func testBlankQueryMatchesNothing() {
        let a = UUID()
        let lines: [(id: UUID, text: String)] = [(a, "무엇이든")]
        XCTAssertEqual(TranscriptFind.matchingLineIDs(lines, query: ""), [])
        XCTAssertEqual(TranscriptFind.matchingLineIDs(lines, query: "   "), [])
    }

    func testQueryIsTrimmed() {
        let a = UUID()
        let lines: [(id: UUID, text: String)] = [(a, "결정 사항")]
        XCTAssertEqual(TranscriptFind.matchingLineIDs(lines, query: "  결정  "), [a])
    }
}
