// PIIRedactorTests — pure PII masking over export text. GUI-free.
import XCTest
@testable import SovereignCore

final class PIIRedactorTests: XCTestCase {

    // ── masks the obvious identifiers ────────────────────────────────────────

    func testMasksEmail() {
        let out = PIIRedactor.redact("연락은 jupiter.song+work@example.co.kr 으로 주세요")
        XCTAssertFalse(out.contains("@example"), "email value removed")
        XCTAssertTrue(out.contains("[이메일]"), "email tagged")
    }

    func testMasksKoreanMobile() {
        for raw in ["010-1234-5678", "010 1234 5678", "01012345678", "011-987-6543"] {
            let out = PIIRedactor.redact("제 번호는 \(raw) 입니다")
            XCTAssertFalse(out.contains(raw), "mobile value \(raw) removed")
            XCTAssertTrue(out.contains("[전화]"), "mobile \(raw) tagged")
        }
    }

    func testMasksKoreanRRN() {
        let out = PIIRedactor.redact("주민번호 900101-1234567 확인했습니다")
        XCTAssertFalse(out.contains("900101-1234567"), "RRN value removed")
        XCTAssertTrue(out.contains("[주민번호]"), "RRN tagged")
        // RRN must win over the phone rule — never tagged [전화] or [번호].
        XCTAssertFalse(out.contains("[전화]"))
        XCTAssertFalse(out.contains("[번호]"))
    }

    func testMasksGenericPhone() {
        for raw in ["02-123-4567", "031-1234-5678", "(02)987-6543"] {
            let out = PIIRedactor.redact("사무실 \(raw) 으로")
            XCTAssertFalse(out.contains(raw), "phone value \(raw) removed")
            XCTAssertTrue(out.contains("[번호]") || out.contains("[전화]"), "phone \(raw) tagged")
        }
    }

    // ── conservative: leaves ordinary meeting text alone ─────────────────────

    func testDoesNotMaskYear() {
        let s = "2026년 예산안을 검토합니다"
        XCTAssertEqual(PIIRedactor.redact(s), s, "plain year untouched")
    }

    func testDoesNotMaskClockTime() {
        let s = "회의는 14:00 에 시작합니다"
        XCTAssertEqual(PIIRedactor.redact(s), s, "clock time untouched")
        let s2 = "9:30부터 10:45까지"
        XCTAssertEqual(PIIRedactor.redact(s2), s2, "time range untouched")
    }

    func testDoesNotMaskShortLooseDigits() {
        let s = "3번 안건과 12번 항목, 총 100개"
        XCTAssertEqual(PIIRedactor.redact(s), s, "short loose digit groups untouched")
    }

    // ── idempotence + structure ──────────────────────────────────────────────

    func testIdempotentOnCleanText() {
        let s = "오늘 회의 안건은 세 가지입니다. 모두 동의하셨습니다."
        XCTAssertEqual(PIIRedactor.redact(s), s)
        XCTAssertTrue(PIIRedactor.detect(s).isEmpty, "no hits on clean text")
    }

    func testIdempotentOnAlreadyRedacted() {
        let once = PIIRedactor.redact("메일 a@b.com 전화 010-1111-2222")
        XCTAssertEqual(PIIRedactor.redact(once), once, "second pass is a no-op")
    }

    func testEmptyString() {
        XCTAssertEqual(PIIRedactor.redact(""), "")
        XCTAssertTrue(PIIRedactor.detect("").isEmpty)
    }

    func testMultipleHitsAllMasked() {
        let out = PIIRedactor.redact("김부장 a@b.com / 010-1234-5678 / 900101-1234567")
        XCTAssertTrue(out.contains("[이메일]"))
        XCTAssertTrue(out.contains("[전화]"))
        XCTAssertTrue(out.contains("[주민번호]"))
        XCTAssertTrue(out.contains("김부장"), "non-PII text preserved")
        XCTAssertEqual(PIIRedactor.detect("김부장 a@b.com / 010-1234-5678 / 900101-1234567").count, 3)
    }
}
