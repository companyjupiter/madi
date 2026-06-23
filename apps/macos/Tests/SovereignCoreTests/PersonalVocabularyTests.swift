// PersonalVocabularyTests — the matcher over the personal glossary: edit-diffing
// (learn), Jaro-Winkler phonetics, and the defensive correctLine substitution gates
// (confidence floor, length guard, exact-vs-phonetic, identity preservation).
import XCTest
@testable import SovereignCore

final class PersonalVocabularyTests: XCTestCase {

    // helper: build a Line from (t0, t1, text, conf) tuples
    private func line(_ words: [(Double, Double, String, Double)], speaker: Int = 0) -> Line {
        let ws = words.map { Word(t0: $0.0, t1: $0.1, text: $0.2, conf: $0.3) }
        return Line(id: ws.first?.id ?? UUID(), speaker: speaker,
                    start: ws.first?.t0 ?? 0, end: ws.last?.t1 ?? 0, words: ws)
    }

    // ── diff (learning) ───────────────────────────────────────────────────────────
    func testDiffPairsSwappedToken() {
        let pairs = PersonalVocabulary.diff(before: "김방장 회의 진행", after: "김부장 회의 진행")
        XCTAssertEqual(pairs.count, 1)
        // WRONG side = particle-stripped stem (the lookup key, so inflected forms
        // match); RIGHT side = full replacement text (never truncated).
        XCTAssertEqual(pairs.first?.wrong, "김방")
        XCTAssertEqual(pairs.first?.right, "김부장")
    }

    func testDiffLearnedInflectedFormMatchesBareForm() {
        // The feature requirement: a rule learned from an inflected form ("소버린을")
        // must correct a future BARE form ("소버린"). The stored key is the stem, and
        // normalizeKeys produces that stem for the bare form too → exact-key hit.
        let pairs = PersonalVocabulary.diff(before: "소버림을 씁니다", after: "소버린을 씁니다")
        XCTAssertEqual(pairs.first?.wrong, "소버림")   // stem of "소버림을"
        XCTAssertEqual(pairs.first?.right, "소버린을")  // full replacement, particle kept
        var g = Glossary(); g.enabled = true
        g.learn(wrong: pairs[0].wrong, right: pairs[0].right)
        // future BARE "소버림" (conf low, no exact full-key) corrects via the stem key
        XCTAssertEqual(PersonalVocabulary.correctIncomingText("소버림", conf: 0.5, g), "소버린을")
    }

    func testDiffSkipsLengthChange() {
        // inserted word → unsafe to positionally align → no rules learned
        let pairs = PersonalVocabulary.diff(before: "소버림 모델", after: "소버린 온디바이스 모델")
        XCTAssertTrue(pairs.isEmpty)
    }

    func testDiffSkipsShortWrongToken() {
        // "네" → "예" is below minLen; don't pollute the glossary with fillers
        let pairs = PersonalVocabulary.diff(before: "네 알겠습니다", after: "예 알겠습니다")
        XCTAssertTrue(pairs.isEmpty)
    }

    func testDiffNormalizesPunctuation() {
        let pairs = PersonalVocabulary.diff(before: "소버림, 좋아요", after: "소버린, 좋아요")
        // surrounding punctuation stripped; WRONG = stem, RIGHT = full surface form.
        XCTAssertEqual(pairs.first?.wrong, "소버")     // stem of "소버림"
        XCTAssertEqual(pairs.first?.right, "소버린")
    }

    // ── Jaro-Winkler ──────────────────────────────────────────────────────────────
    func testJaroWinklerIdenticalAndDisjoint() {
        XCTAssertEqual(PersonalVocabulary.jaroWinkler("소버린", "소버린"), 1.0, accuracy: 1e-9)
        XCTAssertEqual(PersonalVocabulary.jaroWinkler("", "abc"), 0.0, accuracy: 1e-9)
        XCTAssertLessThan(PersonalVocabulary.jaroWinkler("apple", "졸리다"), 0.2)
    }

    func testJaroWinklerLongHomophoneClearsFloor() {
        // A one-char ASR slip in a LONG token scores above the phonetic floor, while
        // unrelated words fall far below — this is the regime where phonetic is safe.
        XCTAssertGreaterThanOrEqual(
            PersonalVocabulary.jaroWinkler("쿠버네티스", "쿠버네티수"),
            PersonalVocabulary.phoneticFloor)
        XCTAssertLessThan(
            PersonalVocabulary.jaroWinkler("쿠버네티스", "마이크로소프트"),
            PersonalVocabulary.phoneticFloor)
    }

    func testShortKoreanHomophonesAreAmbiguousForPhonetics() {
        // MEASURED REALITY: on short tokens Jaro-Winkler can't tell a true mishearing
        // from a different word sharing a prefix — both ~0.82. This is WHY short
        // tokens use the exact-key path, not phonetic guessing.
        let truePair = PersonalVocabulary.jaroWinkler("소버림", "소버린")    // homophone
        let falsePair = PersonalVocabulary.jaroWinkler("회의록", "회의실")   // different words
        XCTAssertLessThan(truePair, PersonalVocabulary.phoneticFloor)
        XCTAssertEqual(truePair, falsePair, accuracy: 0.01,
                       "short-token JW is indistinguishable → must not phonetic-guess")
    }

