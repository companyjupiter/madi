// WordMergerStub.swift — minimal Word definition for the standalone WordMerger
// test build (the real one lives in TranscriptStore.swift, which pulls in
// SwiftUI/Observation and can't link into a tiny CLI test).

import Foundation

struct Word: Identifiable {
    let id = UUID()
    let t0: Double
    let t1: Double
    let text: String
}
