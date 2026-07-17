// PeopleAnalytics.swift — pure aggregator for the People dashboard. Cross-meeting
// view of enrolled voiceprint people: for each enrolled name (passed in — the
// caller reads voiceprintsDir/*.vec), walk every saved transcript .md and, when
// that name appears as a named speaker, sum the person's talk-time (Σ line.end −
// line.start over their lines) and count the meeting.
//
// Matching is by speaker NAME: TranscriptArchive.parse yields `names: [Int:String]`
// (named speakers keep their name; un-renamed "Speaker N" never enter `names`), so a
// person participated in a meeting iff their enrolled name is a value in that map.
// Talk-time then sums the lines whose speaker id maps to that name.
//
// Deterministic + Foundation-only (no SwiftUI) so it joins SovereignCore + XCTest.
// The PeopleDashboard view renders the [Person] this produces.

import Foundation

/// One enrolled person aggregated across all saved transcripts. `meetings` is the
/// number of .md files they appear in (by name); `totalTalk` is their summed
/// speaking time in seconds across those meetings; `lineCount` is total lines.
struct Person: Identifiable, Hashable {
    let name: String
    var meetings: Int = 0
    var totalTalk: Double = 0    // seconds, Σ(line.end − line.start) over this person's lines
    var lineCount: Int = 0

    var id: String { name }

    /// Average talk-time per meeting (0 when they appear in no meeting).
    var avgTalkPerMeeting: Double { meetings > 0 ? totalTalk / Double(meetings) : 0 }
}

enum PeopleAnalytics {

    /// Aggregate people across saved transcripts.
    /// - voiceprintNames: enrolled display names (caller derives from *.vec basenames).
    ///   May be empty — voiceprints are unwired for the beta, and seeding from them
    ///   ALONE made this dashboard permanently blank (no .vec is ever written).
    /// - mdFiles: transcript .md URLs (caller derives from the workspace folder).
    /// Returns one Person per named speaker, sorted by totalTalk desc then name —
    /// so the busiest collaborator leads and the order is deterministic. People with
    /// zero matched meetings are kept (a 0-bar card surfaces "enrolled but unseen").
    static func aggregate(voiceprintNames: [String], mdFiles: [URL]) -> [Person] {
        // Seeding now needs the names out of every transcript up front, so parse
        // first and hand the whole set to the one accumulation rule below.
        aggregate(voiceprintNames: voiceprintNames,
                  parsed: mdFiles.compactMap { TranscriptArchive.parse($0) })
    }

    /// Same as `aggregate` but over already-parsed transcripts — the unit-test seam
    /// (build fixtures in memory, no temp-file dance required) and reused by the URL
    /// path above so both routes share one accumulation rule.
    static func aggregate(voiceprintNames: [String], parsed: [TranscriptArchive.Parsed]) -> [Person] {
        var seen = Set<String>()
        var people: [String: Person] = [:]
        // Seed from enrolled voiceprints AND from every name the transcripts already
        // carry, so naming a speaker is enough to put them on the dashboard. Parse
        // keeps un-renamed "화자 N" and the 미확인 bucket out of `names`, so this can
        // only ever surface real, user-named people.
        for raw in voiceprintNames + parsed.flatMap({ $0.names.values }) {
            let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty, seen.insert(n).inserted else { continue }
            people[n] = Person(name: n)
        }
        guard !people.isEmpty else { return [] }
        for p in parsed { accumulate(into: &people, parsed: p) }
        return people.values.sorted {
            $0.totalTalk != $1.totalTalk ? $0.totalTalk > $1.totalTalk
                                         : $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    /// Fold one parsed transcript into the running per-person totals. A person counts
    /// the meeting once (their name is a value in `names`); talk-time sums every line
    /// whose speaker id maps to their name. A name appearing under multiple ids in one
    /// file (shouldn't happen, but defensive) still counts the meeting once.
    private static func accumulate(into people: inout [String: Person],
                                   parsed: TranscriptArchive.Parsed) {
        // name → set of speaker ids carrying that name in THIS file.
        var idsForName: [String: Set<Int>] = [:]
        for (id, name) in parsed.names {
            idsForName[name, default: []].insert(id)
        }
        for (name, ids) in idsForName {
            guard people[name] != nil else { continue }   // not an enrolled person
            var talk = 0.0
            var lineN = 0
            for line in parsed.lines where ids.contains(line.speaker) {
                talk += max(0, line.end - line.start)
                lineN += 1
            }
            people[name]!.meetings += 1
            people[name]!.totalTalk += talk
            people[name]!.lineCount += lineN
        }
    }
}
