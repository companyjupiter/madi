// RecapData.swift — pure value model for the shareable recap card, extracted
// from RecapCardView so it joins SovereignCore + XCTest (no SwiftUI/AppKit).
//
// Section bucketing reads the SummarySection registry (SummaryTemplate.swift):
// gist → TL;DR, decision → 결정, action-kind (액션 아이템 + 인터뷰 후속 조치) →
// 액션 체크리스트, and the lecture/interview-only sections (핵심 요점 · 용어·개념 ·
// 문답) land in `extras` — rendered as their own card sections so a template
// summary doesn't leave the card bare. Meeting summaries produce no extras, so
// today's card/markdown layout is byte-identical.

import Foundation

/// Pure value model for the recap card — built from a TranscriptStore + summary
/// text, no SwiftUI/engine dependency, so it's trivially testable in isolation.
struct RecapData {
    struct Talk: Identifiable {
        let speaker: Int
        let name: String
        let seconds: Double
        var id: Int { speaker }
    }

    /// A registry section outside the fixed TL;DR/결정/액션 slots (핵심 요점,
    /// 용어·개념, 문답), in summary order. Title is the section's canon.
    struct Extra: Identifiable {
        let title: String
        let items: [String]
        var id: String { title }
    }

    var title: String
    var dateText: String
    var tldr: [String]          // TL;DR 문장/불릿 (요약 섹션)
    var decisions: [String]     // 결정 사항
    var actions: [String]       // action-kind: 액션 아이템 + 후속 조치 (담당자 prefix 포함될 수 있음)
    var extras: [Extra]         // 템플릿 전용 섹션 (요점/용어/문답)
    var talk: [Talk]            // 화자별 발화시간 (내림차순)
    var totalTalk: Double       // 막대 정규화용 최대값(= 최댓값 화자)
    var quote: String?          // 가장 긴 한 줄 인용

    /// Build from the live/archived transcript + the on-device summary text.
    static func make(lines: [Line],
                     names: [Int: String],
                     summary: String?,
                     title: String,
                     date: Date) -> RecapData {
        let df = DateFormatter(); df.dateFormat = "yyyy년 M월 d일 (EEE)"; df.locale = Locale(identifier: "ko_KR")
        let dateText = df.string(from: date)

        // ── sections (reuse the deck's tolerant parser, bucket by registry kind) ──
        var tldr: [String] = [], decisions: [String] = [], actions: [String] = []
        var extras: [Extra] = []
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for sec in SummaryDeck.parseSections(summary) {
                let items = sec.bullets + sec.paras
                switch SummarySection.kind(forCanon: sec.title) {
                case .action:   actions += items
                case .decision: decisions += items
                case .keypoint, .term, .qa:
                    if let i = extras.firstIndex(where: { $0.title == sec.title }) {
                        extras[i] = Extra(title: sec.title, items: extras[i].items + items)
                    } else {
                        extras.append(Extra(title: sec.title, items: items))
                    }
                case .gist, nil: tldr += items   // 요약/기타
                }
            }
        }

        // ── talk-time per speaker ──
        var secs: [Int: Double] = [:]
        for l in lines {
            let d = max(0, l.end - l.start)
            secs[l.speaker, default: 0] += d
        }
        let talk = secs
            .map { Talk(speaker: $0.key,
                        name: SpeakerID.display($0.key, names: names, fallback: "화자\($0.key)"),
                        seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
        let maxTalk = talk.map(\.seconds).max() ?? 0

        // ── key quote: the longest single line (proxy for a substantive remark) ──
        let quote = lines
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
            .max(by: { $0.count < $1.count })

        return RecapData(title: title.isEmpty ? "회의 요약" : title,
                         dateText: dateText,
                         tldr: tldr, decisions: decisions, actions: actions, extras: extras,
                         talk: talk, totalTalk: maxTalk, quote: quote)
    }

    /// One-page Markdown — what "복사"/"내보내기" emit. Extras follow TL;DR (the
    /// template's own section order), then 결정/액션 — empty sections are omitted,
    /// so a meeting summary emits exactly the legacy layout.
    var markdown: String {
        var s = "# \(title)\n\n_\(dateText)_\n"
        if !tldr.isEmpty {
            s += "\n## TL;DR\n"
            for t in tldr { s += "- \(t)\n" }
        }
        for e in extras {
            s += "\n## \(e.title)\n"
            for i in e.items { s += "- \(i)\n" }
        }
        if !decisions.isEmpty {
            s += "\n## 결정\n"
            for d in decisions { s += "- \(d)\n" }
        }
        if !actions.isEmpty {
            s += "\n## 액션\n"
            for a in actions { s += "- [ ] \(a)\n" }
        }
        if !talk.isEmpty {
            s += "\n## 발화 시간\n"
            for t in talk { s += "- \(t.name): \(RecapData.clock(t.seconds))\n" }
        }
        if let quote, !quote.isEmpty {
            s += "\n> \(quote)\n"
        }
        return s
    }

    /// m:ss / h:mm:ss clock for a duration in seconds.
    static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}
