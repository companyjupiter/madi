import XCTest
@testable import SovereignCore

final class ErasureMathTests: XCTestCase {

    func testPrefixGrowthErasesNothing() {
        XCTAssertEqual(ErasureMath.erasure(from: "안녕하", to: "안녕하세요"), 0)
        XCTAssertEqual(ErasureMath.erasure(from: "", to: "hello"), 0)
    }

    func testTailRewriteErasesOnlyTheTail() {
        // "회의를 시작하겠습니다" → "회의를 시작할게요": common prefix "회의를 시작하"
        XCTAssertEqual(ErasureMath.erasure(from: "회의를 시작하겠습니다", to: "회의를 시작할게요"), 5)
        XCTAssertEqual(ErasureMath.erasure(from: "let us begin", to: "let us start"), 5)
    }

    func testFullReplaceErasesEverything() {
        XCTAssertEqual(ErasureMath.erasure(from: "완전히 다른 문장", to: "전혀 무관한 출력"), 9)
    }

    func testShrinkIsErasure() {
        // Loop-collapse/think-strip can shrink a streamed partial.
        XCTAssertEqual(ErasureMath.erasure(from: "abcdef", to: "abc"), 3)
    }

    func testGraphemeClusters() {
        // Composed Hangul + emoji count as single user-visible characters.
        XCTAssertEqual(ErasureMath.commonPrefixCount("가족👨‍👩‍👧", "가족👨‍👩‍👧입니다"), 3)
    }
}

final class InterimTranslateGateTests: XCTestCase {

    func testFirstRequestAlwaysPasses() {
        XCTAssertTrue(InterimTranslateGate.worthTranslating(source: "안", lastRequested: ""))
    }

    func testEmitterFlapAndShrinkAreGated() {
        XCTAssertFalse(InterimTranslateGate.worthTranslating(
            source: "회의를 시작하겠습니다", lastRequested: "회의를 시작하겠습니다"))
        XCTAssertFalse(InterimTranslateGate.worthTranslating(
            source: "회의를 시작", lastRequested: "회의를 시작하겠습니다"))
    }

    func testSmallTailGrowthWaitsAndBigGrowthPasses() {
        XCTAssertFalse(InterimTranslateGate.worthTranslating(
            source: "회의를 시작하겠습니다 오늘", lastRequested: "회의를 시작하겠습니다"))
        XCTAssertTrue(InterimTranslateGate.worthTranslating(
            source: "회의를 시작하겠습니다 오늘의 안건은", lastRequested: "회의를 시작하겠습니다"))
    }

    func testRealRewritePasses() {
        XCTAssertTrue(InterimTranslateGate.worthTranslating(
            source: "회의를 곧 시작할게요", lastRequested: "회의를 시작하겠습니다"))
    }
}

final class StablePrefixFilterTests: XCTestCase {

