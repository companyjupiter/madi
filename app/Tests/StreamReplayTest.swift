// StreamReplayTest.swift — replay a REAL engine stdout capture through the
// actual EngineProtocol.Decoder + WordMerger chain and assert the overlap
// dedup holds on field data (not just synthetic cases).
//
// Build:
//   swiftc -parse-as-library Sovereign/Engine/EngineProtocol.swift \
//          Sovereign/Transcript/WordMerger.swift Tests/WordMergerStub.swift \
//          Tests/StreamReplayTest.swift -o /tmp/srtest
// Run:
//   /tmp/srtest <raw_engine_stdout.txt>

import Foundation

@main
struct StreamReplayTest {
    static func main() {
        guard CommandLine.arguments.count == 2,
              let raw = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        else { print("usage: srtest <raw_stream.txt>"); exit(2) }

        let decoder = EngineProtocol.Decoder()
        var merger = WordMerger()
        var sections = 0, wordsIn = 0, flushSeen = false

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            switch decoder.decode(line: String(line)) {
            case .wordSectionBegin:
                sections += 1
                merger.segmentBreak()
            case .word(let t0, let t1, let text):
                wordsIn += 1
                merger.add(Word(t0: t0, t1: t1, text: text))
            case .flushEnd:
                flushSeen = true
                merger.finish()
            default: break
            }
        }

        let out = merger.committed
        print("sections=\(sections) wordsIn=\(wordsIn) wordsOut=\(out.count) flush=\(flushSeen)")

        // assertion 1: monotonic non-overlapping onsets (no re-decoded region kept twice)
        var fails = 0
        for i in 1..<max(1, out.count) where out[i].t0 < out[i-1].t0 - 0.05 {
            fails += 1
            print("FAIL: t0 regression at \(i): \(out[i-1].t0)→\(out[i].t0)")
        }
        // assertion 2: no adjacent normalized duplicates within 1.0s (the field symptom)
        func norm(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }
        for i in 1..<max(1, out.count) {
            if norm(out[i].text) == norm(out[i-1].text), !norm(out[i].text).isEmpty,
               out[i].t0 - out[i-1].t1 < 0.2, abs(out[i].t0 - out[i-1].t0) < 1.0 {
                fails += 1
                print("FAIL: adjacent dup \"\(out[i].text)\" @ \(out[i-1].t0)/\(out[i].t0)")
            }
        }
        // assertion 3: dedup actually removed something when overlaps existed
        if sections > 1, wordsIn == out.count {
            print("WARN: no words removed across \(sections) sections — overlap empty or dedup inert")
        }

        print(fails == 0 ? "✅ replay: dedup holds on real stream" : "❌ \(fails) failure(s)")
        print("merged: " + out.map(\.text).joined(separator: " "))
        exit(fails == 0 ? 0 : 1)
    }
}
