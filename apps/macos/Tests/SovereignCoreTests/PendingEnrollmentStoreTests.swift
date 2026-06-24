// PendingEnrollmentStoreTests — deterministic checks of the mid-session
// enrollment buffer (the fix for the enrollment-timing bug). GUI-free.
import XCTest
@testable import SovereignCore

final class PendingEnrollmentStoreTests: XCTestCase {

    func testAddBuffersName() {
        var s = PendingEnrollmentStore()
        XCTAssertTrue(s.isEmpty)
        s.add(id: 1, name: "김부장")
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.names[1], "김부장")
    }

    func testAddTrimsWhitespace() {
        var s = PendingEnrollmentStore()
        s.add(id: 2, name: "  이대리\n")
        XCTAssertEqual(s.names[2], "이대리")
    }

    func testEmptyNameClearsEntry() {
        var s = PendingEnrollmentStore()
        s.add(id: 3, name: "박과장")
        s.add(id: 3, name: "   ")        // user cleared the name back to 화자 N
        XCTAssertNil(s.names[3])
        XCTAssertTrue(s.isEmpty)
    }

    func testLastWriteWinsPerSpeaker() {
        var s = PendingEnrollmentStore()
        s.add(id: 4, name: "임시")
        s.add(id: 4, name: "최종")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.names[4], "최종")
    }

    func testRemove() {
        var s = PendingEnrollmentStore()
        s.add(id: 5, name: "홍길동")
        s.remove(id: 5)
        XCTAssertNil(s.names[5])
    }

    func testPendingIsSortedById() {
        var s = PendingEnrollmentStore()
        s.add(id: 3, name: "c")
        s.add(id: 1, name: "a")
        s.add(id: 2, name: "b")
        let p = s.pending()
        XCTAssertEqual(p.map(\.id), [1, 2, 3])
        XCTAssertEqual(p.map(\.name), ["a", "b", "c"])
    }

    func testFlushedMergesBufferOverBase() {
        var s = PendingEnrollmentStore()
        s.add(id: 1, name: "버퍼우선")     // overrides base[1]
        s.add(id: 9, name: "신규")          // adds a new id
        let base: [Int: String] = [1: "기존", 2: "유지"]
        let merged = s.flushed(into: base)
        XCTAssertEqual(merged[1], "버퍼우선")  // buffer wins
        XCTAssertEqual(merged[2], "유지")       // untouched base survives
        XCTAssertEqual(merged[9], "신규")       // new id added
        // flushed is non-mutating — the buffer is unchanged.
        XCTAssertEqual(s.count, 2)
    }

    func testClearEmptiesBuffer() {
        var s = PendingEnrollmentStore()
        s.add(id: 1, name: "a")
        s.add(id: 2, name: "b")
        s.clear()
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.count, 0)
        XCTAssertTrue(s.pending().isEmpty)
    }
}
