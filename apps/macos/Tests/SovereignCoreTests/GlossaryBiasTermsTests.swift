import XCTest
@testable import SovereignCore

/// S4 — the glossary now also biases the DECODER (engine `PROMPT`), not just the
/// post-hoc text. Measured 2026-08-27 (docs/ENGINE_EVAL.md S4): a matched glossary
/// lifted rare-word recovery 32.7% → 51.0%, a mismatched one made CER worse than
/// none — so these tests pin the RELEVANCE gates that keep the list matched.
final class GlossaryBiasTermsTests: XCTestCase {

    private func glossary(enabled: Bool = true, minHits: Int = 2,
                          _ pairs: [(String, String, Int)]) -> Glossary {
        var g = Glossary()
        g.enabled = enabled
        g.minHits = minHits
        for (wrong, right, hits) in pairs {
            g.entries[wrong] = GlossaryEntry(wrong: wrong, right: right, hits: hits)
        }
        return g
    }

    func testOffGlossaryBiasesNothing() {
        let g = glossary(enabled: false, [("소버림", "소버린", 5)])
        XCTAssertTrue(PersonalVocabulary.biasTerms(g).isEmpty,
                      "biasing follows the same opt-in as substitution")
    }

    func testOnlyConfirmedRulesAreEligible() {
        let g = glossary(minHits: 2, [("소버림", "소버린", 3), ("마디", "마디빔", 1)])
        // hits 1 < minHits 2 — a single accidental edit must not steer the decoder.
        XCTAssertEqual(PersonalVocabulary.biasTerms(g), ["소버린"])
    }

    func testStrongestRulesFirstAndDeterministic() {
        let g = glossary(minHits: 1, [("a", "알파값", 1), ("b", "브라보", 9), ("c", "찰리팀", 5)])
        XCTAssertEqual(PersonalVocabulary.biasTerms(g), ["브라보", "찰리팀", "알파값"])
    }

    func testShortTermsAreSkippedLikeSubstitution() {
        // minLen guard: 2-char Korean tokens collide phonetically with everything.
        let g = glossary(minHits: 1, [("a", "찰리", 9), ("b", "소버린", 9)])
        XCTAssertEqual(PersonalVocabulary.biasTerms(g), ["소버린"])
    }

    func testTermCountIsCapped() {
        let pairs = (0..<100).map { ("w\($0)", "용어\($0)", 100 - $0) }
        let terms = PersonalVocabulary.biasTerms(glossary(minHits: 1, pairs))
        XCTAssertEqual(terms.count, PersonalVocabulary.maxBiasTerms)
        XCTAssertEqual(terms.first, "용어0", "highest-hit rule survives the cap")
    }

    func testCharBudgetIsRespected() {
        let long = String(repeating: "가", count: 200)
        let pairs = (0..<20).map { ("w\($0)", long + "\($0)", 50 - $0) }
        let terms = PersonalVocabulary.biasTerms(glossary(minHits: 1, pairs))
        let chars = terms.reduce(0) { $0 + $1.count + 1 }
        XCTAssertLessThanOrEqual(chars, PersonalVocabulary.maxBiasChars)
        XCTAssertFalse(terms.isEmpty)
    }

    func testMultiWordAndShortTermsAreSkipped() {
        // whitespace would split into separate bias words engine-side; short tokens
        // collide phonetically with everything (same reason substitution skips them).
        let g = glossary(minHits: 1, [("a", "두 단어", 9), ("b", "네", 9), ("c", "소버린", 9)])
        XCTAssertEqual(PersonalVocabulary.biasTerms(g), ["소버린"])
    }

    func testDuplicateSurfaceFormsCollapse() {
        let g = glossary(minHits: 1, [("소버림", "소버린", 5), ("서버린", "소버린", 3)])
        XCTAssertEqual(PersonalVocabulary.biasTerms(g), ["소버린"])
    }

    func testEmptyGlossaryIsEmpty() {
        XCTAssertTrue(PersonalVocabulary.biasTerms(glossary(minHits: 1, [])).isEmpty)
    }

    // ── P6-2 (2026-09-07): only the measured script reaches the prompt ──────

    /// The user's DevOps corrections are Latin-script; in a Korean session they
    /// turned a quiet lecture into German. They never enter the prompt.
    func testLatinScriptTermsNeverBias() {
        let g = glossary(minHits: 1, [("이스티오", "istio", 9), ("람다", "lambda", 9), ("오픈소스", "opensource", 9)])
        XCTAssertTrue(PersonalVocabulary.biasTerms(g).isEmpty, "unmeasured script → no PROMPT at all")
    }

    func testHangulTermsStillBias() {
        let g = glossary(minHits: 1, [("쿠버네티스", "쿠버네티스", 3), ("마이그레이션", "마이그레이션", 2), ("k8s", "K8s", 9)])
        XCTAssertEqual(PersonalVocabulary.biasTerms(g), ["쿠버네티스", "마이그레이션"], "Hangul kept in hit order; mixed-script K8s dropped")
    }

    func testScriptRuleAllowsDigitsAndJamo() {
        XCTAssertTrue(PersonalVocabulary.isBiasScript("소버린2"))
        XCTAssertTrue(PersonalVocabulary.isBiasScript("ㅋㅋㅋ"))
        XCTAssertFalse(PersonalVocabulary.isBiasScript("123"), "no letters at all is not a term")
    }
}
