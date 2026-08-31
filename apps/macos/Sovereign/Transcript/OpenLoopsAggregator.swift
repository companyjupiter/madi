// OpenLoopsAggregator.swift — pure cross-meeting commitment tracker. Walks the
// workspace .md files, extracts each meeting's open loops (결정 / 액션 / 질문)
// from its on-device summary block, tags every item with its source meeting +
// creation date (→ age), and flags items that are RE-MENTIONED in a LATER
// meeting (keyword overlap) as resolved / followed-up.
//
// The summary block lives either inline in the transcript (`## 회의 요약` from
// Exporters.markdown) or in the sibling "<base> 요약.md" file. Two extraction
// routes, tried in order, cover the model's two output shapes:
//   1. LiveActionRail.parse — strict "[결정]/[액션]/[질문] …" tagged lines
//      (the live-rail / structured summary shape).
//   2. SummaryDeck.parseSections — action/decision-kind section headers per the
//      SummarySection registry (액션 아이템·후속 조치 / 결정 사항) with "- "
//      bullets (the prose summary shape). Questions fall out of an extra
//      "미결/질문" header here since SummaryDeck doesn't model them.
//
// Foundation-only (no SwiftUI/AppKit) → joins SovereignCore + XCTest like
// PeopleAnalytics. The OpenLoopsView renders the [OpenLoopItem] this produces;
// SessionController.openLoopsAnalytics() is the URL-walking entry point.

import Foundation

/// One unresolved commitment surfaced from a past meeting. `kind` reuses the
/// live-rail taxonomy (결정/액션/질문); `owner` is set for action items only.
/// `meetingDate` is the source .md's creation date (→ `ageDays`); `isResolved`
/// is true when a LATER meeting re-mentions it strongly enough, in which case
/// `followedUpInMeeting` / `followUpAfterDays` describe the follow-up.
struct OpenLoopItem: Identifiable, Hashable {
    enum Kind: String { case decision = "결정", action = "액션", question = "질문" }

    let kind: Kind
    let owner: String?
    let text: String
    let meetingName: String          // source .md basename (no extension)
    let meetingDate: Date            // source .md creation date
    var isResolved: Bool = false     // re-mentioned in a later meeting
    var followedUpInMeeting: String? = nil
    var followUpAfterDays: Int? = nil

    /// Content-derived id, mirrors RailItem.id so the same loop keeps identity
    /// across refreshes. Scoped by meeting so the same text in two meetings is
    /// two distinct loops.
    var id: String { "\(meetingName)|\(kind.rawValue)|\(owner ?? "")|\(text)" }

    /// Whole days from `meetingDate` to `now` (≥0). The UI shows "N일째 후속 없음".
    func ageDays(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: meetingDate)
        let to = calendar.startOfDay(for: now)
        return max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    }
}

/// A meeting's extracted loops plus the metadata the aggregator needs to age them
/// and scan for re-mentions. Public so tests can build fixtures without temp files
/// (the URL route below converts to this).
struct MeetingLoops {
    let name: String
    let date: Date
    let items: [(kind: OpenLoopItem.Kind, owner: String?, text: String)]
    /// Full searchable text of the meeting (summary + any transcript bodies the
    /// caller passes) used to detect re-mentions of EARLIER meetings' loops.
    let searchText: String
}

enum OpenLoopsAggregator {

    // ── URL route (app) ───────────────────────────────────────────────────────

    /// Aggregate open loops across workspace transcript .md files. For each file:
    /// read it, pull its creation date, extract the summary block's loops, and
    /// build a `MeetingLoops`. Unreadable files are skipped (like TranscriptArchive).
    /// `summaryURLForTranscript` lets a transcript without an inline summary borrow
    /// its sibling "<base> 요약.md" — the caller supplies the lookup since the URL
    /// set is theirs.
    static func aggregate(mdFiles: [URL], now: Date = Date(),
                          summaryText: (URL) -> String? = { _ in nil }) -> [OpenLoopItem] {
        var meetings: [MeetingLoops] = []
        for url in mdFiles {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let date = creationDate(of: url) ?? Date.distantPast
            let name = url.deletingPathExtension().lastPathComponent
            // Prefer the inline `## 회의 요약` block; fall back to a sibling 요약.md.
            let summary = summarySection(text) ?? summaryText(url) ?? text
            let items = extractItems(fromSummary: summary)
            meetings.append(MeetingLoops(name: name, date: date, items: items, searchText: text))
        }
        return aggregate(meetings: meetings, now: now)
    }