    func testPureGrowthPassesThrough() {
        var f = StablePrefixFilter()
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "We"), "We")
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "We will"), "We will")
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "We will begin"), "We will begin")
    }

    func testSmallTailRewriteIsAccepted() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "English", candidate: "We will begin now")
        // erases "now" (3) ≤ tolerance → accepted immediately
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "We will begin today"),
                       "We will begin today")
    }

    func testDeepRewriteFreezesThenAcceptsOnSecondVerdict() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "English", candidate: "The meeting will start in a moment")
        // Whole-prefix rewording — held on first sight…
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "In a moment the meeting starts"),
                       "The meeting will start in a moment")
        // …accepted when a second consecutive candidate still contradicts.
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "In a moment the meeting starts, so"),
                       "In a moment the meeting starts, so")
    }

    func testAgreementResetsTheStreak() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "English", candidate: "The meeting will start in a moment")
        _ = f.stabilize(lang: "English", candidate: "Shortly the meeting is going to start")  // held (streak 1)
        // A candidate that AGREES with the display again clears the streak…
        XCTAssertEqual(f.stabilize(lang: "English",
                                   candidate: "The meeting will start in a moment, everyone"),
                       "The meeting will start in a moment, everyone")
        // …so a later single contradiction is held again.
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "Something entirely different here"),
                       "The meeting will start in a moment, everyone")
    }

    func testShrinkToPrefixIsHeldOnce() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "Korean", candidate: "회의를 시작하겠습니다. 회의를 시작하겠습니다. 회의를 시작하겠습니다.")
        // Loop-collapse shrinks the text (deep erase): un-drawing waits for a
        // second opinion…
        XCTAssertEqual(f.stabilize(lang: "Korean", candidate: "회의를 시작하겠습니다."),
                       "회의를 시작하겠습니다. 회의를 시작하겠습니다. 회의를 시작하겠습니다.")
        // …and lands when confirmed.
        XCTAssertEqual(f.stabilize(lang: "Korean", candidate: "회의를 시작하겠습니다."),
                       "회의를 시작하겠습니다.")
    }

    func testLanguagesAreIndependentAndResetClears() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "English", candidate: "Hello everyone")
        XCTAssertEqual(f.stabilize(lang: "Japanese", candidate: "皆さんこんにちは"), "皆さんこんにちは")
        f.reset()
        // After a window boundary a brand-new sentence replaces freely.
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "Next topic then"), "Next topic then")
    }

    func testRemoveDropsState() {
        var f = StablePrefixFilter()
        _ = f.stabilize(lang: "English", candidate: "Original sentence shown here")
        f.remove(lang: "English")
        XCTAssertEqual(f.stabilize(lang: "English", candidate: "Fresh start"), "Fresh start")
    }
}

@MainActor
final class TranslationStabilityMetricsTests: XCTestCase {

    override func setUp() async throws {
        TranslationStabilityMetrics.shared.reset()
    }

    func testCaptionRewriteSequence() {
        let m = TranslationStabilityMetrics.shared
        m.recordShown(.caption, key: "English", text: "We will")            // first show
        m.recordShown(.caption, key: "English", text: "We will begin")      // growth
        m.recordShown(.caption, key: "English", text: "We are starting")    // rewrite: erases "will begin" (10)
        let c = m.counters[.caption]!
        XCTAssertEqual(c.updates, 3)
        XCTAssertEqual(c.rewrites, 1)
        XCTAssertEqual(c.erasedChars, 10)
    }

    func testIdenticalTextIsNoOp() {
        let m = TranslationStabilityMetrics.shared
        m.recordShown(.caption, key: "English", text: "same")
        m.recordShown(.caption, key: "English", text: "same")
        XCTAssertEqual(m.counters[.caption]?.updates, 1)
    }

    func testRemovalCountsAsFullErase() {
        let m = TranslationStabilityMetrics.shared
        m.recordShown(.panel, key: "L1|English", text: "hello there")
        m.recordShown(.panel, key: "L1|English", text: nil)   // invalidate/prune
        let c = m.counters[.panel]!
        XCTAssertEqual(c.erasedChars, 11)
        XCTAssertEqual(c.rewrites, 1)
        // Removing an already-absent key records nothing.
        m.recordShown(.panel, key: "L1|English", text: nil)
        XCTAssertEqual(m.counters[.panel]?.updates, 2)
    }

    func testCloseCaptionForgetsWithoutCounting() {
        let m = TranslationStabilityMetrics.shared
        m.recordShown(.caption, key: "English", text: "provisional text")
        m.closeCaption()   // committed translation superseded it — not flicker
        XCTAssertEqual(m.counters[.caption]?.erasedChars, 0)
        // Next window's first text is a fresh show, not a rewrite of the old one.
        m.recordShown(.caption, key: "English", text: "next sentence")
        XCTAssertEqual(m.counters[.caption]?.rewrites ?? 0, 0)
    }

    func testFinalPanelCharsIsTheDenominator() {
        let m = TranslationStabilityMetrics.shared
        m.recordShown(.panel, key: "L1|English", text: "final one")   // 9
        m.recordShown(.panel, key: "L1|Korean", text: "최종")          // 2
        XCTAssertEqual(m.finalPanelChars, 11)
        XCTAssertTrue(m.summary().contains("finalChars=11"))
    }
}

final class InterimSourceGateTests: XCTestCase {

