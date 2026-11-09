import Foundation

// Logging is disabled in this oracle; EngineProcess and both parsers are compiled unchanged.
final class DebugLog {
    static var shared: DebugLog? { nil }
    var elapsed: Double { 0 }
    func append(_ data: Data, to: String) {}
    func appendLine(_ text: String, to: String) {}
    func write(_ text: String, to: String) {}
    @discardableResult func copyIn(_ url: URL, as name: String) -> URL? { nil }
    func emit(_ category: String, _ name: String, _ data: [String: Any]) {}
}

@MainActor final class Observer: EngineProcessDelegate {
    var engine: EngineProcess!
    var root: URL!
    var finished = false
    var acknowledge = false
    var output: [String] = []
    func engineDidBecomeReady() { output.append("ready") }
    func engineDidFlush() { output.append("flush") }
    func engine(didTerminate code: Int32) { output.append("exit:\(code)"); finished = true }
    func engine(didEmit event: EngineEvent) {
        switch event {
        case .wordSectionBegin: output.append("words")
        case .word(let t0, let t1, let text, let conf): output.append("word:\(bits(t0)):\(bits(t1)):\(bits(conf)):\(hex(text))")
        case .segmentEnd:
            output.append("segment")
            if acknowledge { engine.feed(offset: 0, wav: root.appendingPathComponent("ack.wav")) }
        case .progressTotal(let count): output.append("total:\(count)")
        case .previewBegin: output.append("preview-begin")
        case .previewEnd: output.append("preview-end")
        default: output.append("unexpected-stdout:\(event)")
        }
    }
    func engine(didEmitStructured event: StructuredEvent) {
        switch event {
        case .ready: output.append("json:ready")
        case .flushEnd: output.append("json:flush")
        case .partial(let t0, let text): output.append("json:partial:\(bits(t0)):\(hex(text))")
        default: output.append("unexpected-json:\(event)")
        }
    }
    func bits(_ d: Double) -> String { String(format: "%016llx", d.bitPattern) }
    func hex(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }
}

@main enum StreamProcessOracle {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[4])
        let observer = Observer()
        observer.root = root
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [String: Any]
        observer.acknowledge = (fixture["batches"] as! [[String: Any]]).contains { $0["ack"] as? Bool == true }
        let engine = EngineProcess(config: .init(binaryURL: URL(fileURLWithPath: args[1]), modelURL: URL(fileURLWithPath: args[2]), bpeURL: root, assetsDir: root, streamWavRoots: [root], fileURL: URL(fileURLWithPath: args[3])))
        observer.engine = engine
        engine.delegate = observer
        engine.onDiagnosticLine = { observer.output.append("other:\(observer.hex($0))") }
        defer { engine.terminate() }
        try engine.start()
        for _ in 0..<1000 {
            if observer.finished {
                print(observer.output.joined(separator: "\n"))
                print("caps:\(engine.capabilities.sorted().joined(separator: ","))")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("engine oracle timed out")
    }
}
