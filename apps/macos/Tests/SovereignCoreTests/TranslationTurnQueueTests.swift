import Foundation
import XCTest
@testable import SovereignCore

final class TranslationTurnQueueTests: XCTestCase {
    private func turn(id: UUID = UUID(), lang: String = "English", source: String,
                      kind: TranslationTurnKind) -> TranslationTurn {
        TranslationTurn(id: id, lang: lang, source: source, prompt: source,
                        prefix: nil, body: nil, retries: 1, kind: kind)
    }

    func testCommittedTurnEvictsPendingInterimAndRunsFirst() {
        var queue = TranslationTurnQueue()
        let interim = turn(source: "draft", kind: .interim)
        XCTAssertTrue(queue.enqueue(interim).accepted)

        let committed = turn(source: "final", kind: .committed)
        let result = queue.enqueue(committed)

        XCTAssertEqual(result.displaced, [interim])
        XCTAssertEqual(queue.popNext(), committed)
        XCTAssertTrue(queue.isEmpty)
    }

    func testNewestRevisionCoalescesSameLineAndLanguage() {
        var queue = TranslationTurnQueue()
        let id = UUID()
        let old = turn(id: id, source: "old revision", kind: .committed)
        let new = turn(id: id, source: "new revision", kind: .committed)
        _ = queue.enqueue(old)

        let result = queue.enqueue(new)

        XCTAssertEqual(result.displaced, [old])
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.popNext(), new)
    }

    func testCommittedRunsBeforeNewerInterimWithinMixedLegacyQueue() {
        var queue = TranslationTurnQueue(turns: [
            turn(source: "committed", kind: .committed),
            turn(source: "new interim", kind: .interim),
        ])

        XCTAssertEqual(queue.popNext()?.source, "committed")
        XCTAssertEqual(queue.popNext()?.source, "new interim")
    }

    func testInterimRejectedWhileCommittedIsInFlightOrQueued() {
        var inFlightQueue = TranslationTurnQueue()
        let interim = turn(source: "draft", kind: .interim)
        XCTAssertFalse(inFlightQueue.enqueue(interim, blockInterim: true).accepted)

        var queued = TranslationTurnQueue()
        _ = queued.enqueue(turn(source: "final", kind: .committed))
        XCTAssertFalse(queued.enqueue(interim).accepted)
    }

    func testOldRetryCannotReplaceNewerPendingRevision() {
        var queue = TranslationTurnQueue()
        let id = UUID()
        let newer = turn(id: id, source: "new revision", kind: .committed)
        let oldRetry = turn(id: id, source: "old retry", kind: .committed)
        _ = queue.enqueue(newer)

        let result = queue.enqueue(oldRetry, replaceExisting: false)

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(queue.popNext(), newer)
    }

    func testLowMemoryCapShedsOldestOnly() {
        var queue = TranslationTurnQueue()
        for i in 0..<6 {
            _ = queue.enqueue(turn(lang: "lang-\(i)", source: "line-\(i)", kind: .committed))
        }

        let shed = queue.shedOldest(to: 4)

        XCTAssertEqual(shed.map(\.source), ["line-0", "line-1"])
        XCTAssertEqual(queue.count, 4)
    }
}

final class TranslateModelVariantTests: XCTestCase {
    func testEightGBSelectsRealtime2B() {
        XCTAssertEqual(
            AssetManifest.recommendedTranslateModelVariant(physicalMemory: 8 * (1 << 30)),
            .realtime2B)
    }

    func testSixteenGBKeepsQuality4BDefault() {
        XCTAssertEqual(
            AssetManifest.recommendedTranslateModelVariant(physicalMemory: 16 * (1 << 30)),
            .quality4B)
    }

    func testModelSpecificAssetsDoNotAlias() {
        XCTAssertNotEqual(AssetManifest.translateModel2B.name, AssetManifest.translateModel4B.name)
        XCTAssertLessThan(AssetManifest.translateModel2B.sizeBytes, AssetManifest.translateModel4B.sizeBytes)
    }
}

final class TranslationOutputPolicyTests: XCTestCase {
    func testRemovesLeakedThinkingAndKeepsFinalAnswer() {
        XCTAssertEqual(
            TranslationOutputPolicy.clean("원문 </think> The meeting starts at three."),
            "The meeting starts at three.")
        XCTAssertEqual(TranslationOutputPolicy.clean("<think>draft only"), "")
    }