    func testCommitsOnlyTheAgreedPrefix() {
        var g = InterimSourceGate(fastFirst: false)
        XCTAssertEqual(g.commit("안녕하세요"), "", "first hypothesis has nothing to agree with")
        // Second decode agrees on "안녕하세요" and adds an unconfirmed tail.
        XCTAssertEqual(g.commit("안녕하세요 오늘은 클라우드"), "안녕하세요")
        // Third agrees through "오늘은 클라우드"…
        XCTAssertEqual(g.commit("안녕하세요 오늘은 클라우드 네이티브"), "안녕하세요 오늘은 클라우드")
    }

    func testUnstableTailNeverReachesTheTranslator() {
        var g = InterimSourceGate(fastFirst: false)
        _ = g.commit("오늘은 클라우드 아키테이였습니다")
        // The tail is re-decoded into something different — it must not have
        // been committed by the earlier call.
        let out = g.commit("오늘은 클라우드 아키텍처에 대해")
        XCTAssertEqual(out, "오늘은 클라우드")
        XCTAssertFalse(out.contains("아키테이였습니다"))
    }

    func testOutputIsAppendOnlyAcrossACosmeticFlip() {
        var g = InterimSourceGate(fastFirst: false)
        var seen: [String] = []
        for h in ["안녕하세요. 오늘은", "안녕하세요. 오늘은 클라우드",
                  "안녕하세요 오늘은 클라우드 네이티브",          // periods vanish
                  "안녕하세요. 오늘은 클라우드 네이티브 아키텍처"] {
            seen.append(g.commit(h))
        }
        for i in 1..<seen.count {
            XCTAssertTrue(seen[i].hasPrefix(seen[i - 1]),
                          "committed source must be append-only: \(seen[i-1]) → \(seen[i])")
        }
        // The surface form committed first is the one that survives.
        XCTAssertTrue(seen.last!.hasPrefix("안녕하세요."))
    }

    func testStallEscapeHatchCommitsRatherThanStarving() {
        var g = InterimSourceGate(maxStall: 2, fastFirst: false)
        _ = g.commit("하나 둘 셋")
        XCTAssertEqual(g.commit("하나 둘 셋 넷"), "하나 둘 셋")
        // Two emitters now flap between different tails, so agreement never
        // advances past "하나 둘 셋" and the caption would starve.
        XCTAssertEqual(g.commit("하나 둘 셋 다섯"), "하나 둘 셋", "first stall still waits")
        let out = g.commit("하나 둘 셋 여섯")   // maxStall reached
        XCTAssertTrue(out.hasPrefix("하나 둘 셋"), "the locked prefix survives the escape hatch")
        XCTAssertGreaterThan(out.count, "하나 둘 셋".count, "stall must eventually commit")
    }

    func testShrinkingHypothesisKeepsCommittedText() {
        var g = InterimSourceGate(fastFirst: false)
        _ = g.commit("하나 둘 셋 넷")
        let committed = g.commit("하나 둘 셋 넷")
        XCTAssertEqual(committed, "하나 둘 셋 넷")
        // A later decode collapses to something shorter — already-committed
        // words must not be withdrawn.
        XCTAssertEqual(g.commit("하나 둘"), "하나 둘 셋 넷")
    }

    func testResetStartsTheNextWindowClean() {
        var g = InterimSourceGate(fastFirst: false)
        _ = g.commit("이전 문장입니다")
        _ = g.commit("이전 문장입니다 계속")
        g.reset()
        XCTAssertEqual(g.commit("새로운"), "")
        XCTAssertEqual(g.commit("새로운 문장"), "새로운")
    }
}

final class InterimDisplayAgreementTests: XCTestCase {

    func testCommitsOnlyWordsTwoResultsAgreeOn() {
        var d = InterimDisplayAgreement(fastFirst: false)
        XCTAssertEqual(d.feed(lang: "English", candidate: "Hello?"), "",
                       "a single MT result proves nothing yet")
        // Next result agrees on "hello" (cosmetically different) — the surface
        // locked is the AGREEING (newest) candidate's, then never changes.
        XCTAssertEqual(d.feed(lang: "English", candidate: "Hello. Today is cloud."), "Hello.")
        // Reworded continuation: the agreed prefix grows only where they match
        // ("Today" vs "Today," agree cosmetically; "is" vs "we" do not).
        XCTAssertEqual(d.feed(lang: "English", candidate: "Hello. Today, we are talking."),
                       "Hello. Today,")
    }

