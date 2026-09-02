// TranslateStreamParser.swift — incremental framing for the DNA3 translate
// engine's stdout. PURE logic (Foundation only) so it is unit-testable.
//
// Why this exists (T5, 2026-07-03): the engine already streams the reply
// TOKEN-BY-TOKEN (measured ~19 ms/token through the pipe — main.zig printToken
// writes unbuffered), but the old parser framed stdout by NEWLINE, and the
// reply's terminating '\n' only arrives as part of "\n[perf] generation: …".
// So the whole reply sat in the line buffer until the turn finished — the app
// threw away ~0.5-0.9 s of visible progress per turn. This parser frames by
// STATE instead: control lines by newline, reply bytes incrementally.
//
// Engine stdout shape per turn (verified by timestamped pipe capture):
//   "> [chat] N tokens, prefilling...\n"
//   "[perf] prefill: N tok in Xms (Y tok/s)\n"
//   <reply bytes, token by token, NO newline>          ← streamed as .replyDelta
//   "\n[perf] generation: N tok in Xms (Y tok/s)\n> "  ← completes the turn
//
// UTF-8 note: a token boundary can split a multi-byte character (Korean/kana
// BPE) — the decoder only surfaces the longest valid UTF-8 prefix and holds
// the partial tail bytes for the next chunk.

import Foundation

struct TranslateStreamParser {
    enum Event: Equatable {
        case ready
        case prefixReady(Int)
        /// "[caps] pfxcache fp" — the engine's capability tokens, printed once
        /// before READY (T1: `fp` = accepts a ` %%FP <text>` forced reply prefix).
        case capabilities([String])
        case replyDelta(String)      // full accumulated reply text so far (not a diff)
        case turnComplete(String)    // final reply text for the turn
    }

    private enum State { case control, reply, afterReplyNewline }

    private var buffer = Data()
    private var state: State = .control
    private var replyRaw = Data()
    private let preserveNewlines: Bool

    init(preserveNewlines: Bool = false) { self.preserveNewlines = preserveNewlines }

    private static let generationMarker = Data("[perf] generation".utf8)

    /// Feed a stdout chunk; returns the events it completes, in order.
    mutating func ingest(_ chunk: Data) -> [Event] {
        buffer.append(chunk)
        var events: [Event] = []
        loop: while true {
            switch state {
            case .control:
                guard let nl = buffer.firstIndex(of: 0x0A) else { break loop }
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let e = handleControl(lineData) { events.append(e) }

            case .reply:
                if let nl = buffer.firstIndex(of: 0x0A) {
                    replyRaw.append(buffer.subdata(in: buffer.startIndex..<nl))
                    buffer.removeSubrange(buffer.startIndex...nl)
                    state = .afterReplyNewline
                } else {
                    guard !buffer.isEmpty else { break loop }
                    replyRaw.append(buffer)
                    buffer.removeAll(keepingCapacity: true)
                    if let text = Self.decodeStablePrefix(replyRaw), !text.isEmpty {
                        events.append(.replyDelta(text))
                    }
                    break loop
                }

            case .afterReplyNewline:
                // The reply's '\n' either terminates the turn ("[perf] generation…"
                // follows) or was an intra-reply newline (defensive — the contract
                // is single-line). Decide once enough bytes are visible.
                let m = Self.generationMarker
                if buffer.count >= m.count {
                    if buffer.prefix(m.count) == m {
                        state = .control       // the control handler completes the turn
                    } else {
                        replyRaw.append(preserveNewlines ? 0x0A : 0x20)
                        state = .reply
                    }
                } else if buffer.firstIndex(of: 0x0A) != nil {
                    // a full line shorter than the marker — continuation
                    replyRaw.append(preserveNewlines ? 0x0A : 0x20)
                    state = .reply
                } else {
                    break loop                 // wait for more bytes
                }
            }
        }
        return events
    }

    private mutating func handleControl(_ lineData: Data) -> Event? {
        guard var s = String(data: lineData, encoding: .utf8) else { return nil }
        while s.hasPrefix(">") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if s == "READY" { return .ready }
        if s.hasPrefix("[caps] ") {
            return .capabilities(s.dropFirst(7).split(separator: " ").map(String.init))
        }
        if s.hasPrefix("PFX_OK ") {
            let fields = s.split(separator: " ")
            if fields.count >= 2, let slot = Int(fields[1]) { return .prefixReady(slot) }
        }
        if s.hasPrefix("[perf] prefill") {     // reply bytes follow
            state = .reply
            replyRaw.removeAll(keepingCapacity: true)
            return nil
        }
        if s.hasPrefix("[perf] generation") {  // turn done
            let text = (Self.decodeStablePrefix(replyRaw) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            replyRaw.removeAll(keepingCapacity: true)
            return .turnComplete(text)
        }
        return nil                             // banners / [chat] / [arch] / token[…]
    }

    /// Longest valid-UTF-8 prefix of `data` (holds back a split multi-byte tail).
    static func decodeStablePrefix(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        // walk back up to 3 bytes — a UTF-8 sequence is ≤4 bytes
        for back in 1...3 where data.count >= back {
            let d = data.subdata(in: data.startIndex..<data.index(data.endIndex, offsetBy: -back))
            if let s = String(data: d, encoding: .utf8) { return s }
        }
        return nil
    }
}

/// Per-line language routing for the bidirectional clinic scenario (T4):
/// detect a text's language by Unicode script so a Japanese line targets only
/// Korean and a Korean line only the patient's language — instead of every
/// line × every session target.
enum TranslateRouting {
    /// English language name for the dominant script, or nil when ambiguous.
    /// Rules: any kana → Japanese; hangul-dominant → Korean; han without kana
    /// or hangul → Chinese; latin-dominant → English.
    static func scriptLang(of text: String) -> String? {
        var hangul = 0, kana = 0, han = 0, latin = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF: kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        let scripted = hangul + kana + han + latin
        guard scripted > 0 else { return nil }
        if kana > 0 { return "Japanese" }                       // kanji+kana mix is still JA
        if hangul > 0, hangul >= han { return "Korean" }        // KO with sprinkled hanja stays KO
        if han > 0 { return "Chinese" }
        if latin * 2 > scripted { return "English" }
        return nil
    }
}
