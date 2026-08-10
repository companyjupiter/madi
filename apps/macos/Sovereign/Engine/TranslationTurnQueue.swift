// TranslationTurnQueue.swift — pure scheduling policy for live translation.
//
// The DNA process is serial, so queue order is the product behavior: committed
// captions must beat disposable interim previews, and a newer revision must not
// leave an older pending revision consuming Metal time. Kept separate from the
// process driver so these invariants are headless-testable.

import Foundation

enum TranslationTurnKind: Equatable {
    case interim
    case committed
}

struct TranslationTurn: Equatable {
    let id: UUID
    let lang: String
    let source: String
    let prompt: String
    let prefix: String?
    let body: String?
    var retries: Int
    let kind: TranslationTurnKind
    /// P10-1: this interim turn holds the starvation-guarantee slot. It bypasses
    /// the committed block, survives a committed turn's interim eviction, and is
    /// served before pending committed work — once, so the caption cannot be
    /// starved for longer than the guarantee interval under a committed backlog.
    var reserved: Bool = false
}

struct TranslationQueueEnqueueResult {
    let accepted: Bool
    let displaced: [TranslationTurn]
}

struct TranslationTurnQueue {
    private(set) var turns: [TranslationTurn] = []

    var count: Int { turns.count }
    var isEmpty: Bool { turns.isEmpty }
    var hasCommitted: Bool { turns.contains { $0.kind == .committed } }

    /// Enqueue one target turn. A committed turn evicts all pending interim work;
    /// a newer revision replaces an older pending turn for the same line+language.
    /// Interim work is rejected while committed work is queued or in flight.
    mutating func enqueue(_ turn: TranslationTurn, blockInterim: Bool = false,
                          replaceExisting: Bool = true)
        -> TranslationQueueEnqueueResult {
        if turn.kind == .interim, !turn.reserved, blockInterim || hasCommitted {
            return TranslationQueueEnqueueResult(accepted: false, displaced: [])
        }

        var displaced: [TranslationTurn] = []
        if turn.kind == .committed {
            // A reserved interim survives: evicting it would re-open the
            // starvation window the reservation exists to close.
            displaced.append(contentsOf: removeAll { $0.kind == .interim && !$0.reserved })
        }
        if !replaceExisting,
           turns.contains(where: { $0.id == turn.id && $0.lang == turn.lang }) {
            return TranslationQueueEnqueueResult(accepted: false, displaced: displaced)
        }
        displaced.append(contentsOf: removeAll { $0.id == turn.id && $0.lang == turn.lang })
        turns.append(turn)
        return TranslationQueueEnqueueResult(accepted: true, displaced: displaced)
    }

    /// Highest semantic priority first; newest-first within a lane preserves the
    /// existing live-caption behavior during a backlog.
    var next: TranslationTurn? {
        if let i = turns.lastIndex(where: { $0.reserved }) { return turns[i] }
        if let i = turns.lastIndex(where: { $0.kind == .committed }) { return turns[i] }
        return turns.last
    }

    mutating func popNext() -> TranslationTurn? {
        if let i = turns.lastIndex(where: { $0.reserved }) { return turns.remove(at: i) }
        if let i = turns.lastIndex(where: { $0.kind == .committed }) {
            return turns.remove(at: i)
        }
        return turns.popLast()
    }

    /// Shed oldest queued work to a live cap. The caller decides whether shed
    /// turns need stop-time backfill; superseded turns use `displaced` instead.
    mutating func shedOldest(to maxCount: Int) -> [TranslationTurn] {
        guard maxCount > 0, turns.count > maxCount else { return [] }
        let excess = turns.count - maxCount
        let shed = Array(turns.prefix(excess))
        turns.removeFirst(excess)
        return shed
    }

    mutating func removeAll() { turns.removeAll() }

    private mutating func removeAll(where predicate: (TranslationTurn) -> Bool)
        -> [TranslationTurn] {
        var removed: [TranslationTurn] = []
        turns.removeAll { turn in
            if predicate(turn) {
                removed.append(turn)
                return true
            }
            return false
        }
        return removed
    }
}

/// Conservative output guard for the smaller realtime model. It never rewrites
/// wording: it only removes control-token leakage / exact consecutive loops and
/// identifies replies that are observably in the wrong script so the engine can
/// regenerate them with a source→target-specific prompt.
enum TranslationOutputPolicy {
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // DNA has thinking disabled, but the 2B quant can still emit a stray
        // `<think>` frame. Prefer the answer after the final closing tag; remove
        // a complete/incomplete frame when no answer follows it.
        if let close = text.range(of: "</think>", options: .backwards) {
            let suffix = text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty { text = suffix }
            else { text.removeSubrange(close) }
        }
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }

        return collapseConsecutiveSentences(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldRetry(_ output: String, source: String, target: String) -> Bool {
        let cleaned = clean(output)
        guard !cleaned.isEmpty else { return !output.isEmpty }
        if norm(cleaned) == norm(source) { return true }
        return containsForbiddenScript(cleaned, target: target)
    }

    static func sourceLanguageName(for text: String) -> String {
        var hangul = 0, kana = 0, han = 0
        for scalar in text.unicodeScalars {
            if isHangul(scalar.value) { hangul += 1 }
            else if isKana(scalar.value) { kana += 1 }
            else if isHan(scalar.value) { han += 1 }
        }
        if hangul > 0 { return "Korean" }
        if kana > 0 { return "Japanese" }
        if han > 0 { return "Chinese" }
        return "English"
    }

    private static func containsForbiddenScript(_ text: String, target: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch target {
            case "Korean":
                if isKana(value) { return true }
            case "Japanese":
                if isHangul(value) { return true }
            case "Chinese":
                if isHangul(value) || isKana(value) { return true }
            case "English":
                if isHangul(value) || isKana(value) || isHan(value) { return true }
            default:
                break
            }
        }
        return false
    }

    private static func collapseConsecutiveSentences(_ text: String) -> String {
        let terminators = CharacterSet(charactersIn: ".!?。！？")
        var units: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if terminators.contains(scalar) {
                appendNonempty(current, to: &units)
                current = ""
            }
        }
        appendNonempty(current, to: &units)

        var result: [String] = []
        var i = 0
        while i < units.count {
            var end = i + 1
            while end < units.count, norm(units[end]) == norm(units[i]) { end += 1 }
            // Preserve a deliberate two-sentence repetition ("Yes. Yes."); only
            // collapse the 3+ exact loops observed in 2B runaway generation.
            if end - i >= 3 { result.append(units[i]) }
            else { result.append(contentsOf: units[i..<end]) }
            i = end
        }
        return result.joined(separator: " ")
    }

    private static func appendNonempty(_ value: String, to units: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        units.append(trimmed)
    }

    private static func norm(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.。!?！？\"'"))
    }

    private static func isHangul(_ v: UInt32) -> Bool {
        (0x1100...0x11ff).contains(v) || (0x3130...0x318f).contains(v) ||
        (0xa960...0xa97f).contains(v) || (0xac00...0xd7af).contains(v) ||
        (0xd7b0...0xd7ff).contains(v)
    }

    private static func isKana(_ v: UInt32) -> Bool {
        (0x3040...0x30ff).contains(v) || (0x31f0...0x31ff).contains(v)
    }

    private static func isHan(_ v: UInt32) -> Bool {
        (0x3400...0x4dbf).contains(v) || (0x4e00...0x9fff).contains(v) ||
        (0xf900...0xfaff).contains(v)
    }
}
