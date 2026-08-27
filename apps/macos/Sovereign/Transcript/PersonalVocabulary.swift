// PersonalVocabulary.swift — the matching layer over the persistent Glossary.
// Two pure jobs (Foundation only, fully unit-testable):
//
//   1. LEARN  — diff(before:after:) pairs the tokens that changed when the user
//      edited a line, yielding (wrong → right) corrections to feed Glossary.learn().
//
//   2. APPLY  — correctLine(_:_:) walks an incoming line's words and substitutes any
//      LOW-CONFIDENCE word that an active glossary rule matches (exact key, or a
//      conservative phonetic match via Jaro-Winkler). Only Word.text is rewritten;
//      Word.id / timestamps / conf are untouched so async translations + line
//      identity (keyed by first-word id) survive intact.
//
// Defensiveness is the whole game — a false substitution corrupts the transcript:
//   · only words with conf < highConfFloor are eligible (a clearly-heard word is
//     trusted over the glossary),
//   · the misheard token must be ≥ minLen chars (don't rewrite "네"/"음"),
//   · phonetic matches require Jaro-Winkler ≥ phoneticFloor (high bar).
//
// Particle handling is allowlisted, never `dropLast()`: arbitrary truncation made
// 회의실/회의록 collide at 회의 and turned AWS into aw.

import Foundation

enum PersonalVocabulary {

    // ── tuning knobs (conservative by design) ────────────────────────────────────
    /// Only words the ASR was UNSURE about are eligible for substitution. A word at
    /// full confidence is trusted over the glossary (avoids rewriting correct text).
    static let highConfFloor = 0.8
    /// Don't touch tokens shorter than this — short Korean/English fillers ("네",
    /// "음", "uh") collide phonetically with everything.
    static let minLen = 3
    /// Phonetic acceptance bar for a non-exact match (Jaro-Winkler, 0…1). High so
    /// only near-homophones substitute.
    ///
    /// CALIBRATION (measured, not guessed): on SHORT Korean tokens Jaro-Winkler can
    /// NOT separate a true mishearing from a genuinely different word that shares a
    /// prefix — both score ~0.82 (소버림~소버린 = 0.822, but 회의록~회의실 = 0.822 too).
    /// So the phonetic path is deliberately reserved for LONGER tokens
    /// (≥ phoneticMinLen), where one-char ASR slips score ≥0.92 while unrelated words
    /// fall far below. Short-token corrections rely on the EXACT-key path instead
    /// (the user literally corrected that exact token before — certain, not guessed).
    static let phoneticFloor = 0.92
    /// Minimum token length for the phonetic (non-exact) path. Below this, only an
    /// exact key match substitutes — see the phoneticFloor calibration note.
    static let phoneticMinLen = 5

    // ── S4: decode-time biasing ─────────────────────────────────────────────────
    /// Cap on how many terms go into the engine's `PROMPT` context. The measured
    /// configuration used 22–36 terms per session; the prompt is encoded once and
    /// prepended to every decode, so an unbounded list would eat decoder context.
    static let maxBiasTerms = 32
    /// Byte-ish cap matching the measured prompt size.
    static let maxBiasChars = 900

    /// The vocabulary handed to the engine for decode-time biasing (`PROMPT`).
    ///
    /// Relevance is the shipping condition, not a nicety: measured 2026-08-27 on
    /// 60 FLEURS-ko utterances where the baseline had missed a rare word
    /// (docs/ENGINE_EVAL.md S4), a MATCHED glossary lifted recovery of those words
    /// 32.7% → 51.0% and CER 7.50% → 7.00%, but a deliberately MISMATCHED glossary
    /// of the same size left recovery flat (35.6%) and pushed CER to 7.97% — worse
    /// than shipping no glossary at all. So only CONFIRMED rules (hits ≥ minHits,
    /// i.e. the user corrected that word more than once) are eligible, strongest
    /// first, and the list is capped. Returns [] when the glossary is off.
    static func biasTerms(_ glossary: Glossary) -> [String] {
        guard glossary.enabled else { return [] }
        let confirmed = glossary.entries.values
            .filter { $0.hits >= glossary.minHits && $0.right.count >= minLen }
            // strongest rules first; `right` breaks ties so the list is deterministic
            .sorted { ($0.hits, $1.right) > ($1.hits, $0.right) }
        var seen = Set<String>(), out: [String] = [], chars = 0
        for e in confirmed {
            let term = e.right.trimmingCharacters(in: .whitespacesAndNewlines)
            // a term with whitespace would split into separate bias words engine-side
            guard !term.isEmpty, !term.contains(" "), seen.insert(term.lowercased()).inserted
            else { continue }
            guard chars + term.count + 1 <= maxBiasChars else { break }
            out.append(term); chars += term.count + 1
            if out.count >= maxBiasTerms { break }
        }
        return out
    }

