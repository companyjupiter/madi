// EngineProtocol.swift — parse the `transcribe` STREAM-mode stdout contract.
//
// The engine I/O contract (verified against metal/transcribe.zig):
//   [stream] ready (...)        → model resident, capture may begin
//   === WORD TIMESTAMPS ===     → word section begins
//   [<t0>s-<t1>s] <word>        → a word with GLOBAL timestamps (already offset)
//   SPK <gt> <id> [dur]         → streaming speaker label (1.5s window)
//   SPKFIX <gt> <id> [dur]      → FLUSH: recluster-corrected label
//   SPKOV <gt> <id> [dur]       → FLUSH: overlap 2nd speaker
//   <<FLUSH_END>>               → finalization done → export
//
// This file is pure parsing (no I/O), so it is unit-testable in isolation.

import Foundation

/// One decoded event from the engine's stdout stream.
enum EngineEvent: Equatable {
    case ready
    case wordSectionBegin
    case word(t0: Double, t1: Double, text: String, conf: Double)
    case speaker(SpeakerLabel)        // SPK
    case speakerFix(SpeakerLabel)     // SPKFIX
    case speakerOverlap(SpeakerLabel) // SPKOV
    case flushEnd
    case progressTotal(Int)           // file mode: total 30s chunks to process
    case progressChunk(Int)           // file mode: chunk K just finished
    case languageDetected(Int)        // auto-detect locked a language token id
    case other(String)                // unrecognized line (perf/log) — kept for diagnostics
}

struct SpeakerLabel: Equatable {
    let time: Double      // global seconds
    let id: Int
    let dur: Double       // window duration; defaults to 1.5 when engine omits it
}

enum EngineProtocol {
    /// Stateful line decoder: the word section is delimited by `=== ... ===`
    /// markers, so the parser tracks whether it is "inside words".
    final class Decoder {
        private var inWords = false

        func decode(line raw: String) -> EngineEvent {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("[stream] ready") { return .ready }
            if line == "<<FLUSH_END>>" { return .flushEnd }

            // file-mode progress: "[8] audio: … → N chunk(s) …" / "[perf] chunk K: …"
            if line.hasPrefix("[8] audio:"), let arrow = line.range(of: "→ ") {
                if let n = Int(line[arrow.upperBound...].prefix(while: \.isNumber)) { return .progressTotal(n) }
            }
            if line.hasPrefix("[perf] chunk ") {
                if let k = Int(line.dropFirst("[perf] chunk ".count).prefix(while: \.isNumber)) { return .progressChunk(k) }
            }
            // "[lang] detected token 50264 (en=50259 ko=50264)" — auto-detect lock
            if line.hasPrefix("[lang] detected token "),
               let tok = Int(line.dropFirst("[lang] detected token ".count).prefix(while: \.isNumber)) {
                return .languageDetected(tok)
            }

            if line.hasPrefix("=== WORD TIMESTAMPS") {
                inWords = true
                return .wordSectionBegin
            }
            if line.hasPrefix("=== ") {           // any other section closes words
                inWords = false
                return .other(line)
            }

            if let lbl = EngineProtocol.parseSpeaker(line, tag: "SPKFIX") { return .speakerFix(lbl) }
            if let lbl = EngineProtocol.parseSpeaker(line, tag: "SPKOV")  { return .speakerOverlap(lbl) }
            if let lbl = EngineProtocol.parseSpeaker(line, tag: "SPK")    { return .speaker(lbl) }

            if inWords, line.hasPrefix("["), let w = EngineProtocol.parseWord(line) { return w }

            return .other(line)
        }
    }

    /// `SPK <gt> <id> [dur]` / `SPKFIX …` / `SPKOV …`
    static func parseSpeaker(_ line: String, tag: String) -> SpeakerLabel? {
        guard line.hasPrefix(tag + " ") else { return nil }
        let parts = line.dropFirst(tag.count + 1)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let t = Double(parts[0]),
              let id = Int(parts[1]) else { return nil }
        let dur = parts.count >= 3 ? (Double(parts[2]) ?? 1.5) : 1.5
        return SpeakerLabel(time: t, id: id, dur: dur)
    }

    /// `[<t0>s-<t1>s] <word>`  (engine already globalized the times)
    static func parseWord(_ line: String) -> EngineEvent? {
        guard let close = line.firstIndex(of: "]") else { return nil }
        let bracket = line[line.index(after: line.startIndex)..<close] // "<t0>s-<t1>s"
        var body = line[line.index(after: close)...]
            .trimmingCharacters(in: .whitespaces)
        // optional confidence suffix:  word  «conf 0.42»
        var conf = 1.0
        if let r = body.range(of: "«conf ") {
            let tail = body[r.upperBound...]
            conf = Double(tail.prefix { $0 != "»" }) ?? 1.0
            body = String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        let span = bracket.replacingOccurrences(of: "s", with: "")
        let ends = span.split(separator: "-", maxSplits: 1)
        guard let t0 = Double(ends.first ?? "") else { return nil }
        let t1 = ends.count > 1 ? (Double(ends[1]) ?? t0) : t0
        guard !body.isEmpty else { return nil }
        return .word(t0: t0, t1: t1, text: body, conf: conf)
    }
}
