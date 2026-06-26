// DictationFormatting.swift — Foundation-only seams for system-wide dictation.
//
// Two pure concerns, deliberately AppKit-free so they unit-test headlessly:
//
//  1. `DictationText` — turns the raw word stream the engine emits (one token at
//     a time, leading-space rules identical to PreviewEngine) into the single
//     clean string we drop into the frontmost app. Whisper hands back tokens
//     like ["안녕", "하세요", ".", "Hello", "world"]; the UI wants
//     "안녕하세요. Hello world" with sane spacing around punctuation and CJK.
//
//  2. `PasteboardSwap<P>` — a save→set→restore guard over an abstract pasteboard
//     so a dictation never permanently clobbers the user's clipboard. The real
//     NSPasteboard lives behind the `PasteboardBackend` protocol; tests inject a
//     fake one. The changeCount guard is the sole defense against a second
//     dictation (or any app) writing the pasteboard mid-swap — if the count
//     moved unexpectedly we skip the restore rather than overwrite fresh data.

import Foundation

// MARK: - Text assembly

/// Joins the engine's per-word token stream into one insertion string using the
/// same spacing heuristic the live caption path uses (no space before closing
/// punctuation; no space between adjacent CJK glyphs the tokenizer already split).
public enum DictationText {

    /// Characters that must NOT be preceded by a space when they start a token.
    private static let noLeadingSpace: Set<Character> = [
        ",", ".", "!", "?", "…", ":", ";", ")", "]", "}",
        "”", "’", "」", "』", "》", "〉",
        // CJK punctuation
        "，", "。", "！", "？", "、", "：", "；", "）", "」", "』",
    ]

    /// Build the final string. `words` is the raw token list in emit order.
    public static func assemble(_ words: [String]) -> String {
        var out = ""
        for raw in words {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if out.isEmpty {
                out = t
                continue
            }
            let needsSpace = t.first.map { !noLeadingSpace.contains($0) } ?? true
            && !endsWithOpenBracket(out)
            && !(isCJK(out.last) && isCJK(t.first))   // CJK run: tokenizer split, no space
            if needsSpace { out += " " }
            out += t
        }
        return out
    }

    private static func endsWithOpenBracket(_ s: String) -> Bool {
        guard let c = s.last else { return false }
        return "([{“‘「『《〈".contains(c)
    }

    /// CJK ranges (Hangul, Hiragana, Katakana, CJK Unified) — between two such
    /// glyphs the engine's split is artificial, so we don't reintroduce a space.
    public static func isCJK(_ ch: Character?) -> Bool {
        guard let ch = ch, let s = ch.unicodeScalars.first else { return false }
        let v = s.value
        return (0xAC00...0xD7A3).contains(v)   // Hangul syllables
            || (0x1100...0x11FF).contains(v)   // Hangul jamo
            || (0x3040...0x30FF).contains(v)   // Hiragana + Katakana
            || (0x4E00...0x9FFF).contains(v)   // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(v)   // CJK Ext A
    }
}

// MARK: - Pasteboard guard (abstract over NSPasteboard)

/// Minimal surface of NSPasteboard the swap needs. The app supplies an adapter
/// over the real `.general`; tests supply an in-memory fake.
public protocol PasteboardBackend: AnyObject {
    /// Monotonic counter bumped on every external write (NSPasteboard semantics).
    var changeCount: Int { get }
    func readString() -> String?
    /// Clears and writes `s`; concrete impls must bump `changeCount`.
    func writeString(_ s: String)
    /// Clears all contents (used when the original had no string).
    func clear()
}

/// Save → set → restore around one insertion, defended by a changeCount guard.
///
/// Lifecycle per dictation:
///   let swap = PasteboardSwap(backend)
///   swap.stash()                 // remember current string + changeCount
///   swap.set(textToInsert)       // backend now holds the dictation
///   …caller posts ⌘V…
///   swap.restore()               // put the user's clipboard back (guarded)
///
/// `restore()` only writes back if the pasteboard's changeCount equals the value
/// right after our own `set()` — i.e. nobody (no second dictation, no other app)
/// touched it in between. Otherwise we leave the newer content alone.
public final class PasteboardSwap<P: PasteboardBackend> {
    private let backend: P
    private var saved: String??          // outer optional = "did we stash yet"
    private var countAfterSet: Int?

    public init(_ backend: P) { self.backend = backend }

    /// Remember what's currently on the pasteboard so we can put it back.
    public func stash() {
        saved = .some(backend.readString())
    }

    /// Place the dictation text on the pasteboard and record the resulting count.
    public func set(_ text: String) {
        backend.writeString(text)
        countAfterSet = backend.changeCount
    }

    /// Returns true if the count is what we left it at (safe to restore).
    public var isUnchangedSinceSet: Bool {
        guard let c = countAfterSet else { return false }
        return backend.changeCount == c
    }

    /// Put the user's original clipboard back, but only if nothing else wrote it
    /// since our `set()`. No-op (and returns false) if a race was detected or we
    /// never stashed.
    @discardableResult
    public func restore() -> Bool {
        guard let original = saved else { return false }   // outer optional = "did we stash"
        guard isUnchangedSinceSet else { return false }     // someone else won the race
        if let s = original { backend.writeString(s) } else { backend.clear() }
        return true
    }
}
