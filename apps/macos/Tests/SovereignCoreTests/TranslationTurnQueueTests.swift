import Foundation
import XCTest
@testable import SovereignCore

final class TranslationTurnQueueTests: XCTestCase {
    private func turn(id: UUID = UUID(), lang: String = "English", source: String,
                      kind: TranslationTurnKind) -> TranslationTurn {
        TranslationTurn(id: id, lang: lang, source: source, prompt: source,
                        prefix: nil, body: nil, retries: 1, kind: kind)
    }

    // 0.3.1 live regression: the "Now:" turn marker rendered into the target
    // language and echoed at the head of translations (self-reinforcing via the
    // T5 example pair). The sanitizer must strip marker, separator and arrow echoes.
    func testCleanStripsPromptMarkerEcho() {
        XCTAssertEqual(TranslationOutputPolicy.clean("现在： 这是一种后来将定义世界观的视角。"), "这是一种后来将定义世界观的视角。")
        XCTAssertEqual(TranslationOutputPolicy.clean("이제: 나중에 그 세계관을 정의할 것입니다."), "나중에 그 세계관을 정의할 것입니다.")
        XCTAssertEqual(TranslationOutputPolicy.clean("Now: No."), "No.")
        XCTAssertEqual(TranslationOutputPolicy.clean(". 동안 겪어야만 했던 것들"), "동안 겪어야만 했던 것들")
        XCTAssertEqual(TranslationOutputPolicy.clean("後の世界観を定義するもの =>"), "後の世界観を定義するもの")
        XCTAssertEqual(TranslationOutputPolicy.clean("现在：否。 </think> 现在：否。"), "否。")
        // untouched: ordinary sentences that merely start with a time word
        XCTAssertEqual(TranslationOutputPolicy.clean("이제 여기에서 멈추고 내일 계속합니다."), "이제 여기에서 멈추고 내일 계속합니다.")
        XCTAssertEqual(TranslationOutputPolicy.clean("Now we can start."), "Now we can start.")
    }

    // P1: under a deep committed backlog only the priority language is queued;
    // the rest are shed to the stop-time backfill.
    func testSecondaryTargetsShedUnderBacklog() {
        let r1 = TranslationShedPolicy.committedTargets(requested: ["Chinese", "Korean"], priority: "Korean", committedBacklog: 2, threshold: 6)
        XCTAssertEqual(r1.send, ["Chinese", "Korean"]); XCTAssertEqual(r1.shed, [])
        let r2 = TranslationShedPolicy.committedTargets(requested: ["Chinese", "Korean"], priority: "Korean", committedBacklog: 6, threshold: 6)
        XCTAssertEqual(r2.send, ["Korean"]); XCTAssertEqual(r2.shed, ["Chinese"])
        let r3 = TranslationShedPolicy.committedTargets(requested: ["Korean"], priority: "Korean", committedBacklog: 20, threshold: 6)
        XCTAssertEqual(r3.send, ["Korean"]); XCTAssertEqual(r3.shed, [])
        let r4 = TranslationShedPolicy.committedTargets(requested: ["Chinese", "Korean"], priority: nil, committedBacklog: 20, threshold: 6)
        XCTAssertEqual(r4.send, ["Chinese", "Korean"])
        let r5 = TranslationShedPolicy.committedTargets(requested: ["Chinese", "Korean"], priority: "Korean", committedBacklog: 20, threshold: 0)
        XCTAssertEqual(r5.send, ["Chinese", "Korean"])
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

/// T5: the per-turn example slot — previous committed pair when usable, the
/// in-target anchor otherwise (which must reproduce the pre-T5 prompt layout).
final class TranslatePromptTests: XCTestCase {
    func testAnchorFallbackReproducesLegacyLayout() {
        XCTAssertEqual(TranslatePrompt.body(text: "안녕하세요", example: nil, anchor: "Hello"),
                       "Hello => Hello . 안녕하세요 =>")
    }

    func testPreviousPairBecomesTheExample() {
        let ex = TranslatePrompt.Example(source: "김 대리는 어제 밤늦게까지 배포 작업을 했습니다.",
                                         target: "Kim worked on the deployment until late last night.")
        XCTAssertEqual(TranslatePrompt.body(text: "그래서 오늘 늦게 도착했습니다.", example: ex, anchor: "Hello"),
                       "김 대리는 어제 밤늦게까지 배포 작업을 했습니다. => Kim worked on the deployment until late last night. . 그래서 오늘 늦게 도착했습니다. =>")
    }

    func testUnusableExamplesFallBack() {
        let same = TranslatePrompt.Example(source: "같은 문장", target: "Same sentence")
        XCTAssertNil(TranslatePrompt.usableExample(same, for: "같은 문장"), "its own sentence is not context")
        XCTAssertNil(TranslatePrompt.usableExample(TranslatePrompt.Example(source: "", target: "x"), for: "y"))
        XCTAssertNil(TranslatePrompt.usableExample(
            TranslatePrompt.Example(source: String(repeating: "가", count: 201), target: "long"), for: "y"),
            "an over-long pair would push the prefill out of the fixed-cost regime")
        XCTAssertNil(TranslatePrompt.usableExample(TranslatePrompt.Example(source: "a\nb", target: "c"), for: "y"))
        XCTAssertNotNil(TranslatePrompt.usableExample(TranslatePrompt.Example(source: "이전 문장", target: "Previous"), for: "다음 문장"))
    }
}
