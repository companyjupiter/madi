// EventContractTests.swift — verify the macOS structured-event parser against
// the real engine fixtures (web/fixtures/*.events.jsonl), so the Swift and the
// web/dashboard model stay in lock-step with docs/EVENTS.md.
//
// Build standalone (no Xcode):
//   swiftc -parse-as-library Sovereign/Engine/EngineEvents.swift \
//          Tests/EventContractTests.swift -o /tmp/evtest && /tmp/evtest
// Exits non-zero on any failure.

import Foundation

@main
struct EventContractTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) { if !cond { failures += 1; print("FAIL: \(msg)") } }

        // locate the repo's fixtures relative to this file's build dir / cwd
        let candidates = [
            "../web/fixtures", "web/fixtures",
            FileManager.default.currentDirectoryPath + "/../web/fixtures",
        ]
        guard let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0 + "/jfk3.events.jsonl") }) else {
            print("FAIL: jfk3.events.jsonl fixture not found (cwd \(FileManager.default.currentDirectoryPath))")
            exit(1)
        }

        func load(_ name: String) -> [StructuredEvent] {
            let text = (try? String(contentsOfFile: dir + "/\(name).events.jsonl", encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { EngineEvents.decode(line: String($0)) }
        }

        // ── jfk3 (EN, 1 speaker) ─────────────────────────────────────────────
        let jfk = load("jfk3")
        var words = 0, segs = 0, metaOK = false, diarSpeakers = -1
        var firstSegHasLogprob = false
        for e in jfk {
            switch e {
            case .meta(let model, _, let sr, let v):
                metaOK = model.contains("whisper") && sr == 16000 && v == 1
            case .word: words += 1
            case .segment(let s):
                segs += 1
                if s.idx == 0 { firstSegHasLogprob = s.avgLogprob != 0 && s.fallback == "none" }
            case .diarization(let di): diarSpeakers = di.speakers
            default: break
            }
        }
        check(metaOK, "jfk3 meta (model/sr/v)")
        check(words == 66, "jfk3 word count == 66 (got \(words))")
        check(segs == 2, "jfk3 seg count == 2 (got \(segs))")
        check(firstSegHasLogprob, "jfk3 seg0 has real avg_logprob + fallback=none")
        check(diarSpeakers == 1, "jfk3 diar speakers == 1 (got \(diarSpeakers))")

        // ── devops_ko (KO, 2-speaker) — confidence + speaker fields ──────────
        let dk = load("devops_ko")
        var spkSegs = 0, twoSpeakers = false, lowConfSeen = false
        for e in dk {
            switch e {
            case .word(_, _, let conf, _, _): if conf < 0.55 { lowConfSeen = true }
            case .speakerSegment: spkSegs += 1
            case .diarization(let di): twoSpeakers = di.speakers == 2
            default: break
            }
        }
        check(spkSegs > 1, "devops_ko has multiple spk_seg runs (got \(spkSegs))")
        check(twoSpeakers, "devops_ko diar speakers == 2")
        check(lowConfSeen, "devops_ko surfaces low-confidence words")

        // ── biased fixture — bias_hits populated (P3) ────────────────────────
        let dkb = load("devops_ko_biased")
        var anyBias = false
        for e in dkb { if case .segment(let s) = e, !s.biasHits.isEmpty { anyBias = true } }
        check(anyBias, "devops_ko_biased carries bias_hits")

        // ── forward-compat: unknown event type → .unknown, not nil ───────────
        check(EngineEvents.decode(line: "{\"t\":\"future_thing\",\"x\":1}") == .unknown("future_thing"),
              "unknown event type degrades to .unknown")
        check(EngineEvents.decode(line: "not json") == nil, "garbage line → nil")

        if failures == 0 { print("OK: all EventContract checks passed (\(jfk.count + dk.count) events parsed)") }
        else { print("\(failures) FAILURES"); exit(1) }
    }
}
