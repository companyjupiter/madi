// WorkspaceRetrievalTests — cross-meeting lexical retrieval ("ask across ALL
// meetings"). Writes a couple of transcript .md files (the exact bullet format
// TranscriptArchive parses) into a temp dir, queries, and asserts excerpts come
// from the RIGHT meetings and the char budget is respected.
import XCTest
@testable import SovereignCore

final class WorkspaceRetrievalTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsrag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Write a transcript .md in the Exporters.markdown bullet format that
    /// TranscriptArchive.parse round-trips. `rows` = (mm:ss, who, body).
    @discardableResult
    private func writeMeeting(_ name: String, _ rows: [(String, String, String)]) throws -> URL {
        let body = rows.map { "- **[\($0.0)] \($0.1)** \($0.2)" }.joined(separator: "\n")
        let md = "# \(name)\n\n\(body)\n"
        let url = dir.appendingPathComponent(name).appendingPathExtension("md")
        try md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testExcerptsComeFromTheRightMeeting() throws {
        let budget = try writeMeeting("예산회의", [
            ("00:00", "김부장", "오늘 날씨가 좋네요"),
            ("00:05", "이영희", "마케팅 예산이 부족합니다"),
            ("00:10", "김부장", "예산안은 금요일까지 검토하겠습니다"),
        ])
        let hiring = try writeMeeting("채용회의", [
            ("00:00", "박철수", "점심은 김밥 먹읍시다"),
            ("00:05", "박철수", "채용 두 명 진행하겠습니다"),
        ])

        let out = WorkspaceRetrieval.relevantExcerpts(
            "예산은 누가 맡나요?", mdFiles: [hiring, budget], budget: 1000)

        XCTAssertFalse(out.isEmpty)
        // every excerpt that matched 예산 must be tagged to the 예산회의 meeting
        XCTAssertTrue(out.contains { $0.meeting == "예산회의" && $0.text.contains("예산") })
        // none of the picked lines come from the unrelated 채용회의 (no 예산 keyword there)
        XCTAssertFalse(out.contains { $0.meeting == "채용회의" })
        // meeting tag is the file base name, never the .md extension
        XCTAssertFalse(out.contains { $0.meeting.hasSuffix(".md") })
    }

    func testKeywordSpansMultipleMeetings() throws {
        let a = try writeMeeting("회의A", [("00:00", "김부장", "예산 검토가 필요합니다")])
        let b = try writeMeeting("회의B", [("00:00", "이영희", "예산 보고서 제출했습니다")])
        let c = try writeMeeting("회의C", [("00:00", "박철수", "주말 등산 갈 사람")])

        let out = WorkspaceRetrieval.relevantExcerpts(
            "예산은?", mdFiles: [a, b, c], budget: 1000)

        let meetings = Set(out.map { $0.meeting })
        XCTAssertTrue(meetings.contains("회의A"))
        XCTAssertTrue(meetings.contains("회의B"))
        XCTAssertFalse(meetings.contains("회의C"))   // no keyword overlap
    }

    func testBudgetRespected() throws {
        // many matching lines, tiny budget → only the highest-scoring few fit
        let rows = (0..<20).map { ("00:\(String(format: "%02d", $0))", "김부장", "예산 항목 \($0) 검토") }
        let m = try writeMeeting("긴회의", rows)

        let budget = 80
        let out = WorkspaceRetrieval.relevantExcerpts("예산은?", mdFiles: [m], budget: budget)

        XCTAssertFalse(out.isEmpty)
        // combined chars (+3 joiner per excerpt) must stay within budget
        let used = out.reduce(0) { $0 + $1.text.count + 3 }
        XCTAssertLessThanOrEqual(used, budget)
        // and it didn't just take everything
        XCTAssertLessThan(out.count, rows.count)
    }

    func testNoKeywordMatchReturnsEmpty() throws {
        let m = try writeMeeting("회의", [
            ("00:00", "김부장", "안녕하세요 반갑습니다"),
            ("00:05", "이영희", "오늘 회의 시작하겠습니다"),
        ])
        XCTAssertTrue(WorkspaceRetrieval.relevantExcerpts(
            "우주선 발사는?", mdFiles: [m], budget: 500).isEmpty)
    }

    func testUnparseableFilesSkippedGracefully() throws {
        let good = try writeMeeting("진짜회의", [("00:00", "김부장", "예산 검토합니다")])
        // a .md with no recognizable bullet lines → TranscriptArchive.parse returns nil
        let junk = dir.appendingPathComponent("쓰레기.md")
        try "# 제목만 있고 본문 없음\n\n그냥 텍스트 예산\n".write(to: junk, atomically: true, encoding: .utf8)
        // a path that doesn't exist at all
        let missing = dir.appendingPathComponent("없는파일.md")

        let out = WorkspaceRetrieval.relevantExcerpts(
            "예산은?", mdFiles: [junk, missing, good], budget: 1000)

        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0.meeting == "진짜회의" })
    }

    func testDeterministic() throws {
        let a = try writeMeeting("회의A", [("00:00", "김부장", "예산 검토")])
        let b = try writeMeeting("회의B", [("00:00", "이영희", "예산 보고")])
        let r1 = WorkspaceRetrieval.relevantExcerpts("예산은?", mdFiles: [a, b], budget: 1000)
        let r2 = WorkspaceRetrieval.relevantExcerpts("예산은?", mdFiles: [b, a], budget: 1000)
        XCTAssertEqual(r1.map { $0.meeting }, r2.map { $0.meeting })
        XCTAssertEqual(r1.map { $0.text }, r2.map { $0.text })
    }
}
