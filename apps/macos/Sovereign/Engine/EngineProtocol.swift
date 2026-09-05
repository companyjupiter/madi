// EngineProtocol.swift — parse the `transcribe` STREAM-mode stdout contract.
//
// The engine I/O contract (verified against metal/transcribe.zig):
//   [stream] ready (...)        → model resident, capture may begin
//   === WORD TIMESTAMPS ===     → word section begins
//   [<t0>s-<t1>s] <word>        → a word with GLOBAL timestamps (already offset)
//   SPK <gt> <id> [dur]         → streaming speaker label (1.5s window)
//   SPKFIX <gt> <id> [dur]      → FLUSH: recluster-corrected label
//   SPKOV <gt> <id> [dur]       → causal/final overlap 2nd speaker
//   SPKOVRESET                   → replace causal overlap with final rows
//   <<PREVIEW_BEGIN>>            → throwaway open-window decode begins
//   <<PREVIEW_END>>              → throwaway open-window decode ends
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
    case speakerOverlapReset          // SPKOVRESET
    case speakerName(id: Int, name: String)  // SPKNAME — matched an enrolled voiceprint
    case flushEnd
    case progressTotal(Int)           // file mode: total 30s chunks to process
    case progressChunk(Int)           // file mode: chunk K just finished
    case languageDetected(Int)        // auto-detect locked a language token id
    case partial(t0: Double, text: String) // «partial <t0>» — in-decode hypothesis (PARTIALS=1)
    case segmentEnd                   // <<SEG_END>> — one stream job finished (watchdog heartbeat)
    case previewBegin                 // <<PREVIEW_BEGIN>> — isolate following output from committed state
    case previewWord(String)          // final word emitted by the throwaway preview lane
    case previewPartial(String)       // in-decode hypothesis from the throwaway preview lane
    case previewEnd                   // <<PREVIEW_END>> — preview lane is available again
    case other(String)                // unrecognized line (perf/log) — kept for diagnostics
}

struct SpeakerLabel: Equatable {
    let time: Double      // global seconds
    let id: Int
    let dur: Double       // window duration; defaults to 1.5 when engine omits it
    /// Acoustic confidence: best−second centroid cosine margin (S2). 1.0 = the
    /// engine had no competing speaker (or an old engine without the field).
    var margin: Double = 1.0
}

enum EngineProtocol {
    /// Stateful line decoder: the word section is delimited by `=== ... ===`
    /// markers, so the parser tracks whether it is "inside words".
    final class Decoder {
        private var inWords = false
        private var inPreview = false

        func decode(line raw: String) -> EngineEvent {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if line == "<<PREVIEW_BEGIN>>" {
                inPreview = true
                inWords = false
                return .previewBegin
            }
            if line == "<<PREVIEW_END>>" {
                inPreview = false
                inWords = false
                return .previewEnd
            }

            let partial: EngineEvent? = {
                guard line.hasPrefix("\u{00AB}partial ") else { return nil }
                let rest = line.dropFirst("\u{00AB}partial ".count)
                guard let close = rest.range(of: "\u{00BB} "),
                      let t0 = Double(rest[..<close.lowerBound]) else { return nil }
                return .partial(t0: t0, text: String(rest[close.upperBound...]))
            }()

            // Markers quarantine every control/event family, including any a
            // future engine accidentally prints. Only preview text can escape.
            if inPreview {
                if line.hasPrefix("=== WORD TIMESTAMPS") {
                    inWords = true
                    return .other(line)
                }
                if line.hasPrefix("=== ") {
                    inWords = false
                    return .other(line)
                }
                if let partial, case .partial(_, let text) = partial {
                    return .previewPartial(text)
                }
                if inWords, line.hasPrefix("["), let word = EngineProtocol.parseWord(line),
                   case .word(_, _, let text, _) = word {
                    return .previewWord(text)
                }
                return .other(line)
            }

            if line.hasPrefix("[stream] ready") { return .ready }
            if line == "<<FLUSH_END>>" { return .flushEnd }
            if line == "<<SEG_END>>" { return .segmentEnd }
            if line == "SPKOVRESET" { return .speakerOverlapReset }

            // file-mode progress: "[8] audio: … → N chunk(s) …" / "[perf] chunk K: …"
            if line.hasPrefix("[8] audio:"), let arrow = line.range(of: "→ ") {
                if let n = Int(line[arrow.upperBound...].prefix(while: \.isNumber)) { return .progressTotal(n) }
            }
            if line.hasPrefix("[perf] chunk ") {
                if let k = Int(line.dropFirst("[perf] chunk ".count).prefix(while: \.isNumber)) { return .progressChunk(k) }
            }
            // "[lang] detected token 50264 (…)" (pre-0.3.8) / "[lang] locked token 50259
            // margin 2.60 after 1 probe(s) (…)" (0.3.8+) — the auto-detect lock. P6: the
            // 0.3.8 engine changed the wording and this parser did not follow, so
            // .languageDetected never fired and the preview lane never started
            // (a captured 0.3.9 session shows 48 SEG commands and 0 PREVIEW).
            for prefix in ["[lang] locked token ", "[lang] detected token "] where line.hasPrefix(prefix) {
                if let tok = Int(line.dropFirst(prefix.count).prefix(while: \.isNumber)) {
                    return .languageDetected(tok)
                }
            }

            if line.hasPrefix("=== WORD TIMESTAMPS") {
                inWords = true
                return .wordSectionBegin
            }
            if line.hasPrefix("=== ") {           // any other section closes words
                inWords = false
                return .other(line)
            }

            // "SPKNAME <id> <name>" — a session speaker matched an enrolled voiceprint
            if line.hasPrefix("SPKNAME ") {
                let rest = line.dropFirst("SPKNAME ".count)
                if let sp = rest.firstIndex(of: " "), let id = Int(rest[..<sp]) {
                    let name = rest[rest.index(after: sp)...].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { return .speakerName(id: id, name: name) }
                }
            }

            // «partial <t0>» <text> — streaming in-decode hypothesis (engine env
            // PARTIALS=1; live STREAM mode sets it). The text grows batch-by-
            // batch and is superseded by the committed word section.
            if let partial { return partial }

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
        let margin = parts.count >= 4 ? (Double(parts[3]) ?? 1.0) : 1.0
        return SpeakerLabel(time: t, id: id, dur: dur, margin: margin)
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
