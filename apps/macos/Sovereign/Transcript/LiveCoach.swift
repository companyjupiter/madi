// LiveCoach.swift — pure, deterministic "live coach / teleprompter" compute for an
// in-progress meeting. Given the agenda items the host walked in with (the prior
// decisions + still-open actions from MeetingPrepBrief) and the live transcript so
// far, it tells the host — at a glance — what's already been covered, what is still
// outstanding, which open questions from the live rail are still unanswered, and
// whether the room is energized or flagging.
//
// Three on-device, model-free signals, all reusing proven building blocks:
//   • agenda coverage — each prep item carries a few content keywords (via the SAME
//     Retrieval.keywords stemming the Q&A retrieval uses); an item is "covered" once
//     enough of its keywords have surfaced in the spoken transcript. So coverage is
//     consistent with how the rest of the app matches text, Korean-particle-aware.
//   • question persistence — live-rail "질문" items that haven't been echoed back by a
//     later spoken line stay flagged as 미답변, so the host doesn't leave a question
//     hanging. A question is considered answered once its keywords reappear in lines
//     spoken AFTER it was raised (a heuristic — cheap, no model).
//   • pace — reuses EnergyArc to emit a compact 0...1 sparkline plus a single
//     "지금 흐름" cue (가열/안정/저조) from the most recent buckets, so the host can
//     feel when the room has gone quiet and needs re-energizing.
//
// Foundation-only (NO SwiftUI) so it joins SovereignCore for XCTest. Stateless,
// fully deterministic for given inputs. The caller (SessionController) owns the
// cheap incremental cache; this core recomputes purely from immutable snapshots so
// every result is reproducible in a unit test.

import Foundation

/// One agenda line the host wants to make sure gets addressed, derived from a
/// MeetingPrepBrief PrepItem (a prior decision or still-open action). `keywords`
/// are precomputed once (via Retrieval.keywords) so coverage checking is cheap on
/// every line append.
struct CoachAgendaItem: Identifiable, Hashable {
    enum Origin: String { case decision = "지난 결정", openItem = "미해결 액션" }
    let origin: Origin
    let speaker: String      // who it was attributed to in the past meeting
    let text: String         // the agenda line itself (display)
    let meeting: String      // source transcript base name (provenance)
    let keywords: [String]   // content keywords for coverage matching
    /// Stable id: provenance + text, so re-deriving the same agenda keeps identity.
    var id: String { "\(meeting)|\(origin.rawValue)|\(text)" }
}

/// A live-rail question and whether the running transcript has since answered it.
struct CoachQuestion: Identifiable, Hashable {
    let text: String
    let answered: Bool
    var id: String { text }
}

/// "지금 흐름" — the room's momentum from the most recent energy buckets.
enum CoachPace: String {
    case heating = "가열"   // recent energy rising / high
    case steady  = "안정"   // recent energy moderate
    case low     = "저조"   // recent energy low — room has gone quiet
    case unknown = "—"      // not enough signal yet
}

/// The full coach snapshot the view renders. Deterministic for given inputs.
struct LiveCoachState {
    var covered: [CoachAgendaItem]      // agenda items already addressed (spoken order-stable)
    var remaining: [CoachAgendaItem]    // agenda items still outstanding
    var questions: [CoachQuestion]      // live-rail questions, answered-flagged
    var energy: [Double]                // 0...1 sparkline (EnergyArc)
    var pace: CoachPace

    /// Items covered / total — for the "3 / 7 다룸" progress readout.
    var coveredCount: Int { covered.count }
    var totalCount: Int { covered.count + remaining.count }
    var unansweredCount: Int { questions.filter { !$0.answered }.count }

    /// Nothing to coach yet (no agenda AND no questions): the view shows an empty
    /// "준비된 안건이 없습니다" state instead of blank sections.
    var isEmpty: Bool { covered.isEmpty && remaining.isEmpty && questions.isEmpty }

    static let empty = LiveCoachState(covered: [], remaining: [], questions: [],
                                      energy: [], pace: .unknown)
}

enum LiveCoach {

    /// How many of an item's keywords must surface before it counts as "covered".
    /// Short items (≤2 keywords) need all of them; longer items need a majority so a
    /// single incidental word doesn't prematurely tick them off.
    static func coverageThreshold(keywordCount n: Int) -> Int {
        guard n > 0 else { return 0 }
        if n <= 2 { return n }
        return n / 2 + 1   // strict majority (>half): 3→2, 4→3, 5→3, 6→4
    }

