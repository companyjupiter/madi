// TranscriptFind.swift — pure ⌘F match logic for the transcript find bar. Given
// each line's display text + a query, returns the ids of matching lines in
// document order (case-insensitive substring). No UI, no highlighting (that
// happens in TranscriptView.attributed) — just the navigable match list, so the
// find bar's count/next/prev stay testable.

import Foundation

enum TranscriptFind {
    /// Ids of lines containing `query` (case-insensitive), in the input order.
    /// A blank/whitespace query matches nothing.
    static func matchingLineIDs(_ lines: [(id: UUID, text: String)], query: String) -> [UUID] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return lines.compactMap { $0.text.range(of: q, options: .caseInsensitive) != nil ? $0.id : nil }
    }
}
