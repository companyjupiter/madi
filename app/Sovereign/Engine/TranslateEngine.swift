// TranslateEngine.swift — drives the bundled sovereign DNA3.0-4B Metal engine for
// on-device translation. Spawns the engine once, feeds each committed segment as a
// single-turn chat (the engine is STATELESS per line → independent translations,
// no reset), and returns the translated text.
//
// Engine I/O (verified from sovereignLLM/apps/metal-dna3-4b-q4km/main.zig):
//   launch: translate-engine <model.gguf> → prints READY
//   stdin : ONE line = one chat turn (\n-delimited!). The chat template +
//           tokenize + generate + DETOKENIZE happen inside; thinking is disabled.
//   stdout: "> [chat] N tokens, prefilling..." / "[perf] prefill: …" / <reply text>
//           / "[perf] generation: …" / "> ". The reply is the text between the
//           prefill and generation [perf] lines; we strip "> "/[chat]/[perf]/etc.
//
// CRITICAL: the prompt MUST be a single line (no '\n') or the engine splits it
// into multiple turns — so the instruction + text are one line and any newline in
// the segment text is collapsed to a space.

import Foundation

@MainActor
final class TranslateEngine {
    /// (lineID, translated text) for a completed turn, in FIFO order.
    var onResult: ((UUID, String) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let ioQueue = DispatchQueue(label: "sovereign.translate.io")
    private var lineBuffer = Data()

    private var ready = false
    private var current = ""           // reply text accumulating for the in-flight turn
    private var inflight: [UUID] = []  // FIFO line ids awaiting a result
    private var queued: [(UUID, String)] = []  // prompts sent before READY

    func start(engine: URL, model: URL) -> Bool {
        process.executableURL = engine
        process.arguments = [model.path]
        // NOTE: do NOT set SOV_DEBUG — the engine gates debug on env PRESENCE
        // (not value), so even SOV_DEBUG=0 turns on the token-dump. Leave it unset.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SOV_DEBUG")
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            self?.ioQueue.async { self?.ingest(chunk) }
        }
        do { try process.run(); return true } catch { return false }
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        ready = false; current = ""; inflight.removeAll(); queued.removeAll()
    }

    /// Queue a translation of `text` into `target` (English language name, e.g.
    /// "Korean") for `id`. Result arrives via onResult, FIFO.
    func translate(_ text: String, into target: String, id: UUID) {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return }
        let prompt = "Translate the following into \(target). Reply with only the translation, no notes or quotes: \(oneLine)"
        if ready { send(id, prompt) } else { queued.append((id, prompt)) }
    }

    private func send(_ id: UUID, _ prompt: String) {
        inflight.append(id)
        write(prompt + "\n")
    }

    private func write(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        ioQueue.async { [weak self] in try? self?.stdinPipe.fileHandleForWriting.write(contentsOf: data) }
    }

    // MARK: stdout framing + parse
    private func ingest(_ chunk: Data) {
        lineBuffer.append(chunk)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            guard let raw = String(data: lineData, encoding: .utf8) else { continue }
            Task { @MainActor in self.parse(raw) }
        }
    }

    @MainActor
    private func parse(_ raw: String) {
        // strip leading "> " REPL prompt(s)
        var s = raw
        while s.hasPrefix(">") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if s == "READY" {
            ready = true
            let q = queued; queued.removeAll()
            for (id, p) in q { send(id, p) }
            return
        }
        if s.hasPrefix("[perf] generation") {           // turn complete
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            if !inflight.isEmpty {
                let id = inflight.removeFirst()
                if !t.isEmpty { onResult?(id, t) }
            }
            return
        }
        // control / banner / debug lines → ignore (token[…] = the SOV_DEBUG dump,
        // defensively filtered even though we leave SOV_DEBUG unset)
        if s.isEmpty || s.hasPrefix("[chat]") || s.hasPrefix("[perf]")
            || s.hasPrefix("Loading") || s.hasPrefix("Initializing") || s.hasPrefix("[arch]")
            || s.hasPrefix("token[") {
            return
        }
        // reply text (may be multi-line) → accumulate
        current += current.isEmpty ? s : " " + s
    }
}