    /// Derive the coachable agenda from a prep brief: every prior decision + open
    /// item becomes an item, keyworded once via Retrieval.keywords. Items whose text
    /// yields no usable keyword are dropped (can never be matched). Order preserved
    /// (decisions first, then open items — matching the brief's reading order).
    static func agenda(from brief: PrepBriefData) -> [CoachAgendaItem] {
        var out: [CoachAgendaItem] = []
        var seen = Set<String>()
        func add(_ origin: CoachAgendaItem.Origin, _ p: PrepItem) {
            let kws = Retrieval.keywords(p.text)
            guard !kws.isEmpty else { return }
            let item = CoachAgendaItem(origin: origin, speaker: p.speaker, text: p.text,
                                       meeting: p.meeting, keywords: kws)
            if seen.insert(item.id).inserted { out.append(item) }
        }
        for d in brief.decisions { add(.decision, d) }
        for o in brief.openItems { add(.openItem, o) }
        return out
    }

    /// Split the agenda into covered / remaining against the spoken transcript so far.
    /// `spokenLines` is the live transcript's per-line text (chronological). An item
    /// is covered once `coverageThreshold` of its keywords appear anywhere in the
    /// joined spoken text (case-insensitive substring, the same shape Retrieval uses).
    /// Covered items keep agenda order; remaining items keep agenda order.
    static func classify(agenda: [CoachAgendaItem],
                         spokenLines: [String]) -> (covered: [CoachAgendaItem], remaining: [CoachAgendaItem]) {
        let haystack = spokenLines.joined(separator: " \u{2063} ").lowercased()
        var covered: [CoachAgendaItem] = []
        var remaining: [CoachAgendaItem] = []
        for item in agenda {
            let need = coverageThreshold(keywordCount: item.keywords.count)
            var hits = 0
            for kw in item.keywords where haystack.contains(kw.lowercased()) {
                hits += 1
                if hits >= need { break }
            }
            if hits >= need { covered.append(item) } else { remaining.append(item) }
        }
        return (covered, remaining)
    }

    /// Flag live-rail questions as answered/unanswered. A question is answered once a
    /// majority of its keywords reappear in the transcript text — a cheap heuristic
    /// for "the room came back to it". `questionTexts` are the rail's 질문 items in
    /// the order they were raised. Deduped by text, raise-order preserved.
    static func questions(railQuestions questionTexts: [String],
                          spokenLines: [String]) -> [CoachQuestion] {
        let haystack = spokenLines.joined(separator: " \u{2063} ").lowercased()
        var out: [CoachQuestion] = []
        var seen = Set<String>()
        for raw in questionTexts {
            let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty, seen.insert(q).inserted else { continue }
            let kws = Retrieval.keywords(q)
            let answered: Bool
            if kws.isEmpty {
                answered = false   // nothing to match on → treat as still open
            } else {
                let need = coverageThreshold(keywordCount: kws.count)
                var hits = 0
                for kw in kws where haystack.contains(kw.lowercased()) {
                    hits += 1
                    if hits >= need { break }
                }
                answered = hits >= need
            }
            out.append(CoachQuestion(text: q, answered: answered))
        }
        return out
    }

    /// Read momentum from the energy arc's most recent buckets. Averages the last
    /// `window` buckets and compares to the meeting's overall mean: clearly above →
    /// 가열, clearly below → 저조, otherwise 안정. Too few buckets → unknown.
    static func pace(energy: [Double], window: Int = 4) -> CoachPace {
        guard energy.count >= 3 else { return .unknown }
        let w = max(1, min(window, energy.count))
        let recent = energy.suffix(w)
        let recentAvg = recent.reduce(0, +) / Double(recent.count)
        let overallAvg = energy.reduce(0, +) / Double(energy.count)
        // Absolute floor: a recently-near-silent room is 저조 regardless of mean.
        if recentAvg < 0.20 { return .low }
        if recentAvg >= overallAvg * 1.15 { return .heating }
        if recentAvg <= overallAvg * 0.70 { return .low }
        return .steady
    }

    /// One-shot compute of the whole coach state from immutable snapshots. The view's
    /// single entry point; the caller passes the derived agenda (cached), the spoken
    /// line texts, the rail question texts, and the diarized lines for the energy arc.
    static func compute(agenda: [CoachAgendaItem],
                        spokenLines: [String],
                        railQuestions: [String],
                        lines: [Line],
                        energyBuckets: Int = 24) -> LiveCoachState {
        let (covered, remaining) = classify(agenda: agenda, spokenLines: spokenLines)
        let qs = questions(railQuestions: railQuestions, spokenLines: spokenLines)
        let energy = EnergyArc.compute(lines: lines, buckets: energyBuckets)
        return LiveCoachState(covered: covered, remaining: remaining,
                              questions: qs, energy: energy, pace: pace(energy: energy))
    }
}
