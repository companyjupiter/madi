// EngineEvents.swift — parse the engine's STRUCTURED event contract (EVENTS_FILE,
// JSON-lines). This is the macOS counterpart to web/dashboard/src/types.ts: both
// front-ends now consume the SAME contract (docs/EVENTS.md). The legacy stdout
// text parser (EngineProtocol.swift) stays for back-compat; new signals
// (avg_logprob, fallback, bias_hits, partial) arrive cleanly typed here.
//
// Pure parsing (JSONSerialization, no I/O) → unit-testable in isolation.

import Foundation

struct SegInfo: Equatable {
    let idx: Int
    let t0, t1: Double
    let avgLogprob: Double
    let fallback: String          // none | collapse | logprob
    let tokS, encMs, decMs: Double
    let passes: Int
    let dropped: Bool
    let text: String
    let biasHits: [String]        // term-biasing hits (P3); empty if no prompt
}

struct DiarInfo: Equatable {
    let speakers: Int
    let silhouette, sep, tau: Double
    let segments: Int
}

enum StructuredEvent: Equatable {
    case meta(model: String, lang: Int, sampleRate: Int, version: Int)
    case ready
    case partial(t0: Double, text: String)
    case word(t0: Double, t1: Double, conf: Double, spk: Int, text: String)
    case segment(SegInfo)
    case speakerSegment(t0: Double, spk: Int, text: String)
    case diarization(DiarInfo)
    case segEnd
    case flushEnd
    case unknown(String)          // forward-compat: unrecognized "t"
}

enum EngineEvents {
    /// Decode one JSON-lines event. Unknown types / missing fields fall back
    /// gracefully (the contract guarantees consumers ignore what they don't know).
    static func decode(line raw: String) -> StructuredEvent? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = o["t"] as? String else { return nil }

        func d(_ k: String, _ def: Double = 0) -> Double { (o[k] as? NSNumber)?.doubleValue ?? def }
        func i(_ k: String, _ def: Int = 0) -> Int { (o[k] as? NSNumber)?.intValue ?? def }
        func s(_ k: String, _ def: String = "") -> String { o[k] as? String ?? def }

        switch t {
        case "meta":      return .meta(model: s("model"), lang: i("lang"), sampleRate: i("sr"), version: i("v", 1))
        case "ready":     return .ready
        case "partial":   return .partial(t0: d("t0"), text: s("text"))
        case "word":      return .word(t0: d("t0"), t1: d("t1"), conf: d("conf", 1), spk: i("spk", -1), text: s("text"))
        case "spk_seg":   return .speakerSegment(t0: d("t0"), spk: i("spk", -1), text: s("text"))
        case "seg":
            return .segment(SegInfo(
                idx: i("idx"), t0: d("t0"), t1: d("t1"), avgLogprob: d("avg_logprob"),
                fallback: s("fallback", "none"), tokS: d("tok_s"), encMs: d("enc_ms"),
                decMs: d("dec_ms"), passes: i("passes"), dropped: (o["dropped"] as? Bool) ?? false,
                text: s("text"), biasHits: (o["bias_hits"] as? [String]) ?? []))
        case "diar":
            return .diarization(DiarInfo(speakers: i("speakers"), silhouette: d("silhouette"),
                sep: d("sep"), tau: d("tau"), segments: i("segments")))
        case "seg_end":   return .segEnd
        case "flush_end": return .flushEnd
        default:          return .unknown(t)
        }
    }
}
