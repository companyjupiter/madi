// WorkspaceRetrieval.swift — cross-document lexical retrieval: "ask across ALL
// meetings". Retrieval.swift answers over ONE transcript's lines; this is its
// workspace-scoped sibling — it parses every archived .md in the workspace,
// scores each line by keyword overlap with the question, and collects the
// highest-scoring lines across ALL meetings up to a char budget, each tagged
// with the meeting (file) it came from. The DNA3 engine context is ~1024
// tokens, so we can't feed N whole meetings; we feed the question-relevant
// excerpts, grounded in REAL lines from the right meetings.
//
// Pure (Foundation only) so it's unit-tested without the live engine. Reuses
// Retrieval.keywords (same interrogative-drop + Korean particle-stem rules) and
// TranscriptArchive.parse (the exact inverse of Exporters.markdown), so a query
// matches a "김부장:" line whether the user typed "김부장이" or "김부장".

import Foundation

enum WorkspaceRetrieval {

    /// For each `.md` URL: parse it back into speaker-attributed lines, score
    /// every line by `Retrieval.keywords` overlap with `query`, and globally rank
    /// all scoring lines across every meeting. Returns the top lines whose
    /// combined characters fit `budget`, each paired with its meeting (file) name.
    /// Unparseable / unreadable files are skipped gracefully. Pure + deterministic:
    /// ties break by (meeting name, original line order) so the result is stable.
    static func relevantExcerpts(_ query: String, mdFiles: [URL], budget: Int) -> [(meeting: String, text: String)] {
        let kws = Retrieval.keywords(query)
        guard !kws.isEmpty, budget > 0 else { return [] }

        struct Scored {
            let meeting: String   // .md base name (no extension) — the meeting title
            let order: Int        // line index within its meeting (stable tie-break)
            let text: String      // "이름: 발언" — speaker-attributed, like SummaryEngine input
            let score: Int        // keyword-overlap count
        }

        func scoreLine(_ line: String) -> Int {
            let low = line.lowercased()
            return kws.reduce(0) { $0 + (low.contains($1) ? 1 : 0) }
        }

        var candidates: [Scored] = []
        // Sort the input files so the global ranking is deterministic regardless of
        // the directory-walk order the caller passes in.
        let files = mdFiles.sorted { $0.path < $1.path }
        for url in files {
            guard let parsed = TranscriptArchive.parse(url) else { continue }   // skip unparseable
            let meeting = url.deletingPathExtension().lastPathComponent
            for (i, line) in parsed.lines.enumerated() {
                let who = SpeakerID.display(line.speaker, names: parsed.names, fallback: "화자\(line.speaker)")
                let text = "\(who): \(line.text)"
                let s = scoreLine(text)
                if s > 0 { candidates.append(Scored(meeting: meeting, order: i, text: text, score: s)) }
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Highest score first; ties → (meeting name, in-meeting order) for stability.
        let ranked = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.meeting != $1.meeting { return $0.meeting < $1.meeting }
            return $0.order < $1.order
        }

        var picked: [Scored] = []
        var len = 0
        for c in ranked {
            // " / " separator joins excerpts downstream (SummaryEngine.transcriptOneLine),
            // so budget against text.count + the 3-char joiner, like Retrieval.relevantLines.
            if len + c.text.count + 3 > budget { continue }
            picked.append(c); len += c.text.count + 3
        }
        guard !picked.isEmpty else { return [] }

        // Re-group by meeting (meeting name, then in-meeting order) so excerpts from
        // the same meeting read together and chronologically — clearer for the LLM
        // than score order, and keeps the output deterministic.
        return picked
            .sorted { $0.meeting != $1.meeting ? $0.meeting < $1.meeting : $0.order < $1.order }
            .map { (meeting: $0.meeting, text: $0.text) }
    }
}
