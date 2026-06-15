// CaptionStub.swift — minimal Word/Line/Theme for the standalone caption-spec
// test build (the real Word/Line live in TranscriptStore.swift, which pulls in
// SwiftUI/Observation and can't link into a tiny CLI test).

import Foundation

struct Word: Identifiable {
    let id = UUID()
    let t0: Double
    let t1: Double
    let text: String
    var conf: Double = 1.0
}

struct Line: Identifiable {
    let id = UUID()
    var speaker: Int
    var start: Double
    var end: Double
    var words: [Word]
    var overlapSpeakers: [Int] = []
    var text: String {
        var s = ""
        for w in words {
            if !s.isEmpty, w.text.first.map({ !",.!?…".contains($0) }) ?? true { s += " " }
            s += w.text
        }
        return s
    }
}

enum Theme {
    static let confThreshold = 0.5
}