    func testCollapsesOnlyConsecutiveExactSentenceLoops() {
        XCTAssertEqual(
            TranslationOutputPolicy.clean("该服务不适用。 该服务不适用。 该服务不适用。"),
            "该服务不适用。")
        XCTAssertEqual(
            TranslationOutputPolicy.clean("Keep this. Keep that. Keep this."),
            "Keep this. Keep that. Keep this.")
        XCTAssertEqual(TranslationOutputPolicy.clean("Yes. Yes."), "Yes. Yes.")
    }

    func testRejectsObservableWrongTargetScripts() {
        XCTAssertTrue(TranslationOutputPolicy.shouldRetry(
            "오늘은 어떤 상담을 도와드릴까요?", source: "오늘은 어떤 상담을 도와드릴까요?", target: "Japanese"))
        XCTAssertTrue(TranslationOutputPolicy.shouldRetry(
            "请从明天使用 순한 cleanser。", source: "내일부터 사용하세요", target: "Chinese"))
        XCTAssertFalse(TranslationOutputPolicy.shouldRetry(
            "今日はどのようなご相談でしょうか？", source: "오늘은 어떤 상담을 도와드릴까요?", target: "Japanese"))
    }

    func testDetectsSourceLanguageForRepairPrompt() {
        XCTAssertEqual(TranslationOutputPolicy.sourceLanguageName(for: "회의를 시작합니다"), "Korean")
        XCTAssertEqual(TranslationOutputPolicy.sourceLanguageName(for: "会議を始めます"), "Japanese")
        XCTAssertEqual(TranslationOutputPolicy.sourceLanguageName(for: "会议开始"), "Chinese")
        XCTAssertEqual(TranslationOutputPolicy.sourceLanguageName(for: "The meeting starts"), "English")
    }
}

/// P10-1 — the interim starvation guarantee. On device the committed lane is
/// busy almost continuously, which starved the caption to 4 turns per session.
final class InterimReservationTests: XCTestCase {

    private func turn(_ kind: TranslationTurnKind, _ lang: String = "English",
                      reserved: Bool = false, id: UUID = UUID()) -> TranslationTurn {
        TranslationTurn(id: id, lang: lang, source: "s", prompt: "p",
                        prefix: nil, body: nil, retries: 1, kind: kind, reserved: reserved)
    }

    func testUnreservedInterimIsStillBlockedByCommitted() {
        var q = TranslationTurnQueue()
        _ = q.enqueue(turn(.committed))
        XCTAssertFalse(q.enqueue(turn(.interim)).accepted,
                       "the existing backpressure must survive")
    }

    func testReservedInterimBypassesTheCommittedBlock() {
        var q = TranslationTurnQueue()
        _ = q.enqueue(turn(.committed))
        XCTAssertTrue(q.enqueue(turn(.interim, reserved: true)).accepted)
        XCTAssertTrue(q.enqueue(turn(.interim, reserved: true), blockInterim: true).accepted,
                      "an in-flight committed turn must not block the reserved slot either")
    }

    func testReservedInterimIsServedBeforePendingCommitted() {
        var q = TranslationTurnQueue()
        _ = q.enqueue(turn(.committed))
        _ = q.enqueue(turn(.interim, reserved: true))
        let first = q.popNext()
        XCTAssertEqual(first?.kind, .interim, "admission alone is not enough — it must RUN")
        XCTAssertEqual(q.popNext()?.kind, .committed)
    }

    func testCommittedEvictionSparesTheReservedInterim() {
        var q = TranslationTurnQueue()
        _ = q.enqueue(turn(.interim, reserved: true))
        _ = q.enqueue(turn(.interim, "Japanese"))   // ordinary interim
        let r = q.enqueue(turn(.committed))
        XCTAssertEqual(r.displaced.count, 1, "only the unreserved interim is evicted")
        XCTAssertEqual(r.displaced.first?.lang, "Japanese")
        XCTAssertTrue(q.turns.contains { $0.reserved })
    }

    func testReservedSlotDoesNotDisableRevisionCoalescing() {
        var q = TranslationTurnQueue()
        let id = UUID()
        _ = q.enqueue(turn(.interim, reserved: true, id: id))
        let r = q.enqueue(turn(.interim, reserved: true, id: id))
        XCTAssertEqual(r.displaced.count, 1, "a newer revision still replaces the older turn")
        XCTAssertEqual(q.count, 1)
    }
}