    // ── in-memory route (tests + shared core) ────────────────────────────────

    /// Aggregate already-built meeting loops. Re-mention detection compares each
    /// item against every LATER meeting's searchText (by date, then name) and
    /// marks it resolved on ≥2 shared content keywords. Returns unresolved-first,
    /// then by age (oldest first), with deterministic tie-breaks.
    static func aggregate(meetings input: [MeetingLoops], now: Date = Date()) -> [OpenLoopItem] {
        // Stable chronological order so "later" is well-defined and deterministic.
        let meetings = input.enumerated().sorted {
            $0.element.date != $1.element.date
                ? $0.element.date < $1.element.date
                : $0.offset < $1.offset
        }.map(\.element)

        var out: [OpenLoopItem] = []
        for (mi, m) in meetings.enumerated() {
            for raw in m.items {
                var item = OpenLoopItem(kind: raw.kind, owner: raw.owner, text: raw.text,
                                        meetingName: m.name, meetingDate: m.date)
                // Scan strictly-later meetings for a re-mention.
                let kws = loopKeywords(owner: raw.owner, text: raw.text)
                if !kws.isEmpty {
                    for later in meetings[(mi + 1)...] where reMentions(later.searchText, kws) {
                        item.isResolved = true
                        item.followedUpInMeeting = later.name
                        item.followUpAfterDays = daysBetween(m.date, later.date)
                        break   // first follow-up wins (meetings already chronological)
                    }
                }
                out.append(item)
            }
        }

        return out.sorted { a, b in
            if a.isResolved != b.isResolved { return !a.isResolved }      // unresolved first
            let aAge = a.ageDays(now: now), bAge = b.ageDays(now: now)
            if aAge != bAge { return aAge > bAge }                        // oldest first
            if a.meetingName != b.meetingName {
                return a.meetingName.localizedCompare(b.meetingName) == .orderedAscending
            }
            return a.id < b.id                                            // final stable tie-break
        }
    }

    // ── summary extraction ────────────────────────────────────────────────────

