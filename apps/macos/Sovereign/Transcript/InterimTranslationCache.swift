import Foundation

/// O3 — INTERIM TRANSLATION REUSE.
///
/// During a live session the in-progress (interim) caption is debounce-translated
/// by the DNA3 LLM so a provisional translation appears right after you speak.
/// When the recognition window closes the SAME text is committed as a stable line
/// and would normally be re-queued for a fresh translation turn — duplicate work
/// the LLM already did moments ago.
///
/// This cache remembers, per session, the most-recent interim source texts and
/// their per-language translations, keyed by the SAME normalization the engine
/// applies to a source string (`TranslateEngine.translate` collapses newlines to
/// spaces and trims). When a stable line's normalized text hits the cache, the
/// committed translation is reused verbatim and no LLM turn is queued.
///
/// Correctness-conservative by construction:
///   • Matches ONLY exact-or-normalized source text (no fuzzy/substring matching).
///   • Bounded LRU (default 15) — a long meeting can't grow the map unbounded.
///   • Must be cleared on EVERY session boundary (reset/stop/finalize) so a
///     translation from meeting A can never be assigned to a line in meeting B.
///
/// Pure Foundation (no SwiftUI/AppKit) so it is unit-testable headless.
public struct InterimTranslationCache {

    /// Bound on distinct interim source texts retained. A typical meeting has only
    /// a handful of distinct in-flight sentences before each is committed, so a
    /// small bound comfortably covers more than one session's worth of in-flight
    /// text while keeping the map trivially small.
    public let capacity: Int

    /// Insertion/usage order, oldest first — the LRU eviction queue. Holds the same
    /// normalized keys present in `store`.
    private var order: [String] = []

    /// normalized-source → (lang → translation).
    private var store: [String: [String: String]] = [:]

    public init(capacity: Int = 15) {
        self.capacity = max(1, capacity)
    }

    /// Mirror of the engine's source normalization (`TranslateEngine.translate`):
    /// collapse newlines to spaces, then trim surrounding whitespace/newlines.
    /// Returns `nil` for text that normalizes to empty (never cached — the engine
    /// skips empty sources too).
    public static func normalize(_ text: String) -> String? {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.isEmpty ? nil : oneLine
    }

    /// Record the per-language translations for an interim source. A non-empty
    /// `translations` map replaces any prior entry for the same normalized key and
    /// marks it most-recently-used. Empty maps and empty sources are ignored.
    public mutating func put(_ source: String, _ translations: [String: String]) {
        guard !translations.isEmpty, let key = Self.normalize(source) else { return }
        if store[key] == nil {
            order.append(key)
        } else {
            touch(key)
        }
        // Merge so a key that accumulates languages across debounce turns keeps the
        // union rather than dropping previously-cached targets.
        store[key, default: [:]].merge(translations) { _, new in new }
        evictIfNeeded()
    }

    /// Look up the cached translations for a source text (exact-or-normalized).
    /// A hit marks the key most-recently-used. Returns `nil` on miss.
    public mutating func get(_ source: String) -> [String: String]? {
        guard let key = Self.normalize(source), let hit = store[key] else { return nil }
        touch(key)
        return hit
    }

    /// Non-mutating peek (no LRU update) — handy for tests/inspection.
    public func peek(_ source: String) -> [String: String]? {
        guard let key = Self.normalize(source) else { return nil }
        return store[key]
    }

    /// Drop everything. MUST be called on every session boundary to prevent
    /// cross-meeting translation bleed.
    public mutating func clear() {
        order.removeAll()
        store.removeAll()
    }

    /// Current number of distinct cached source texts.
    public var count: Int { store.count }

    public var isEmpty: Bool { store.isEmpty }

    // MARK: - LRU bookkeeping

    private mutating func touch(_ key: String) {
        if let i = order.firstIndex(of: key) {
            order.remove(at: i)
        }
        order.append(key)
    }

    private mutating func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            store.removeValue(forKey: oldest)
        }
    }
}