    /// Lowercase + punctuation trim, then remove only a known Korean particle.
    static func normalize(_ raw: String) -> String {
        let t = surfaceForm(raw)
        return splitParticle(t).stem
    }

    /// Lowercased, punctuation-stripped surface form WITHOUT the trailing-particle
    /// strip — the full token as written. Used as one of the dual lookup keys.
    static func surfaceForm(_ raw: String) -> String {
        let punct = CharacterSet(charactersIn: ",.!?…\"'`’”“()-—·:; ")
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: punct)
            .lowercased()
    }

    /// Candidate keys: exact surface plus a stem only when an allowlisted particle
    /// is actually present. Lexemes such as 회의실/회의록/AWS remain distinct.
    static func normalizeKeys(_ raw: String) -> [String] {
        let surface = surfaceForm(raw)
        guard !surface.isEmpty else { return [] }
        var keys = [surface]
        let split = splitParticle(surface)
        if split.particle != nil, split.stem != surface { keys.append(split.stem) }
        return keys
    }

    /// Longest-first. A minimum two-character stem prevents short nouns such as
    /// 사과 from being interpreted as 사+과.
    private static let particles = [
        "한테서", "이라고", "으로", "에게", "에서", "부터", "까지", "처럼", "보다",
        "께서", "한테", "이랑", "라고", "은", "는", "이", "가", "을", "를", "와", "과",
        "의", "에", "께", "로", "도", "만", "랑",
    ]

    private static func splitParticle(_ surface: String) -> (stem: String, particle: String?) {
        for particle in particles where surface.hasSuffix(particle) {
            let stem = String(surface.dropLast(particle.count))
            if stem.count >= 2 { return (stem, particle) }
        }
        return (surface, nil)
    }

    // ── LEARN: diff an edit into (wrong → right) corrections ──────────────────────
    /// Pair the tokens that changed between the ASR text and the user's edit. Uses a
    /// positional zip over whitespace tokens: this captures the common case (one or
    /// a few words swapped in place) without a costly alignment, and stays
    /// conservative — only same-position tokens that differ become rules, and only
    /// when BOTH sides clear minLen (so punctuation/spacing tweaks don't pollute the
    /// glossary). Returns normalized (wrong, right) pairs ready for Glossary.learn.
    static func diff(before: String, after: String) -> [(wrong: String, right: String)] {
        let bs = tokens(before)
        let as_ = tokens(after)
        // Only learn when the edit is a same-length token swap (true substitution).
        // Length changes (inserted/deleted words) can't be positionally aligned
        // safely, so we skip them rather than risk garbage rules.
        guard bs.count == as_.count, !bs.isEmpty else { return [] }
        var out: [(wrong: String, right: String)] = []
        for (b, a) in zip(bs, as_) {
            let before = surfaceForm(b), after = surfaceForm(a)
            let bs = splitParticle(before), as_ = splitParticle(after)
            // When both sides carry the same particle, learn stem→stem. At apply
            // time the observed particle is reattached, so bare and inflected
            // future forms both remain grammatical.
            let shareParticle = bs.particle != nil && bs.particle == as_.particle
            let nb = shareParticle ? bs.stem : before
            let na = shareParticle ? as_.stem : after
            guard before != after, before.count >= minLen, !na.isEmpty else { continue }
            out.append((wrong: nb, right: na))
        }
        return out
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0.isWhitespace }).map(String.init)
    }

    // ── APPLY ─────────────────────────────────────────────────────────────────────
    //
    // `Word.text` and `Word.id` are BOTH immutable (`let`) in the app model, and a
    // line's identity == its FIRST word's id (translations + user edits are keyed by
    // it). So there are two distinct apply primitives, by pipeline stage:
    //
    //   · INCOMING (pre-grouping): correctIncomingText() rewrites the raw recognized
    //     STRING before SessionController constructs the Word. No Word exists yet →
    //     no id to preserve. This is the live path (SessionController.ingest).
    //
    //   · GROUPED (post-grouping): correctedLineText() returns the corrected DISPLAY
    //     string for an already-built Line WITHOUT mutating its Words — the integrator
    //     applies it non-destructively (e.g. via the existing editsByLine overlay,
    //     keyed by the stable line id), so Word ids and async translations survive.

    /// Correct a single recognized word STRING before it becomes a `Word`. Returns the
    /// (possibly) corrected text. `conf` is the engine's confidence for this word — a
    /// confident word (≥ highConfFloor) is trusted and returned unchanged. This is the
    /// live-ingest primitive (no Word/id exists yet, so nothing to preserve).
    static func correctIncomingText(_ raw: String, conf: Double, _ glossary: Glossary) -> String {
        guard glossary.enabled, conf < highConfFloor else { return raw }
        let rules = glossary.activeEntries
        guard !rules.isEmpty, let repl = match(raw, rules: rules, glossary: glossary) else { return raw }
        return preservingTrailingPunct(raw, replacement: repl)
    }

    /// Non-destructive: the corrected DISPLAY text for an already-grouped line, or nil
    /// if nothing changed (so the caller can skip writing an overlay). Only
    /// low-confidence words are eligible; `editedText` lines are left fully alone (the
    /// user already fixed them). Word ids/timestamps are untouched — the integrator
    /// stores the returned string as a line-id-keyed overlay, NOT by rebuilding Words.
    static func correctedLineText(_ line: Line, _ glossary: Glossary) -> String? {
        guard glossary.enabled, line.editedText == nil else { return nil }
        let rules = glossary.activeEntries
        guard !rules.isEmpty else { return nil }
        var changed = false
        var pieces: [String] = []
        for w in line.words {
            var text = w.text
            if w.conf < highConfFloor, let repl = match(w.text, rules: rules, glossary: glossary) {
                text = preservingTrailingPunct(w.text, replacement: repl)
                changed = true
            }
            pieces.append(text)
        }
        guard changed else { return nil }
        // Re-join with the same spacing convention as Line.joinedText.
        var s = ""
        for p in pieces {
            if !s.isEmpty, p.first.map({ !",.!?…".contains($0) }) ?? true { s += " " }
            s += p
        }
        return s
    }

    /// Find the corrected term for a raw word token, or nil. Exact key first (fast,
    /// certain), then a conservative phonetic pass over the active rules.
    static func match(_ raw: String, rules: [GlossaryEntry], glossary: Glossary) -> String? {
        let keys = normalizeKeys(raw)
        guard let primary = keys.first, primary.count >= minLen else { return nil }
        // 1) exact (either the normalized form or its particle-stripped stem) — the
        //    certain path: the user corrected this exact token before.
        let surface = surfaceForm(raw)
        let split = splitParticle(surface)
        for k in keys {
            if let e = glossary.exact(k) {
                if k == split.stem, let particle = split.particle,
                   !e.right.hasSuffix(particle) { return e.right + particle }
                return e.right
            }
        }
        // 2) phonetic — only for LONG tokens, where Jaro-Winkler separates a true
        //    mishearing (≥phoneticFloor) from unrelated prefix-sharers. Short tokens
        //    are intentionally NOT phonetically guessed (see calibration note).
        guard primary.count >= phoneticMinLen else { return nil }
        var best: (right: String, score: Double)? = nil
        for r in rules where r.wrong.count >= phoneticMinLen {
            let s = jaroWinkler(primary, r.wrong)
            if s >= phoneticFloor, best == nil || s > best!.score { best = (r.right, s) }
        }
        return best?.right
    }

    /// Re-attach the trailing punctuation that the original token carried (so a
    /// substitution inside a sentence keeps its comma/period), since the replacement
    /// is a bare term. Leading characters are not touched.
    private static func preservingTrailingPunct(_ original: String, replacement: String) -> String {
        let punct = Set(",.!?…\"'`’”“):;")
        var tail = ""
        for ch in original.reversed() {
            if punct.contains(ch) { tail = String(ch) + tail } else { break }
        }
        return replacement + tail
    }

    // ── Jaro-Winkler similarity (0…1) ─────────────────────────────────────────────
    /// Standard Jaro-Winkler. Works on Unicode scalars so Korean syllable blocks
    /// compare as whole characters (한 → 한). Returns 1.0 for identical strings,
    /// 0.0 when either is empty.
    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        let s1 = Array(a), s2 = Array(b)
        if s1.isEmpty || s2.isEmpty { return 0.0 }

        let matchDistance = max(s1.count, s2.count) / 2 - 1
        var s1Matches = [Bool](repeating: false, count: s1.count)
        var s2Matches = [Bool](repeating: false, count: s2.count)
        var matches = 0
        for i in 0..<s1.count {
            let lo = max(0, i - matchDistance)
            let hi = min(i + matchDistance + 1, s2.count)
            guard lo < hi else { continue }
            for j in lo..<hi where !s2Matches[j] && s1[i] == s2[j] {
                s1Matches[i] = true; s2Matches[j] = true; matches += 1; break
            }
        }
        guard matches > 0 else { return 0.0 }

        // transpositions
        var t = 0.0
        var k = 0
        for i in 0..<s1.count where s1Matches[i] {
            while !s2Matches[k] { k += 1 }
            if s1[i] != s2[k] { t += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(s1.count) + m / Double(s2.count) + (m - t / 2) / m) / 3

        // Winkler boost for a common prefix (up to 4 chars), p = 0.1
        var prefix = 0
        for i in 0..<min(4, min(s1.count, s2.count)) {
            if s1[i] == s2[i] { prefix += 1 } else { break }
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }
}
