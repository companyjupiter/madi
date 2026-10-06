import Foundation

/// Bounded, cancellable transcription for a retained line-sized audio clip.
/// Runs on the caller's detached correction task, never on the main actor.
enum SessionOneShotTranscriber {
    struct Config {
        let binary: URL
        let model: URL
        let wav: URL
        let bpe: URL
        let assets: URL
        let languageToken: Int
    }

    static func transcribe(_ config: Config, timeout: TimeInterval = 45) async -> String? {
        let process = Process()
        process.executableURL = config.binary
        process.arguments = [config.model.path, config.wav.path, config.bpe.path]
        process.currentDirectoryURL = config.assets
        var env = ProcessInfo.processInfo.environment
        env["DIAR"] = "0"; env["AUDIO_CTX"] = "auto"; env["WHISPER_LANG_ID"] = String(config.languageToken)
        env.removeValue(forKey: "STREAM"); env.removeValue(forKey: "APP_FILE")
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let lease = ProcessLease(process)
        return await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else { return nil }
            do { try lease.start() } catch { return nil }
            let deadline = DispatchWorkItem { lease.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout), execute: deadline)
            defer { deadline.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard !Task.isCancelled, !lease.wasCancelled, process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return parse(text)
        }, onCancel: { lease.cancel() })
    }

    private static func parse(_ output: String) -> String? {
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("=== TRANSCRIPTION") }) else { return nil }
        var text = ""
        for line in lines[(start + 1)...] {
            if line.hasPrefix("===") || line.hasPrefix("[") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { if text.isEmpty { continue } else { break } }
            text += (text.isEmpty ? "" : " ") + trimmed
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Cancellation can race process launch from another executor. Lock both
    /// operations so cancellation before launch cannot leave an orphan process.
    private final class ProcessLease: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var cancelled = false
        init(_ process: Process) { self.process = process }
        var wasCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func start() throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
}
