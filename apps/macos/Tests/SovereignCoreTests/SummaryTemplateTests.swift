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

    // ── localized picker labels (PR-C) ────────────────────────────────────────

    func testTemplateLabelsLocalize() {
        XCTAssertEqual(SummaryTemplate.meeting.label(.ko), "회의")
        XCTAssertEqual(SummaryTemplate.meeting.label(.en), "Meeting")
        XCTAssertEqual(SummaryTemplate.meeting.label(.ja), "会議")
        XCTAssertEqual(SummaryTemplate.lecture.label(.ja), "講義")      // key shared with 강의 mode
        XCTAssertEqual(SummaryTemplate.interview.label(.ja), "面談")    // key shared with 인터뷰 mode
    }

    /// Japanese must resolve through L10nJa for EVERY template string — a miss
    /// silently shows English in the ja UI, which is exactly what this catches.
    func testJapaneseIsTranslatedNotFallingBackToEnglish() {
        for t in SummaryTemplate.allCases {
            XCTAssertNotEqual(t.label(.ja), t.label(.en),
                              "\(t.rawValue) label has no L10nJa entry")
            XCTAssertNotEqual(t.summaryDescription(.ja), t.summaryDescription(.en),
                              "\(t.rawValue) description has no L10nJa entry")
        }
    }

    func testLabelsAndDescriptionsAreDistinctPerTemplate() {
        for lang in UILanguage.allCases {
            let labels = SummaryTemplate.allCases.map { $0.label(lang) }
            let descs = SummaryTemplate.allCases.map { $0.summaryDescription(lang) }
            XCTAssertEqual(Set(labels).count, labels.count, "\(lang.rawValue) labels collide")
            XCTAssertEqual(Set(descs).count, descs.count, "\(lang.rawValue) descriptions collide")
        }
    }

    /// The picker caption must keep naming the template's OWN sections. Driven
    /// FROM the registry, not from copied literals: change a template's sections
    /// and this fails until the caption follows, which is the drift it exists to
    /// catch. (Korean only — en/ja captions are translations of this one, and
    /// their per-language wording is covered by the distinctness tests above.)
    func testKoreanDescriptionNamesItsOwnSections() {
        for t in SummaryTemplate.allCases {
            let caption = t.summaryDescription(.ko)
            for sec in t.sections {
                XCTAssertTrue(caption.contains(sec.tag),
                              "\(t.rawValue) caption '\(caption)' doesn't name its [\(sec.tag)] section")
            }
        }
    }

    /// …and doesn't name sections it does NOT produce (a stale caption left over
    /// from a section swap would still pass the test above).
    func testKoreanDescriptionNamesNothingElse() {
        for t in SummaryTemplate.allCases {
            let caption = t.summaryDescription(.ko)
            let mine = Set(t.sections.map(\.tag))
            for sec in SummarySection.registry where !mine.contains(sec.tag) {
                XCTAssertFalse(caption.contains(sec.tag),
                               "\(t.rawValue) caption '\(caption)' names [\(sec.tag)], which it doesn't produce")
            }
        }
    }

    // ── mode → template derivation ────────────────────────────────────────────

    func testModeToTemplateDerivation() {
        XCTAssertEqual(MeetingMode.general.defaultSummaryTemplate, .meeting)
        XCTAssertEqual(MeetingMode.oneOnOne.defaultSummaryTemplate, .meeting)
        XCTAssertEqual(MeetingMode.standup.defaultSummaryTemplate, .meeting)
        XCTAssertEqual(MeetingMode.lecture.defaultSummaryTemplate, .lecture)
        XCTAssertEqual(MeetingMode.interview.defaultSummaryTemplate, .interview)
    }

    // ── engine prompts (PR-B) ─────────────────────────────────────────────────

    /// GOLDEN: the meeting final/condense prompts must stay byte-for-byte the
    /// legacy SummaryEngine strings — every existing meeting summary, CLI
    /// verification, and saved output depends on this baseline.
    func testMeetingFinalPromptIsByteIdenticalToLegacy() {
        XCTAssertEqual(
            SummaryTemplate.meeting.finalPrompt(transcript: "T", styleSuffix: ""),
            "다음 회의록을 요약하세요. 회의록과 같은 언어로 답하세요. "
            + "형식: [요약] 핵심을 2-4문장. [액션] 각 줄 '- 담당자: 할 일'(없으면 생략). "
            + "[결정] 각 줄 '- 결정사항'(없으면 생략). 다른 말 없이 이 형식만. 회의록: T")
        // styleSuffix appends AFTER the transcript, exactly like the legacy code.
        XCTAssertTrue(SummaryTemplate.meeting
            .finalPrompt(transcript: "T", styleSuffix: " 넛지").hasSuffix("회의록: T 넛지"))
    }

    func testMeetingCondensePromptIsByteIdenticalToLegacy() {
        XCTAssertEqual(
            SummaryTemplate.meeting.condensePrompt(chunk: "C"),
            "다음 회의 내용을 화자(이름)·핵심·결정·할 일을 보존하며 간결히 요약하세요. "
            + "회의록과 같은 언어로, 군더더기 없이. 내용: C")
    }

    /// Every template's final prompt asks for exactly its own section tags, and
    /// the non-meeting prompts carry the probe-driven guards (따옴표 금지).
    func testTemplatePromptsAskForTheirOwnTags() {
        for t in SummaryTemplate.allCases {
            let p = t.finalPrompt(transcript: "T", styleSuffix: "")
            for sec in t.sections { XCTAssertTrue(p.contains("[\(sec.tag)]"), "\(t.rawValue) missing [\(sec.tag)]") }
            XCTAssertTrue(p.contains("다른 말 없이 이 형식만"))
        }
        XCTAssertTrue(SummaryTemplate.lecture.finalPrompt(transcript: "T", styleSuffix: "").contains("따옴표 없이"))
        XCTAssertTrue(SummaryTemplate.interview.finalPrompt(transcript: "T", styleSuffix: "").contains("따옴표 없이"))
    }

    /// Template-aware condense: what a chunk must PRESERVE names the template's
    /// own material (the meeting wording would lose 요점·용어 on a long lecture).
    func testCondensePromptsPreserveTemplateMaterial() {
        XCTAssertTrue(SummaryTemplate.lecture.condensePrompt(chunk: "C").contains("요점"))
        XCTAssertTrue(SummaryTemplate.lecture.condensePrompt(chunk: "C").contains("용어"))
        XCTAssertTrue(SummaryTemplate.interview.condensePrompt(chunk: "C").contains("질문·답변 짝"))
        XCTAssertTrue(SummaryTemplate.interview.condensePrompt(chunk: "C").contains("후속"))
    }

    /// bulletCap values the sanitizer enforces (probe-tuned: 2B ignores in-prompt
    /// count limits, so these ARE the format contract's hard ceiling).
    func testBulletCaps() {
        XCTAssertEqual(SummarySection.qa.bulletCap, 10)        // 5쌍 × Q/A 2줄
        XCTAssertEqual(SummarySection.keypoint.bulletCap, 5)
        XCTAssertEqual(SummarySection.term.bulletCap, 5)
        XCTAssertEqual(SummarySection.followUp.bulletCap, 6)
        for sec in [SummarySection.gist, .action, .decision] {
            XCTAssertEqual(sec.bulletCap, SummaryReplySanitizer.defaultBulletCap)
        }
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
