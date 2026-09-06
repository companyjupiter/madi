import Foundation

/// Debug mode (2026-09-06, docs/DEBUG_MODE.md): one bundle directory per
/// session with every stream a live-bug hunt has needed so far — the exact
/// engine bytes (env/stdin/wav/stdout), the store's boundary and merge
/// decisions, every translation turn with its prompt and raw reply, watchdog
/// events and a memory time series. OFF = `DebugLog.shared == nil`, one nil
/// check per call site. ON = JSONL appends on a private serial queue.
///
/// Headless-safe (Foundation only) so TranscriptStore, WordMerger and the
/// translation queue can log from the SovereignCore test target too.
final class DebugLog: @unchecked Sendable {
    nonisolated(unsafe) static var shared: DebugLog? = nil

    let bundle: URL
    let startedAt: Date
    private let queue = DispatchQueue(label: "madi.debuglog", qos: .utility)
    private var handles: [String: FileHandle] = [:]
    private let iso = ISO8601DateFormatter()

    /// Create `<root>/<yyyyMMdd-HHmmss>` and make it the shared sink.
    @discardableResult
    static func start(root: URL, now: Date = Date()) -> DebugLog? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let dir = root.appendingPathComponent(f.string(from: now), isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        let log = DebugLog(bundle: dir, startedAt: now)
        shared = log
        return log
    }

    /// Flush and detach the shared sink (the files stay).
    static func stop() {
        guard let log = shared else { return }
        shared = nil
        log.queue.sync {
            for h in log.handles.values { try? h.close() }
            log.handles.removeAll()
        }
    }

    init(bundle: URL, startedAt: Date) {
        self.bundle = bundle
        self.startedAt = startedAt
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Seconds since the bundle was opened.
    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// Append one JSON object line to `<stream>.jsonl`. `fields` must be
    /// JSON-serializable (String/Int/Double/Bool/[…]/[String: …]); anything
    /// else is stringified.
    func emit(_ stream: String, _ ev: String, _ fields: [String: Any] = [:]) {
        let now = Date()
        var obj: [String: Any] = ["t": (now.timeIntervalSince(startedAt) * 1000).rounded() / 1000,
                                  "w": iso.string(from: now), "ev": ev]
        for (k, v) in fields { obj[k] = Self.jsonSafe(v) }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        append(data + Data([0x0A]), to: "\(stream).jsonl")
    }

    /// Append raw bytes to a file in the bundle (engine stdout tee, stdin log).
    func append(_ data: Data, to name: String) {
        queue.async { [self] in
            let h: FileHandle
            if let open = handles[name] { h = open }
            else {
                let url = bundle.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                guard let opened = try? FileHandle(forWritingTo: url) else { return }
                try? opened.seekToEnd()
                handles[name] = opened
                h = opened
            }
            try? h.write(contentsOf: data)
        }
    }

    func appendLine(_ line: String, to name: String) {
        append(Data((line + "\n").utf8), to: name)
    }

    /// Write (replace) a whole text file in the bundle.
    func write(_ text: String, to name: String) {
        queue.async { [self] in
            try? text.write(to: bundle.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    /// Copy a file into the bundle (WAV snapshot, events file). Returns the
    /// destination name, or nil when the copy failed.
    @discardableResult
    func copyIn(_ src: URL, as name: String) -> String? {
        let dst = bundle.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.copyItem(at: src, to: dst)
            return name
        } catch { return nil }
    }

    /// Bytes currently in the bundle (for the WAV snapshot cap).
    func bundleSize() -> Int64 {
        guard let e = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            if let s = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += Int64(s) }
        }
        return total
    }

    private static func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let s as String: return s
        case let i as Int: return i
        case let d as Double: return d.isFinite ? d : "\(d)"
        case let f as Float: return f.isFinite ? Double(f) : "\(f)"
        case let b as Bool: return b
        case let a as [Any]: return a.map(jsonSafe)
        case let d as [String: Any]: return d.mapValues(jsonSafe)
        case let o as Optional<Any>:
            if case .some(let inner) = o { return jsonSafe(inner) }
            return NSNull()
        default: return String(describing: v)
        }
    }
}
