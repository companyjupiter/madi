// GlossaryStore.swift — the user's PERSONAL VOCABULARY: domain terms / names the
// ASR keeps mis-hearing, learned from the corrections the user makes in the
// transcript editor over many meetings. Pure (Foundation only) so it's unit-
// tested without the live engine; persisted via UserDefaults like EditorSettings.
//
// Model: a flat map  misheard-token → corrected-token  with a hit count. When the
// user edits a line, PersonalVocabulary.diff() pairs the changed tokens and feeds
// them here via learn(); on a future live/file line, PersonalVocabulary.correctLine()
// looks each low-confidence word up (exact OR phonetic) and substitutes the term.
//
// Upgrade-safe decode (decodeIfPresent) so a blob saved before a new field existed
// loads with defaults instead of throwing keyNotFound (which would wipe the user's
// whole learned vocabulary).

import Foundation

/// One learned correction: the token the ASR produced → the token the user meant,
/// plus how many times the user has confirmed it (confidence in the rule).
struct GlossaryEntry: Codable, Equatable {
    var wrong: String        // normalized misheard token (lowercased, particle/punct-stripped)
    var right: String        // the user's corrected token (as typed, display form preserved)
    var hits: Int            // how many times this correction has been learned (rule strength)

    init(wrong: String, right: String, hits: Int = 1) {
        self.wrong = wrong; self.right = right; self.hits = hits
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wrong = try c.decodeIfPresent(String.self, forKey: .wrong) ?? ""
        right = try c.decodeIfPresent(String.self, forKey: .right) ?? ""
        hits = try c.decodeIfPresent(Int.self, forKey: .hits) ?? 1
    }
}

/// The persistent personal glossary. Keyed by the normalized `wrong` token so the
/// same mishearing learned twice reinforces one rule (hits++) rather than dupes.
struct Glossary: Codable, Equatable {
    private var schemaVersion = 2
    /// Master gate — auto-correction is OFF by default (a wrong substitution
    /// corrupts text), so the user opts in. Learning still happens silently when
    /// off, so flipping it on starts working immediately.
    var enabled = false
    /// Don't auto-substitute until a rule has been confirmed this many times — a
    /// single accidental edit shouldn't rewrite future transcripts.
    var minHits = 2
    /// wrong-token → entry. The token is the normalized key (== entry.wrong).
    var entries: [String: GlossaryEntry] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = 2
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let savedMinHits = try c.decodeIfPresent(Int.self, forKey: .minHits) ?? 1
        // v1 shipped an unsafe one-edit activation default. Migration raises the
        // gate without deleting personal data; the second confirmation activates it.
        minHits = version < 2 ? max(2, savedMinHits) : max(1, savedMinHits)
        entries = try c.decodeIfPresent([String: GlossaryEntry].self, forKey: .entries) ?? [:]
    }

    /// Learn (or reinforce) one correction. `wrong`/`right` are normalized by the
    /// caller (PersonalVocabulary.normalize). Self-corrections (wrong == right) and
    /// empty tokens are ignored. If a prior rule mapped the same `wrong` to a
    /// DIFFERENT `right`, the newest correction wins but inherits the hit count + 1
    /// (the user changed their mind; trust the latest mapping at least as much).
    mutating func learn(wrong: String, right: String) {
        guard !wrong.isEmpty, !right.isEmpty, wrong != right else { return }
        if var e = entries[wrong] {
            if e.right == right { e.hits += 1 } else { e.right = right; e.hits += 1 }
            entries[wrong] = e
        } else {
            entries[wrong] = GlossaryEntry(wrong: wrong, right: right, hits: 1)
        }
    }

    /// The active rules (hits ≥ minHits), used by the matcher. Returned as a plain
    /// array so the matcher can also do phonetic (non-exact) lookups over them.
    var activeEntries: [GlossaryEntry] {
        entries.values.filter { $0.hits >= max(1, minHits) }.sorted { $0.wrong < $1.wrong }
    }

    /// Exact-key lookup for a normalized token (the fast path before phonetic).
    func exact(_ wrongKey: String) -> GlossaryEntry? {
        guard let e = entries[wrongKey], e.hits >= max(1, minHits) else { return nil }
        return e
    }

    mutating func clear() { entries.removeAll() }
    mutating func forget(_ wrongKey: String) { entries.removeValue(forKey: wrongKey) }

    // ── persistence (UserDefaults, mirrors EditorSettings) ───────────────────────
    private static let key = "personalGlossary"
    static func load(_ defaults: UserDefaults = .standard) -> Glossary {
        guard let d = defaults.data(forKey: key),
              let g = try? JSONDecoder().decode(Glossary.self, from: d) else { return .init() }
        return g
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }
}
