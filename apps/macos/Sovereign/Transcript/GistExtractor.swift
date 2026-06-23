// GistExtractor.swift — derive a one-line "gist" preview for a saved transcript
// .md so the workspace explorer can show what a meeting was about without the
// user opening it. Pure (Foundation only) → unit-tested.
//
// Input is the exact document Exporters.markdown writes:
//
//     # Transcript
//
//     ## 회의 요약
//     <summary block: [요약]/[액션]/[결정] …>
//     ---
//     > *기울임* 표시된 단어는 …            (legend, skipped)
//     - **[mm:ss] Who** body …             (transcript bullets)
//
// Gist priority (first that yields text wins):
//   1. The first decision line ([결정]) — the most "what did we agree" signal.
//   2. The first summary line ([요약] / 회의 요약 block first sentence).
//   3. Fallback: the first transcript bullet's spoken text (speaker stripped).
// Returns nil only when nothing parseable is present (empty / non-transcript md).
//
// A GistCache (also Foundation-only) memoises the result keyed by file URL +
// modification time so the explorer never re-parses on every SwiftUI render and
// re-reads only when the file actually changes on disk.

import Foundation
import os

enum GistExtractor {

    /// Max characters before the gist is truncated with an ellipsis. Tuned for a
    /// single explorer row at the default column width.
    static let maxLength = 80

    /// Extract a one-line gist from a transcript markdown document. See file
    /// header for the priority order. Returns nil when nothing parseable exists.
    static func extractGist(from text: String) -> String? {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Reuse SummaryDeck's tolerant section parser on the summary block (the
        // text between "## 회의 요약" and the "---" separator). Keeps gist
        // parsing identical to how the deck reads the same block.
        if let summary = summaryBlock(rows) {
            let sections = SummaryDeck.parseSections(summary)
            // 1. decision line — strongest signal.
            if let decision = firstLine(in: sections, titledContaining: "결정") {
                return clip(decision)
            }
            // 2. summary line.
            if let gist = firstLine(in: sections, titledContaining: "요약") {
                return clip(gist)
            }
            // 2b. any section's first line (model may label it differently).
            for s in sections {
                if let first = s.paras.first ?? s.bullets.first, !first.isEmpty {
                    return clip(first)
                }
            }
        }

        // 3. fallback — first transcript bullet, speaker label stripped.
        if let spoken = firstBulletSpeech(rows) { return clip(spoken) }

        return nil
    }

    // ── summary block isolation ───────────────────────────────────────────────

    /// Pull the lines between the `## 회의 요약` heading and the `---` rule (or
    /// the first transcript bullet, whichever comes first). nil when absent.
    private static func summaryBlock(_ rows: [String]) -> String? {
        guard let start = rows.firstIndex(where: { isSummaryHeading($0) }) else { return nil }
        var collected: [String] = []
        for row in rows[(start + 1)...] {
            if row == "---" { break }
            if row.hasPrefix("- **[") { break }          // reached transcript bullets
            collected.append(row)
        }
        let joined = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func isSummaryHeading(_ line: String) -> Bool {
        let low = line.lowercased()
        // "## 회의 요약", "# 회의 요약", "## summary" …
        guard low.hasPrefix("#") else { return false }
        let body = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
        return body.contains("요약") || body.contains("summary") || body.contains("회의")
    }

    // ── section helpers ───────────────────────────────────────────────────────

    private static func firstLine(in sections: [SummaryDeck.Section],
                                  titledContaining needle: String) -> String? {
        for s in sections where s.title.contains(needle) {
            if let line = s.bullets.first ?? s.paras.first, !line.isEmpty { return line }
        }
        return nil
    }

    // ── transcript fallback ───────────────────────────────────────────────────

    /// First `- **[mm:ss] Who** body` line → the spoken body, speaker stripped,
    /// confidence-italics and overlap markers removed.
    private static func firstBulletSpeech(_ rows: [String]) -> String? {
        for row in rows where row.hasPrefix("- **[") {
            // body starts after the closing "** " of the bold speaker label.
            guard let close = row.range(of: "** ") else { continue }
            var body = String(row[close.upperBound...])
            // drop overlap markers "⟨+… 겹침⟩".
            if let mark = body.range(of: "⟨") { body = String(body[..<mark.lowerBound]) }
            body = body.replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { return body }
        }
        return nil
    }

    // ── truncation ────────────────────────────────────────────────────────────

    /// Collapse internal whitespace and truncate to `maxLength` with an ellipsis.
    static func clip(_ s: String, max: Int = maxLength) -> String {
        let collapsed = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if collapsed.count <= max { return collapsed }
        let head = collapsed.prefix(max).trimmingCharacters(in: .whitespaces)
        return head + "…"
    }
}

/// Memoises gists keyed by file URL + on-disk modification time. Foundation-only
/// and self-contained: a `.shared` instance lets the explorer's per-row view
/// pull a cached gist (re-reading the file only when its mtime changes) without
/// any state plumbed through the session.
///
/// Thread-safe: GistView reads it from `Task.detached` (a background thread), so
/// the `store` dictionary is guarded by an unfair lock. File I/O is deliberately
/// performed OUTSIDE the lock — only the dictionary check/insert are serialized —
/// so a slow disk read never blocks other rows' lookups.
final class GistCache: @unchecked Sendable {

    /// Shared instance so a single SwiftUI integration line wires the whole
    /// feature (the view reaches GistExtractor + GistCache through this).
    static let shared = GistCache()

    private struct Entry { let mtime: Date?; let gist: String? }
    private let store = OSAllocatedUnfairLock<[URL: Entry]>(initialState: [:])

    init() {}

    /// Cached gist for a transcript .md. Reads + parses the file only when no
    /// entry exists or the file's modification time changed since last read.
    /// Returns nil when the file is missing/unreadable or has no parseable gist.
    func gist(for url: URL) -> String? {
        let mtime = Self.modificationDate(of: url)
        // Fast path under the lock: serve a fresh memoised entry.
        if let hit = store.withLock({ s -> String?? in
            if let cached = s[url], cached.mtime == mtime { return .some(cached.gist) }
            return nil
        }) { return hit }
        // Miss or stale: read + parse OFF the lock so disk I/O doesn't serialize rows.
        let gist = (try? String(contentsOf: url, encoding: .utf8)).flatMap(GistExtractor.extractGist)
        // Re-acquire only to publish. A concurrent writer for the same URL is benign
        // (both computed the same mtime-keyed value); last write wins.
        store.withLock { $0[url] = Entry(mtime: mtime, gist: gist) }
        return gist
    }

    /// Drop all memoised gists — call after a workspace reload/switch so a moved
    /// or rewritten file is re-read.
    func invalidateAll() { store.withLock { $0.removeAll() } }

    /// Drop one file's entry (e.g. after re-saving that transcript).
    func invalidate(_ url: URL) { store.withLock { $0[url] = nil } }

    private static func modificationDate(of url: URL) -> Date? {
        // FileManager attributes, NOT url.resourceValues — URL caches resource
        // values, so a file rewritten in place can report a stale mtime and the
        // cache would never re-read. FileManager always stats the path fresh.
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
