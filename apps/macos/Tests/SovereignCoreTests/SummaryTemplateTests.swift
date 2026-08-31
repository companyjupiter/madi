// SummaryTemplateTests — registry integrity for the one-spine/three-template
// summary taxonomy (docs/SUMMARY_TEMPLATES.md). Guards the invariants the
// parsers rely on: unique tags, alias→section uniqueness, no cross-section
// prefix shadowing (SummaryDeck.matchHeader prefix-matches in registry order),
// the legacy header order (byte-compat with existing meeting summaries), and
// the MeetingMode → template derivation. Foundation-only (SovereignCore + XCTest).
import XCTest
@testable import SovereignCore

final class SummaryTemplateTests: XCTestCase {

    // ── registry integrity ────────────────────────────────────────────────────

    func testModelTagsAreUniqueAcrossRegistry() {
        let tags = SummarySection.registry.map(\.tag)
        XCTAssertEqual(tags.count, Set(tags).count, "duplicate model tag in registry")
    }

    func testCanonTitlesAreUniqueAcrossRegistry() {
        let canons = SummarySection.registry.map(\.canon)
        XCTAssertEqual(canons.count, Set(canons).count, "duplicate canon title in registry")
    }

    func testAliasesMapToExactlyOneSection() {
        var seen: [String: String] = [:]   // alias → canon
        for sec in SummarySection.registry {
            for a in sec.aliases {
                XCTAssertNil(seen[a], "alias '\(a)' claimed by \(seen[a] ?? "?") and \(sec.canon)")
                seen[a] = sec.canon
            }
        }
    }

    /// matchHeader prefix-matches aliases in registry order, so an alias that is
    /// a PREFIX of another section's alias would shadow that section's headers.
    func testNoAliasPrefixShadowingAcrossSections() {
        let all = SummarySection.registry.flatMap { sec in sec.aliases.map { ($0, sec.canon) } }
        for (a, ca) in all {
            for (b, cb) in all where ca != cb {
                XCTAssertFalse(b.lowercased().hasPrefix(a.lowercased()),
                               "alias '\(a)' (\(ca)) shadows '\(b)' (\(cb))")
            }
        }
    }

    /// Legacy order guard: the first three registry entries must stay the
    /// historical 요약/액션/결정 set in that order — SummaryDeck's matching
    /// precedence, and thus every existing meeting summary's parse, depends on it.
    func testLegacyHeaderOrderPreserved() {
        XCTAssertEqual(Array(SummarySection.registry.prefix(3).map(\.canon)),
                       ["요약", "액션 아이템", "결정 사항"])
    }

    func testKindForCanon() {
        XCTAssertEqual(SummarySection.kind(forCanon: "요약"), .gist)
        XCTAssertEqual(SummarySection.kind(forCanon: "액션 아이템"), .action)
        XCTAssertEqual(SummarySection.kind(forCanon: "결정 사항"), .decision)
        XCTAssertEqual(SummarySection.kind(forCanon: "핵심 요점"), .keypoint)
        XCTAssertEqual(SummarySection.kind(forCanon: "용어·개념"), .term)
        XCTAssertEqual(SummarySection.kind(forCanon: "문답"), .qa)
        XCTAssertEqual(SummarySection.kind(forCanon: "후속 조치"), .action)   // 후속 = action kind
        XCTAssertNil(SummarySection.kind(forCanon: "기타 헤더"))
    }

    // ── spine shape ───────────────────────────────────────────────────────────

    func testEveryTemplateIsGistPlusTwoSections() {
        for t in SummaryTemplate.allCases {
            XCTAssertEqual(t.sections.count, 3, "\(t.rawValue) must be the 3-section spine")
            XCTAssertEqual(t.sections.first?.kind, .gist, "\(t.rawValue) must open with [요약]")
        }
    }

    func testMeetingTemplateIsTheLegacySectionSet() {
        XCTAssertEqual(SummaryTemplate.meeting.sections.map(\.tag), ["요약", "액션", "결정"])
    }

    // ── mode → template derivation ────────────────────────────────────────────

    func testModeToTemplateDerivation() {
        XCTAssertEqual(MeetingMode.general.defaultSummaryTemplate, .meeting)
        XCTAssertEqual(MeetingMode.oneOnOne.defaultSummaryTemplate, .meeting)
        XCTAssertEqual(MeetingMode.standup.defaultSummaryTemplate, .meeting)
        XCTAssertEqual(MeetingMode.lecture.defaultSummaryTemplate, .lecture)
        XCTAssertEqual(MeetingMode.interview.defaultSummaryTemplate, .interview)
    }

    // ── round-trip through the deck parser ────────────────────────────────────

    /// Every registry section's model tag resolves back to its canon title via
    /// SummaryDeck.parseSections — the tag a template's prompt asks for is the
    /// tag every consumer can read.
    func testRegistryTagsRoundTripThroughDeckParser() {
        for sec in SummarySection.registry {
            let parsed = SummaryDeck.parseSections("[\(sec.tag)]\n- 항목")
            XCTAssertEqual(parsed.first?.title, sec.canon, "tag [\(sec.tag)] must parse to \(sec.canon)")
            XCTAssertEqual(parsed.first?.bullets, ["항목"])
        }
    }
}
