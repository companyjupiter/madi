// VoiceprintStoreTests — list / rename / delete over a real temp directory of
// `<name>.vec` files. Always reads disk fresh; no GUI. GUI-free.
import XCTest
@testable import SovereignCore

final class VoiceprintStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeVec(_ name: String, bytes: [UInt8] = [1, 2, 3, 4]) throws {
        let url = dir.appendingPathComponent("\(name).vec")
        try Data(bytes).write(to: url)
    }

    func testListEnumeratesVecBasenamesSorted() throws {
        try writeVec("김부장")
        try writeVec("이대리")
        try writeVec("박과장")
        // a non-.vec file must be ignored
        try Data([0]).write(to: dir.appendingPathComponent("notes.txt"))
        let store = VoiceprintStore(directory: dir)
        XCTAssertEqual(Set(store.list()), ["김부장", "이대리", "박과장"])
        // sorted output (case-insensitive locale order)
        XCTAssertEqual(store.list(), store.list().sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testListSkipsHiddenLastDirectory() throws {
        // the engine's per-session scratch dir — must never surface as a "voice".
        let last = dir.appendingPathComponent(".last", isDirectory: true)
        try FileManager.default.createDirectory(at: last, withIntermediateDirectories: true)
        try Data([9]).write(to: last.appendingPathComponent("spk0.vec"))
        try writeVec("실제화자")
        let store = VoiceprintStore(directory: dir)
        XCTAssertEqual(store.list(), ["실제화자"])
    }

    func testExists() throws {
        try writeVec("홍길동")
        let store = VoiceprintStore(directory: dir)
        XCTAssertTrue(store.exists("홍길동"))
        XCTAssertFalse(store.exists("없는사람"))
    }

    func testDeleteRemovesFile() throws {
        try writeVec("삭제대상")
        let store = VoiceprintStore(directory: dir)
        XCTAssertTrue(store.delete("삭제대상"))
        XCTAssertFalse(store.exists("삭제대상"))
        XCTAssertTrue(store.list().isEmpty)
    }

    func testDeleteAbsentIsSuccess() {
        let store = VoiceprintStore(directory: dir)
        XCTAssertTrue(store.delete("이미없음"))   // desired end-state already holds
    }

    func testRenameMovesFile() throws {
        try writeVec("구이름")
        let store = VoiceprintStore(directory: dir)
        XCTAssertTrue(store.rename("구이름", to: "새이름"))
        XCTAssertFalse(store.exists("구이름"))
        XCTAssertTrue(store.exists("새이름"))
    }

    func testRenameToExistingRefuses() throws {
        try writeVec("A")
        try writeVec("B")
        let store = VoiceprintStore(directory: dir)
        XCTAssertFalse(store.rename("A", to: "B"))   // no silent overwrite
        XCTAssertTrue(store.exists("A"))             // both survive
        XCTAssertTrue(store.exists("B"))
    }

    func testRenameMissingSourceFails() {
        let store = VoiceprintStore(directory: dir)
        XCTAssertFalse(store.rename("없음", to: "뭐든"))
    }

    func testRenameEmptyTargetFails() throws {
        try writeVec("원본")
        let store = VoiceprintStore(directory: dir)
        XCTAssertFalse(store.rename("원본", to: "   "))
        XCTAssertTrue(store.exists("원본"))
    }

    func testRenameToSameNameIsNoOpSuccess() throws {
        try writeVec("동일")
        let store = VoiceprintStore(directory: dir)
        XCTAssertTrue(store.rename("동일", to: "동일"))
        XCTAssertTrue(store.exists("동일"))
    }

    func testSanitizeStripsSlash() {
        let store = VoiceprintStore(directory: dir)
        XCTAssertEqual(store.sanitize("a/b"), "a_b")
        // url(for:) uses the sanitized name, so a "/" can't escape the directory.
        XCTAssertEqual(store.url(for: "a/b").lastPathComponent, "a_b.vec")
    }

    func testListReadsDiskFreshNoCacheDrift() throws {
        let store = VoiceprintStore(directory: dir)
        XCTAssertTrue(store.list().isEmpty)
        try writeVec("나중에추가")               // added AFTER the store was created
        XCTAssertEqual(store.list(), ["나중에추가"])  // reflected immediately (no cache)
    }
}
