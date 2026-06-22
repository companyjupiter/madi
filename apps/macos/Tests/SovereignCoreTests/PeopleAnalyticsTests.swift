// PeopleAnalyticsTests — the cross-meeting voiceprint-people aggregator. Builds
// transcript fixtures (parsed in-memory AND via temp .md files), asserts per-person
// meeting count + summed talk-time. GUI-free (SovereignCore + XCTest).
import XCTest
@testable import SovereignCore

final class PeopleAnalyticsTests: XCTestCase {

    // Meeting 1: 김부장 speaks 00:00→00:30 then 00:40→01:00; 이대리 fills the gaps.
    // Talk-time is derived span (each line.end = next line.start, last = its own start),
    // so 김부장's two lines span [0,40) and [70,90) → but end is NEXT line's start.
    // Concretely with these four lines: 김부장 line0 end=20(line1 start), line2 end=80.
    private let meeting1 = """
    # Transcript

    - **[00:00] 김부장** 안건 시작합니다
    - **[00:20] 이대리** 네 준비됐습니다
    - **[00:40] 김부장** 첫 번째 항목입니다
    - **[01:20] Speaker 3** 확인했습니다
    """

    // Meeting 2: only 김부장 + an un-named Speaker 0. 이대리 absent → meetings stays 1.
    private let meeting2 = """
    # Transcript

    - **[00:00] 김부장** 두 번째 회의입니다
    - **[00:30] Speaker 0** 알겠습니다
    """

    private func parsed(_ texts: [String]) -> [TranscriptArchive.Parsed] {
        texts.compactMap { TranscriptArchive.parse(text: $0) }
    }

    func testMeetingCountsByNameMatch() {
        let people = PeopleAnalytics.aggregate(
            voiceprintNames: ["김부장", "이대리", "박과장"],
            parsed: parsed([meeting1, meeting2]))

        let by = Dictionary(uniqueKeysWithValues: people.map { ($0.name, $0) })
        XCTAssertEqual(by["김부장"]?.meetings, 2)   // appears in both
        XCTAssertEqual(by["이대리"]?.meetings, 1)   // only meeting1
        XCTAssertEqual(by["박과장"]?.meetings, 0)   // enrolled but never seen
    }

    func testTalkTimeSumsDerivedSpans() {
        let people = PeopleAnalytics.aggregate(
            voiceprintNames: ["김부장", "이대리"],
            parsed: parsed([meeting1]))
        let by = Dictionary(uniqueKeysWithValues: people.map { ($0.name, $0) })

        // meeting1 line starts: 0, 20, 40, 80. Derived ends = next start (last=own).
        //   김부장 lines: [0→20] span 20, [40→80] span 40  ⇒ 60s, 2 lines.
        //   이대리 line:  [20→40] span 20                  ⇒ 20s, 1 line.
        XCTAssertEqual(by["김부장"]?.totalTalk ?? -1, 60, accuracy: 1e-6)
        XCTAssertEqual(by["김부장"]?.lineCount, 2)
        XCTAssertEqual(by["이대리"]?.totalTalk ?? -1, 20, accuracy: 1e-6)
        XCTAssertEqual(by["이대리"]?.lineCount, 1)
    }

    func testSortedByTalkTimeDescending() {
        let people = PeopleAnalytics.aggregate(
            voiceprintNames: ["이대리", "김부장"],
            parsed: parsed([meeting1]))
        // 김부장 (60s) leads 이대리 (20s) regardless of input order.
        XCTAssertEqual(people.first?.name, "김부장")
        XCTAssertEqual(people.last?.name, "이대리")
    }

    func testBlankAndDuplicateNamesIgnored() {
        let people = PeopleAnalytics.aggregate(
            voiceprintNames: ["김부장", "  ", "김부장", ""],
            parsed: parsed([meeting1]))
        XCTAssertEqual(people.filter { $0.name == "김부장" }.count, 1)
        XCTAssertEqual(people.count, 1)
    }

    func testEmptyEnrollmentYieldsNoPeople() {
        XCTAssertTrue(PeopleAnalytics.aggregate(
            voiceprintNames: [], parsed: parsed([meeting1])).isEmpty)
    }

    func testURLPathParsesTempFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeopleAnalyticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let u1 = dir.appendingPathComponent("회의1.md")
        let u2 = dir.appendingPathComponent("회의2.md")
        try meeting1.write(to: u1, atomically: true, encoding: .utf8)
        try meeting2.write(to: u2, atomically: true, encoding: .utf8)

        let people = PeopleAnalytics.aggregate(
            voiceprintNames: ["김부장", "이대리"], mdFiles: [u1, u2])
        let by = Dictionary(uniqueKeysWithValues: people.map { ($0.name, $0) })
        XCTAssertEqual(by["김부장"]?.meetings, 2)
        XCTAssertEqual(by["이대리"]?.meetings, 1)
        // 김부장 talk-time: meeting1 60s + meeting2 (line [00:00] end = next [00:30]
        // start ⇒ span 30) = 90s.
        XCTAssertEqual(by["김부장"]?.totalTalk ?? -1, 90, accuracy: 1e-6)
    }
}
