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
    /// (tag, reply). tag routes the caller (e.g. "summary" / "qa"); reply is the
    /// finished multi-line text, or nil on empty/failure. The engine stays resident
    /// so follow-up questions don't reload the 2.6 GB model.
    var onResult: ((String, String?) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let ioQueue = DispatchQueue(label: "sovereign.summary.io")
    private var lineBuffer = Data()

    private var ready = false
    private var current = ""                       // reply lines accumulating (newline-joined)
    private var inflightTag: String?               // tag of the request awaiting its reply
    private var queue: [(tag: String, prompt: String)] = []   // FIFO (incl. pre-READY)

    // map-reduce for long meetings: the engine context is ~1024 tokens and silently
    // truncates past it, so a long transcript is split into char-budgeted chunks,
    // each condensed ("fold"), then folded again until one fits → final format.
    private let chunkChars = 800
    private var foldFinalTag = "summary"           // "summary" | "speakers"
    private var foldRemaining = 0
    private var foldAcc: [String] = []
    private var foldRound = 0                       // safety cap against a non-converging fold

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
        ready = false; current = ""; inflightTag = nil; queue.removeAll()
    }

    private func transcriptOneLine(_ lines: [String]) -> String {
        lines.joined(separator: " / ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Summarize a speaker-attributed transcript ("화자: 발언" lines), map-reducing
    /// over chunks so arbitrarily long meetings fit the engine's context.
    private var foldStyleSuffix = ""   // mode prompt nudge appended to the FINAL format prompt

    func summarize(lines: [String], styleSuffix: String = "") { beginFold(lines, finalTag: "summary", styleSuffix: styleSuffix) }

    /// Per-speaker breakdown: each speaker's key point + the actions they own.
    /// Leverages persistent speaker identity (voiceprints) — "who is on the hook".
    func summarizeBySpeaker(lines: [String], styleSuffix: String = "") { beginFold(lines, finalTag: "speakers", styleSuffix: styleSuffix) }

    /// One-line meeting TITLE from the transcript, on-device. Single budget-capped
    /// request (a title is short — no map-reduce fold). The raw reply is sanitized
    /// caller-side via TitleGenerator.sanitize; emits the "title" tag through onResult.
    func generateTitle(lines: [String]) {
        let t = transcriptOneLine(lines)
        guard !t.isEmpty else { onResult?("title", nil); return }
        enqueue("title", TitleGenerator.promptText(String(t.prefix(chunkChars))))
    }

    /// LIVE action-rail extraction — decisions / actions / open questions from the
    /// recent transcript window, during the meeting. Single budget-capped request;
    /// the reply is parsed caller-side via LiveActionRail.parse. "live-rail" tag.
    func extractActions(lines: [String]) {
        let t = transcriptOneLine(lines)
        guard !t.isEmpty else { onResult?("live-rail", nil); return }
        enqueue("live-rail", LiveActionRail.prompt(String(t.suffix(chunkChars))))
    }

    /// POST-SESSION diarization/language reconcile — the model reads the numbered,
    /// speaker-labeled transcript and proposes conservative speaker merges /
    /// relabels / wrong-language flags. Reply is parsed caller-side by
    /// TranscriptReconciler.parse. "reconcile" tag. `numbered` is the full prompt
    /// input from TranscriptReconciler.promptInput.
    func reconcile(numbered: String) {
        let body = String(numbered.suffix(chunkChars))
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { onResult?("reconcile", nil); return }
        enqueue("reconcile", TranscriptReconciler.instruction() + "\n" + body)
    }

    // The final-format prompt (single fitting text → the user-facing output).
    private func finalPrompt(_ tag: String, _ t: String) -> String {
        switch tag {
        case "speakers":
            return "다음 회의록을 화자별로 정리하세요. 회의록과 같은 언어로. "
                + "각 화자마다 '■ 이름: 핵심 발언 1문장. 맡은 일: - 할 일'(맡은 일 없으면 그 부분 생략). "
                + "다른 말 없이 이 형식만. 회의록: \(t)" + foldStyleSuffix
        default:
            return "다음 회의록을 요약하세요. 회의록과 같은 언어로 답하세요. "
                + "형식: [요약] 핵심을 2-4문장. [액션] 각 줄 '- 담당자: 할 일'(없으면 생략). "
                + "[결정] 각 줄 '- 결정사항'(없으면 생략). 다른 말 없이 이 형식만. 회의록: \(t)" + foldStyleSuffix
        }
    }
    // Intermediate "condense" prompt — preserve names, decisions, and to-dos.
    private func condensePrompt(_ t: String) -> String {
        "다음 회의 내용을 화자(이름)·핵심·결정·할 일을 보존하며 간결히 요약하세요. "
            + "회의록과 같은 언어로, 군더더기 없이. 내용: \(t)"
    }

    private func beginFold(_ lines: [String], finalTag: String, styleSuffix: String = "") {
        foldStyleSuffix = styleSuffix
        let full = transcriptOneLine(lines)
        guard !full.isEmpty else { onResult?(finalTag, nil); return }
        foldFinalTag = finalTag
        foldRound = 0
        runFoldRound(splitToBudget(lines))   // round 0 inputs = transcript chunks
    }

    /// Group whole "화자: 발언" lines so each chunk's joined length ≤ chunkChars
    /// (a single over-budget line still becomes its own chunk).
    private func splitToBudget(_ lines: [String]) -> [String] {
        var out: [String] = []; var cur = ""
        for l in lines {
            let merged = cur.isEmpty ? l : cur + " / " + l
            if merged.count > chunkChars, !cur.isEmpty { out.append(cur); cur = l }
            else { cur = merged }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Group already-condensed texts so each batch's joined length ≤ chunkChars.
    private func batchToBudget(_ texts: [String]) -> [[String]] {
        var out: [[String]] = []; var cur: [String] = []; var len = 0
        for t in texts {
            if len + t.count + 3 > chunkChars, !cur.isEmpty { out.append(cur); cur = [t]; len = t.count }
            else { cur.append(t); len += t.count + 3 }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// One fold round: if the inputs fit one request → emit the final format;
    /// else condense each batch ("fold") and recurse on the results.
    private func runFoldRound(_ texts: [String]) {
        foldRound += 1
        let batches = batchToBudget(texts)
        // fits one request, or the fold isn't converging (cap) → emit final format,
        // truncating to the budget so the last request never overflows the context.
        if batches.count <= 1 || foldRound > 4 {
            let joined = (batches.first ?? texts).joined(separator: " ")
            enqueue(foldFinalTag, finalPrompt(foldFinalTag, String(joined.prefix(chunkChars))))
            return
        }
        foldRemaining = batches.count; foldAcc = []
        for b in batches { enqueue("fold", condensePrompt(b.joined(separator: " "))) }
    }

    /// Answer a question grounded ONLY in the transcript. For long meetings the
    /// full transcript exceeds the context, so the most question-relevant lines are
    /// retrieved (lexical, on-device) and fed instead of the (truncated) whole —
    /// grounded in REAL excerpts, not a clipped head. Says it's not in the
    /// transcript rather than hallucinating.
    func ask(_ question: String, lines: [String]) {
        let q = question.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { onResult?("qa", nil); return }
        let t = transcriptOneLine(Retrieval.relevantLines(q, lines, budget: chunkChars))
        guard !t.isEmpty else { onResult?("qa", nil); return }   // no relevant excerpt
        askPreselected(q, lines: Retrieval.relevantLines(q, lines, budget: chunkChars))
    }

    /// Same prompt as ask(), but the lines are ALREADY retrieval-selected (e.g.
    /// workspace RAG, where each line is prefixed with its meeting). Skips the
    /// second Retrieval pass so those prefixes can't push the joined text past
    /// the budget and silently drop relevant excerpts — caps to chunkChars instead.
    func askPreselected(_ question: String, lines: [String]) {
        let q = question.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { onResult?("qa", nil); return }
        let t = String(transcriptOneLine(lines).prefix(chunkChars))
        guard !t.isEmpty else { onResult?("qa", nil); return }
        enqueue("qa",
            "다음 회의록 발췌만 근거로 질문에 답하세요. 회의록과 같은 언어로, 간결하게. "
            + "발췌에 답이 없으면 '회의록에 해당 내용이 없습니다'라고만 답하세요. "
            + "질문: \(q) 발췌: \(t)")
    }

    private func enqueue(_ tag: String, _ prompt: String) {
        if ready, inflightTag == nil { send(tag, prompt) } else { queue.append((tag, prompt)) }
    }

    private func send(_ tag: String, _ prompt: String) {
        inflightTag = tag
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
            drain()
            return
        }
        if s.hasPrefix("[perf] generation") {           // reply complete
            let out = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard let tag = inflightTag else { return }
            inflightTag = nil
            if tag == "fold" {                       // map-reduce intermediate — not user-facing
                if !out.isEmpty { foldAcc.append(out) }
                foldRemaining -= 1
                if foldRemaining <= 0 { runFoldRound(foldAcc) }
                drain()
                return
            }
            onResult?(tag, out.isEmpty ? nil : out)
            drain()
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

    /// Send the next queued request if idle.
    private func drain() {
        guard ready, inflightTag == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        send(next.tag, next.prompt)
    }
}
