// GistExtractorTests — one-line gist derivation from a saved transcript .md,
// plus the mtime-keyed cache invalidation.
import XCTest
@testable import SovereignCore

final class GistExtractorTests: XCTestCase {

    // A document shaped exactly like Exporters.markdown output, with a summary
    // block carrying [요약]/[액션]/[결정] sections.
    private let full = """
    # Transcript

    ## 회의 요약

    [요약] 1분기 매출 목표를 초과 달성했습니다.
    [액션]
    - 김부장: 금요일까지 예산안 검토
    [결정]
    - 다음 스프린트 월요일 시작

    ---

    > *기울임* 표시된 단어는 인식 신뢰도가 낮습니다 — 검토 권장.

    - **[00:03] 김부장** 안녕하세요 회의를 시작하겠습니다
    - **[00:09] Speaker 1** 네 좋습니다
    """

    // No summary block — only transcript bullets.
    private let bulletsOnly = """
    # Transcript

    > *기울임* 표시된 단어는 인식 신뢰도가 낮습니다 — 검토 권장.

    - **[00:01] Speaker 0** 오늘 안건은 출시 일정입니다 ⟨+Speaker 1 겹침⟩
    - **[00:05] Speaker 1** 다음 주로 미루는 게 좋겠어요
    """

    func testPrefersDecisionLine() {
        // [결정] outranks [요약].
        XCTAssertEqual(GistExtractor.extractGist(from: full), "다음 스프린트 월요일 시작")
    }

    func testFallsBackToSummaryWhenNoDecision() {
        let noDecision = """
        # Transcript

        ## 회의 요약

        [요약] 출시 범위를 축소하기로 논의했습니다.
        [액션]
        - 박해민: 백로그 정리

        ---
        - **[00:02] Speaker 0** 시작합니다
        """
        XCTAssertEqual(GistExtractor.extractGist(from: noDecision),
                       "출시 범위를 축소하기로 논의했습니다.")
    }

    func testFallsBackToFirstBulletWhenNoSummaryBlock() {
        // Speaker label stripped, overlap marker removed.
        XCTAssertEqual(GistExtractor.extractGist(from: bulletsOnly),
                       "오늘 안건은 출시 일정입니다")
    }

    func testStripsConfidenceItalicsInFallback() {
        let md = """
        # Transcript
        - **[00:00] Speaker 0** *오늘* 회의를 *시작*합니다
        """
        XCTAssertEqual(GistExtractor.extractGist(from: md), "오늘 회의를 시작합니다")
    }

    func testEmptyAndNonTranscriptYieldNil() {
        XCTAssertNil(GistExtractor.extractGist(from: ""))
        XCTAssertNil(GistExtractor.extractGist(from: "# Transcript\n\n> legend only\n"))
        XCTAssertNil(GistExtractor.extractGist(from: "random text with no structure"))
    }

    func testLongGistTruncatedWithEllipsis() {
        let long = String(repeating: "가", count: 200)
        let md = "# Transcript\n\n## 회의 요약\n\n[결정] \(long)\n\n---\n"
        let gist = GistExtractor.extractGist(from: md)
        XCTAssertNotNil(gist)
        XCTAssertEqual(gist?.count, GistExtractor.maxLength + 1)  // maxLength chars + "…"
        XCTAssertTrue(gist?.hasSuffix("…") ?? false)
    }

    func testClipCollapsesWhitespace() {
        XCTAssertEqual(GistExtractor.clip("  여러   줄\n  공백  "), "여러 줄 공백")
    }

    // ── cache ──────────────────────────────────────────────────────────────────

    func testCacheReturnsGistAndMemoises() throws {
        let url = tmpFile(full)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = GistCache()
        XCTAssertEqual(cache.gist(for: url), "다음 스프린트 월요일 시작")
        // Second hit returns the same value (memoised path).
        XCTAssertEqual(cache.gist(for: url), "다음 스프린트 월요일 시작")
    }

    func testCacheReReadsAfterModification() throws {
        let url = tmpFile("# Transcript\n\n## 회의 요약\n\n[결정] 첫 번째 결정\n\n---\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = GistCache()
        XCTAssertEqual(cache.gist(for: url), "첫 번째 결정")

        // Rewrite with a newer modification date so the mtime key changes.
        try "# Transcript\n\n## 회의 요약\n\n[결정] 두 번째 결정\n\n---\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)

        XCTAssertEqual(cache.gist(for: url), "두 번째 결정")
    }

    func testCacheMissingFileReturnsNil() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).md")
        XCTAssertNil(GistCache().gist(for: url))
    }

    private func tmpFile(_ contents: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gist-\(UUID().uuidString).md")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