    func testDisplayIsAppendOnlyUnderRewording() {
        var d = InterimDisplayAgreement(fastFirst: false)
        var seen: [String] = []
        for c in ["Hello. Today is cloud.",
                  "Hello. Today was about cloud-native architecture.",
                  "Hello. Today, let's talk about cloud-native architecture.",
                  "Hello today, let's talk about cloud-native architecture. However"] {
            seen.append(d.feed(lang: "English", candidate: c))
        }
        for i in 1..<seen.count {
            XCTAssertTrue(seen[i].hasPrefix(seen[i - 1]),
                          "caption must never rewrite: \(seen[i - 1]) → \(seen[i])")
        }
    }

    func testLanguagesAreIndependent() {
        var d = InterimDisplayAgreement(fastFirst: false)
        _ = d.feed(lang: "English", candidate: "Hello there")
        XCTAssertEqual(d.feed(lang: "Japanese", candidate: "こんにちは"), "")
        XCTAssertEqual(d.feed(lang: "English", candidate: "Hello there friends"), "Hello there")
    }

    func testRemoveAndResetClear() {
        var d = InterimDisplayAgreement(fastFirst: false)
        _ = d.feed(lang: "English", candidate: "Some text here")
        _ = d.feed(lang: "English", candidate: "Some text here too")
        d.remove(lang: "English")
        XCTAssertEqual(d.feed(lang: "English", candidate: "Fresh"), "")
        d.reset()
        XCTAssertEqual(d.feed(lang: "English", candidate: "New window"), "")
    }
}

@MainActor
final class TranslationLatencyTests: XCTestCase {

    private func meter() -> TranslationStabilityMetrics {
        let m = TranslationStabilityMetrics.shared
        m.reset()
        return m
    }

    func testMeasuresElapsedBetweenStartAndEnd() {
        let m = meter()
        var t = 100.0
        m.now = { t }
        m.markStart(.turnTTFT, key: "a")
        t += 0.25
        m.markEnd(.turnTTFT, key: "a")
        XCTAssertEqual(m.samples[.turnTTFT]?.first ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertTrue(m.latencySummary(.turnTTFT).contains("250/250ms"))
    }

    func testRestartDoesNotResetARunningClock() {
        let m = meter()
        var t = 0.0
        m.now = { t }
        m.markStart(.captionFirstPaint, key: "window")
        t += 1.0
        m.markStart(.captionFirstPaint, key: "window")   // debounce re-arm
        t += 1.0
        m.markEnd(.captionFirstPaint, key: "window")
        XCTAssertEqual(m.samples[.captionFirstPaint]?.first ?? 0, 2.0, accuracy: 0.0001,
                       "the window clock must start at the FIRST hypothesis char")
    }

    func testOnlyFirstPaintCounts() {
        let m = meter()
        var t = 0.0
        m.now = { t }
        m.markStart(.turnTTFT, key: "a")
        t += 0.4; m.markEnd(.turnTTFT, key: "a")
        t += 5.0; m.markEnd(.turnTTFT, key: "a")   // later repaints are not TTFT
        XCTAssertEqual(m.samples[.turnTTFT]?.count, 1)
    }

    func testCancelDropsTheMeasurement() {
        let m = meter()
        m.markStart(.captionFirstPaint, key: "window")
        m.cancel(.captionFirstPaint, key: "window")
        m.markEnd(.captionFirstPaint, key: "window")
        XCTAssertNil(m.samples[.captionFirstPaint]?.first)
        XCTAssertEqual(m.latencySummary(.captionFirstPaint), "—")
    }

    func testMedianAndP95AndSummaryWiring() {
        let m = meter()
        var t = 0.0
        m.now = { t }
        for d in [0.1, 0.2, 0.3, 0.4, 2.0] {
            m.markStart(.lineFirstTranslation, key: "\(d)")
            t += d
            m.markEnd(.lineFirstTranslation, key: "\(d)")
        }
        let s = m.latencySummary(.lineFirstTranslation)
        XCTAssertTrue(s.contains("300/2000ms(n=5)"), "got \(s)")
        XCTAssertTrue(m.summary().contains("lineTr=300/2000ms"))
        XCTAssertTrue(m.summary().contains("ttft=—"), "unmeasured axes stay explicit")
    }

    func testResetClearsLatency() {
        let m = meter()
        m.markStart(.turnTTFT, key: "a"); m.markEnd(.turnTTFT, key: "a")
        m.reset()
        XCTAssertTrue(m.samples.isEmpty)
        XCTAssertEqual(m.latencySummary(.turnTTFT), "—")
    }
}

/// P10-2 — first-paint fast path. The 0→1 delay (source cycle + MT turn) is
/// what made the caption feel dead at the start of every window.
final class FirstPaintFastPathTests: XCTestCase {

