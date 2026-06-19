// SummaryEngine.swift — on-device meeting intelligence. Drives the SAME bundled
// DNA3.0-4B Metal engine as translation, but for POST-session summarization:
// feeds the speaker-attributed transcript as one chat turn and returns a
// structured [요약]/[액션]/[결정] block. 100% local — the transcript never leaves
// the device (the product moat vs cloud meeting tools; whisper.cpp has no LLM).
//
// Forked from TranslateEngine (per the AI-first per-app-fork philosophy): same
// spawn/stdin-line/stdout-parse contract, but ONE request, a long single-line
// prompt, and a MULTI-LINE reply preserved with newlines (translation collapsed
// to one line; a summary's [요약]/[액션] structure must survive).
//
// Engine I/O (verified, sovereignLLM/apps/metal-dna3-4b-q4km/main.zig):
//   launch: translate-engine <model.gguf> → prints READY
//   stdin : ONE line = one chat turn. stdout: banner/[perf] lines + reply text +
//           "[perf] generation" terminator + "> ".

import Foundation

@MainActor
final class SummaryEngine {
    /// The finished summary text (multi-line, structured). nil arg = failed/empty.
    var onResult: ((String?) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let ioQueue = DispatchQueue(label: "sovereign.summary.io")
    private var lineBuffer = Data()

    private var ready = false
    private var current = ""           // reply lines accumulating (newline-joined)
    private var inflight = false       // a summarize request is awaiting its reply
    private var queuedPrompt: String?  // request issued before READY

    func start(engine: URL, model: URL) -> Bool {
        process.executableURL = engine
        process.arguments = [model.path]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SOV_DEBUG")   // gates on presence, not value
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
        ready = false; current = ""; inflight = false; queuedPrompt = nil
    }

    /// Summarize a speaker-attributed transcript. `lines` are "화자: 발언" strings;
    /// joined with " / " into one chat turn. The model is asked to reply in the
    /// transcript's own language (so English meetings get English summaries).
    func summarize(lines: [String]) {
        let oneLine = lines.joined(separator: " / ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { onResult?(nil); return }
        let prompt =
            "다음 회의록을 요약하세요. 회의록과 같은 언어로 답하세요. "
            + "형식: [요약] 핵심을 2-4문장. [액션] 각 줄 '- 담당자: 할 일'(없으면 생략). "
            + "[결정] 각 줄 '- 결정사항'(없으면 생략). 다른 말 없이 이 형식만. 회의록: \(oneLine)"
        if ready { send(prompt) } else { queuedPrompt = prompt }
    }

    private func send(_ prompt: String) {
        inflight = true
        current = ""
        write(prompt + "\n")
    }

    private func write(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        ioQueue.async { [weak self] in try? self?.stdinPipe.fileHandleForWriting.write(contentsOf: data) }
    }

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
        var s = raw
        while s.hasPrefix(">") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if s == "READY" {
            ready = true
            if let p = queuedPrompt { queuedPrompt = nil; send(p) }
            return
        }
        if s.hasPrefix("[perf] generation") {           // reply complete
            let out = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard inflight else { return }
            inflight = false
            onResult?(out.isEmpty ? nil : out)
            return
        }
        if s.isEmpty || s.hasPrefix("[chat]") || s.hasPrefix("[perf]")
            || s.hasPrefix("Loading") || s.hasPrefix("Initializing") || s.hasPrefix("[arch]")
            || s.hasPrefix("token[") {
            return
        }
        // reply text — preserve line structure ([요약]/[액션]/bullets) with newlines
        current += current.isEmpty ? s : "\n" + s
    }
}