    // ── correctLine: gates ─────────────────────────────────────────────────────────
    private func glossary(enabled: Bool = true, _ rules: [(String, String)]) -> Glossary {
        var g = Glossary(); g.enabled = enabled
        for (w, r) in rules { g.learn(wrong: w, right: r) }
        return g
    }

    // ── correctIncomingText (live ingest, string-level) ───────────────────────────
    func testIncomingLowConfExactMatch() {
        let g = glossary([("소버림", "소버린")])
        XCTAssertEqual(PersonalVocabulary.correctIncomingText("소버림", conf: 0.5, g), "소버린")
        XCTAssertEqual(PersonalVocabulary.correctIncomingText("모델", conf: 0.5, g), "모델",
                       "non-glossary word unchanged")
    }

    func testIncomingHighConfidenceNotRewritten() {
        let g = glossary([("소버림", "소버린")])
        // ASR was SURE it heard 소버림 → trust it over the glossary
        XCTAssertEqual(PersonalVocabulary.correctIncomingText("소버림", conf: 0.99, g), "소버림")
    }

    func testIncomingShortTokenNotRewritten() {
        var g = Glossary(); g.enabled = true
        g.entries["네"] = GlossaryEntry(wrong: "네", right: "예")   // force a short rule
        XCTAssertEqual(PersonalVocabulary.correctIncomingText("네", conf: 0.4, g), "네")
    }

    func testIncomingPhoneticOnLongToken() {
        // A LONG term mis-heard with a one-syllable slip and NO exact key is corrected
        // via Jaro-Winkler (the safe regime for phonetic matching).
        var g = Glossary(); g.enabled = true
        g.learn(wrong: "쿠버네티수", right: "쿠버네티스")   // a prior slip the user fixed
        // a NEW, different slip with no exact key:
        XCTAssertEqual(PersonalVocabulary.correctIncomingText("쿠버네티슈", conf: 0.5, g), "쿠버네티스")
    }

    func testIncomingShortTokenNoPhoneticGuess() {
        // A short mishearing with NO exact key must NOT be phonetically rewritten
        // (would risk 회의록→회의실 class false positives).
        var g = Glossary(); g.enabled = true
        g.learn(wrong: "소버린이", right: "소버린")   // exact key is 소버린이, not 소버림
        XCTAssertEqual(PersonalVocabulary.correctIncomingText("소버림", conf: 0.5, g), "소버림",
                       "no exact key + short → left alone")
    }

    func testIncomingDisabledGlossaryIsNoOp() {
        let g = glossary(enabled: false, [("소버림", "소버린")])
        XCTAssertEqual(PersonalVocabulary.correctIncomingText("소버림", conf: 0.4, g), "소버림")
    }

    func testIncomingTrailingPunctuationPreserved() {
        let g = glossary([("소버림", "소버린")])
        XCTAssertEqual(PersonalVocabulary.correctIncomingText("소버림,", conf: 0.5, g), "소버린,",
                       "trailing comma re-attached")
    }

    func testIncomingKoreanNameCorrection() {
        let g = glossary([("김방장", "김부장")])   // 김부장 mis-heard as 김방장 across meetings
        XCTAssertEqual(PersonalVocabulary.correctIncomingText("김방장", conf: 0.6, g), "김부장")
    }

    // ── correctedLineText (grouped lines, non-destructive) ────────────────────────
    func testCorrectedLineTextRewritesEligibleWords() {
        let g = glossary([("소버림", "소버린")])
        let l = line([(0, 1, "소버림", 0.5), (1, 2, "모델", 0.95)])
        XCTAssertEqual(PersonalVocabulary.correctedLineText(l, g), "소버린 모델")
    }

    func testCorrectedLineTextNilWhenNoChange() {
        let g = glossary([("쿠버", "쿠버네티스")])   // no eligible word in the line
        let l = line([(0, 1, "안녕하세요", 0.95), (1, 2, "반갑습니다", 0.9)])
        XCTAssertNil(PersonalVocabulary.correctedLineText(l, g), "no change → nil (skip overlay)")
    }

    func testCorrectedLineTextLeavesEditedLineAlone() {
        var g = Glossary(); g.enabled = true
        g.learn(wrong: "소버림", right: "소버린")
        var l = line([(0, 1, "소버림", 0.3)])
        l.editedText = "사용자가 직접 고친 텍스트"
        XCTAssertNil(PersonalVocabulary.correctedLineText(l, g),
                     "user-edited line is left alone")
    }

    func testCorrectedLineTextPunctuationSpacing() {
        let g = glossary([("소버림", "소버린")])
        // trailing-punctuation word then a clitic — verify joinedText spacing rule
        let l = line([(0, 1, "소버림", 0.5), (1, 2, ",", 1.0)])
        // "," has conf 1.0 (not rewritten); spacing convention: no space before ","
        XCTAssertEqual(PersonalVocabulary.correctedLineText(l, g), "소버린,")
    }
}