    func testSourceGatePaintsTheWindowOpeningImmediately() {
        var g = InterimSourceGate()   // fastFirst is the shipped default
        XCTAssertEqual(g.commit("안녕하세요 오늘은"), "안녕하세요 오늘은",
                       "the first hypothesis must not wait for a second decode")
    }

    func testProvisionalPaintYieldsToTheFirstAgreedPrefix() {
        var g = InterimSourceGate()
        XCTAssertEqual(g.commit("안녕하세요 오늘은"), "안녕하세요 오늘은")
        // Only "안녕하세요" is agreed — the provisional opening yields to it.
        // This single correction is the price P10-2 trades for first paint.
        XCTAssertEqual(g.commit("안녕하세요 오늘의 안건은"), "안녕하세요")
    }

    func testProvisionalDoesNotPoisonTheAgreementBaseline() {
        var g = InterimSourceGate()
        _ = g.commit("안녕하세요 오늘은 클라우드 네이티브 아키텍처")   // long, unconfirmed
        _ = g.commit("안녕하세요 오늘은")                            // agreement = 2 words
        // Committing the provisional outright would have frozen the gate here
        // (measured: coverage 60% → 4%). Growth must still flow.
        XCTAssertEqual(g.commit("안녕하세요 오늘은 클라우드"), "안녕하세요 오늘은")
        XCTAssertEqual(g.commit("안녕하세요 오늘은 클라우드 네이티브"),
                       "안녕하세요 오늘은 클라우드")
    }

    func testAppendOnlyHoldsFromTheFirstAgreedPrefixOn() {
        var g = InterimSourceGate()
        _ = g.commit("안녕하세요 오늘은")
        var seen = [g.commit("안녕하세요 오늘은 클라우드")]
        seen.append(g.commit("안녕하세요 오늘은 클라우드 네이티브"))
        seen.append(g.commit("안녕하세요 오늘은 클라우드 네이티브 아키텍처"))
        for i in 1..<seen.count {
            XCTAssertTrue(seen[i].hasPrefix(seen[i - 1]), "\(seen[i-1]) → \(seen[i])")
        }
    }

    func testDisplayGatePaintsTheFirstTranslationImmediately() {
        var d = InterimDisplayAgreement()
        XCTAssertEqual(d.feed(lang: "English", candidate: "Hello, today"), "Hello, today")
        // Nothing agrees yet, so the provisional paint stays rather than blanking.
        XCTAssertEqual(d.feed(lang: "English", candidate: "Hi, this morning"), "Hello, today")
        // Agreement is between CONSECUTIVE results, so this one still disagrees
        // with its predecessor ("Hi," vs "Hello,") — provisional holds.
        XCTAssertEqual(d.feed(lang: "English", candidate: "Hello, this morning"), "Hello, today")
        // Now two consecutive results agree on "Hello, this" — it commits, and
        // the provisional opening yields.
        XCTAssertEqual(d.feed(lang: "English", candidate: "Hello, this afternoon"), "Hello, this")
    }

    func testResetRearmsTheFastPathForTheNextWindow() {
        var g = InterimSourceGate()
        _ = g.commit("첫 윈도")
        g.reset()
        XCTAssertEqual(g.commit("새 윈도 시작"), "새 윈도 시작")
    }
}

/// P10-5 — the responsiveness dials must be settable without a rebuild.
final class InterimTuningTests: XCTestCase {

