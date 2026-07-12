// SpeakerUnknownTests — the reserved "Unknown" (미확인) speaker bucket: display
// mapping, the sentinel value contract with the engine, and that a saved
// transcript's 미확인 label round-trips back to the reserved id 255 on re-import
// (not a fresh named person).
import XCTest
@testable import SovereignCore

final class SpeakerUnknownTests: XCTestCase {

    func testDisplayMapsUnknownTo미확인() {
        XCTAssertEqual(SpeakerID.display(SpeakerID.unknown, names: [:], fallback: "Speaker 256"), "미확인")
        XCTAssertEqual(SpeakerID.display(0, names: [0: "박Doctor"], fallback: "화자 0"), "박Doctor")
        XCTAssertEqual(SpeakerID.display(1, names: [:], fallback: "화자 1"), "화자 1")
        // a stray name on the Unknown id is ignored — 미확인 always wins
        XCTAssertEqual(SpeakerID.display(SpeakerID.unknown, names: [255: "hijack"], fallback: "x"), "미확인")
    }

    func testUnknownSentinelValue() {
        // Must stay in lockstep with transcribe.zig DIAR_UNK_ID: positive, ≥16, ≤255.
        XCTAssertEqual(SpeakerID.unknown, 255)
        XCTAssertEqual(SpeakerID.unknownLabel, "미확인")
    }

    func testArchiveRoundTripPreservesUnknown() {
        // A saved transcript with a real speaker + the Unknown bucket. On re-import
        // 미확인 must map to id 255 and stay OUT of the names map (so it renders via
        // the shared helper and remains un-nameable / un-enrollable).
        let md = """
        # Transcript

        - **[00:00] Speaker 0** 안녕하세요 원장님
        - **[00:02] 미확인** 실례합니다 커피 나왔어요
        - **[00:05] Speaker 1** 고맙습니다 다시 회의로
        """
        guard let parsed = TranscriptArchive.parse(text: md) else {
            return XCTFail("re-parse failed")
        }
        let ids = parsed.lines.map(\.speaker)
        XCTAssertEqual(ids, [0, SpeakerID.unknown, 1], "미확인 re-imports to reserved 255, reals to 0/1")
        XCTAssertNil(parsed.names[SpeakerID.unknown], "Unknown must NOT become a named speaker")
        XCTAssertEqual(ids.filter { $0 == SpeakerID.unknown }.count, 1, "exactly one Unknown line")
    }
}