    /// Pull the `## 회의 요약 … ---` block from a transcript .md (Exporters.markdown
    /// writes the summary first, fenced by a `---` rule). Returns nil if absent so
    /// the caller can fall back to a sibling 요약.md.
    static func summarySection(_ md: String) -> String? {
        let lines = md.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("## 회의 요약")
        }) else { return nil }
        var body: [String] = []
        for l in lines[(start + 1)...] {
            if l.trimmingCharacters(in: .whitespaces) == "---" { break }
            body.append(l)
        }
        let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Extract loop items from a summary block. Route 1: strict tagged lines via
    /// LiveActionRail.parse. Route 2 (when route 1 finds nothing): SummaryDeck's
    /// header+bullet sections, mapping 액션/결정 sections to their kinds, plus a
    /// naive 미결/질문 header scan since SummaryDeck doesn't model questions.
    static func extractItems(fromSummary summary: String)
        -> [(kind: OpenLoopItem.Kind, owner: String?, text: String)] {

        // Route 1 — tagged "[결정]/[액션]/[질문] …" lines.
        let rail = LiveActionRail.parse(summary)
        if !rail.isEmpty {
            return rail.compactMap { it in
                OpenLoopItem.Kind(rawValue: it.kind.rawValue).map { (kind: $0, owner: it.owner, text: it.text) }
            }
        }

        // Route 2 — prose sections (## 액션 아이템 / ## 결정 사항) + 질문 fallback.
        var out: [(kind: OpenLoopItem.Kind, owner: String?, text: String)] = []
        var seen = Set<String>()
        func add(_ kind: OpenLoopItem.Kind, _ owner: String?, _ text: String) {
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            let key = "\(kind.rawValue)|\(owner ?? "")|\(t)"
            if seen.insert(key).inserted { out.append((kind, owner, t)) }
        }
        for sec in SummaryDeck.parseSections(summary) {
            let kind: OpenLoopItem.Kind
            switch SummarySection.kind(forCanon: sec.title) {
            case .action:   kind = .action     // 액션 아이템 + 인터뷰 후속 조치
            case .decision: kind = .decision
            default: continue   // 요약/요점/용어/문답 aren't loops
            }
            for b in sec.bullets {
                if kind == .action, let (o, t) = splitOwner(b) { add(.action, o, t) }
                else { add(kind, nil, b) }
            }
        }
        // Questions: SummaryDeck drops them, so scan for a 미결/질문 header's bullets.
        out.append(contentsOf: questionItems(summary, seen: &seen))
        return out
    }

    /// "이수민 · 부하 테스트…" → ("이수민", "부하 테스트…"). Mirrors LiveActionRail's
    /// owner split (same separators, ≤20-char owner guard).
    private static func splitOwner(_ body: String) -> (String, String)? {
        for sep in [" · ", " — ", " - ", ": "] where body.contains(sep) {
            let parts = body.components(separatedBy: sep)
            if parts.count >= 2, parts[0].count <= 20 {
                let owner = parts[0].trimmingCharacters(in: .whitespaces)
                let text = parts.dropFirst().joined(separator: sep).trimmingCharacters(in: .whitespaces)
                if !owner.isEmpty, !text.isEmpty { return (owner, text) }
            }
            return nil
        }
        return nil
    }

    private static let questionHeader = ["미결", "질문", "open question", "question"]
    private static let bulletMarks = ["- ", "* ", "• ", "■ ", "● ", "▪ ", "· "]

    /// Bullets under a 미결/질문 header (until the next header / rule). Standalone
    /// scan because SummaryDeck.parseSections only models 요약/액션/결정.
    private static func questionItems(_ summary: String, seen: inout Set<String>)
        -> [(kind: OpenLoopItem.Kind, owner: String?, text: String)] {
        var out: [(kind: OpenLoopItem.Kind, owner: String?, text: String)] = []
        var inSection = false
        for raw in summary.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let low = line
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t[]:"))
                .lowercased()
            // A header line: enter the section if it's a question header, else leave.
            let isHeader = line.hasPrefix("#") || line.hasPrefix("[")
                || questionHeader.contains(where: { low.hasPrefix($0) })
            if isHeader {
                inSection = questionHeader.contains { low.hasPrefix($0) }
                continue
            }
            guard inSection else { continue }
            if let mark = bulletMarks.first(where: { line.hasPrefix($0) }) {
                let t = String(line.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
                let key = "질문||\(t)"
                if !t.isEmpty, seen.insert(key).inserted { out.append((.question, nil, t)) }
            }
        }
        return out
    }

    // ── re-mention detection ──────────────────────────────────────────────────

    /// Content keywords for a loop (owner + text), reusing Retrieval.keywords'
    /// tokenizer + Korean particle stemming so re-mention matching is consistent
    /// with Q&A retrieval. Owner is added verbatim (names rarely tokenize well).
    static func loopKeywords(owner: String?, text: String) -> [String] {
        var kws = Retrieval.keywords(text)
        if let o = owner?.trimmingCharacters(in: .whitespaces), o.count >= 2 {
            let low = o.lowercased()
            if !kws.contains(low) { kws.append(low) }
        }
        return kws
    }

    /// A loop is re-mentioned in `text` when ≥2 of its content keywords appear
    /// (conservative — one shared common word is noise). Case-insensitive.
    static func reMentions(_ text: String, _ keywords: [String]) -> Bool {
        guard keywords.count >= 2 else { return false }   // can't clear the bar
        let low = text.lowercased()
        var hits = 0
        for k in keywords where low.contains(k) {
            hits += 1
            if hits >= 2 { return true }
        }
        return false
    }

    // ── dates ─────────────────────────────────────────────────────────────────

    /// File creation date, falling back to modification date (copies/SMB shares
    /// can lose creationDate). nil only when neither is available.
    static func creationDate(of url: URL) -> Date? {
        let vals = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return vals?.creationDate ?? vals?.contentModificationDate
    }

    private static func daysBetween(_ a: Date, _ b: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: a), to = calendar.startOfDay(for: b)
        return max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    }
}