    func testDefaultsWhenNothingIsSet() {
        let d = UserDefaults(suiteName: "tuning-test-empty")!
        d.removePersistentDomain(forName: "tuning-test-empty")
        XCTAssertEqual(InterimTuning.resolve(env: "X", defaultsKey: "k", default: 3.0,
                                             min: 0, max: 10, environment: [:], defaults: d), 3.0)
    }

    func testEnvironmentOverridesEverythingAndClamps() {
        let d = UserDefaults(suiteName: "tuning-test-env")!
        d.set(9.0, forKey: "k")
        XCTAssertEqual(InterimTuning.resolve(env: "X", defaultsKey: "k", default: 3.0,
                                             min: 0, max: 10, environment: ["X": "1.5"], defaults: d), 1.5)
        XCTAssertEqual(InterimTuning.resolve(env: "X", defaultsKey: "k", default: 3.0,
                                             min: 0, max: 10, environment: ["X": "99"], defaults: d), 10.0)
        XCTAssertEqual(InterimTuning.resolve(env: "X", defaultsKey: "k", default: 3.0,
                                             min: 0, max: 10, environment: ["X": "garbage"], defaults: d), 9.0,
                       "unparseable env falls through to defaults")
        d.removePersistentDomain(forName: "tuning-test-env")
    }

    func testUserDefaultsClampAndZeroDisable() {
        let d = UserDefaults(suiteName: "tuning-test-ud")!
        d.set(0.0, forKey: "k")
        XCTAssertEqual(InterimTuning.resolve(env: "X", defaultsKey: "k", default: 3.0,
                                             min: 0, max: 10, environment: [:], defaults: d), 0.0,
                       "0 must survive (it means 'reservation off'), not fall to the default")
        d.set(-5.0, forKey: "k")
        XCTAssertEqual(InterimTuning.resolve(env: "X", defaultsKey: "k", default: 3.0,
                                             min: 0, max: 10, environment: [:], defaults: d), 0.0)
        d.removePersistentDomain(forName: "tuning-test-ud")
    }
}

/// P12 — sentence-scoped interim + adaptive reservation.
final class InterimSentenceScopeTests: XCTestCase {

    func testSplitAndAdvanceOnlyEverGrows() {
        var l = InterimSentenceLedger()
        var r = l.advance(source: "안녕하세요.")
        XCTAssertEqual(r.newlyCompleted, ["안녕하세요."])
        XCTAssertEqual(r.current, "")
        r = l.advance(source: "안녕하세요. 오늘은 클라우드")
        XCTAssertEqual(r.newlyCompleted, [], "already-counted sentences never repeat")
        XCTAssertEqual(r.current, "오늘은 클라우드")
        r = l.advance(source: "안녕하세요. 오늘은 클라우드 네이티브입니다. 다음")
        XCTAssertEqual(r.newlyCompleted, ["오늘은 클라우드 네이티브입니다."])
        XCTAssertEqual(r.current, "다음")
        XCTAssertEqual(l.sentences.count, 2)
    }

    func testCJKEndersAndNoTrailingEnder() {
        let (c, cur) = InterimSentenceLedger.split("你好。今天呢")
        XCTAssertEqual(c, ["你好。"])
        XCTAssertEqual(cur, "今天呢")
    }

    func testResetStartsClean() {
        var l = InterimSentenceLedger()
        _ = l.advance(source: "문장 하나.")
        l.reset()
        let r = l.advance(source: "새 문장.")
        XCTAssertEqual(r.newlyCompleted, ["새 문장."])
    }

    func testAdaptiveGuaranteeBands() {
        XCTAssertEqual(InterimTuning.adaptiveGuarantee(base: 3, committedBacklog: 0), 3)
        XCTAssertEqual(InterimTuning.adaptiveGuarantee(base: 3, committedBacklog: 2), 3)
        XCTAssertEqual(InterimTuning.adaptiveGuarantee(base: 3, committedBacklog: 4), 6)
        XCTAssertNil(InterimTuning.adaptiveGuarantee(base: 3, committedBacklog: 7),
                     "deep backlog → the reservation yields entirely")
        XCTAssertNil(InterimTuning.adaptiveGuarantee(base: 0, committedBacklog: 0),
                     "0 keeps meaning 'reservation off'")
    }
}
