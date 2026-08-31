// SummaryEngine.swift — on-device meeting intelligence. Drives the SAME bundled
// the hardware-selected DNA3 Metal engine as translation, but for POST-session summarization:
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
    /// so follow-up questions don't reload the selected model.
    var onResult: ((String, String?) -> Void)?

    private let broker = DNAEngineBroker.shared
    private let clientID = UUID()

    // map-reduce for long meetings: the engine context is ~1024 tokens and silently
    // truncates past it, so a long transcript is split into char-budgeted chunks,
    // each condensed ("fold"), then folded again until one fits → final format.
    private let chunkChars = 800
    private var foldFinalTag = "summary"           // "summary" | "speakers"
    private var foldRemaining = 0
    private var foldAcc: [String] = []
    private var foldRound = 0                       // safety cap against a non-converging fold
    private var reconcileRemaining = 0
    private var reconcileAcc: [String] = []

    func start(engine: URL, model: URL) -> Bool {
        broker.attach(client: clientID, engine: engine, model: model, onReady: {})
    }

    func stop() {
        broker.detach(client: clientID)
    }

    /// Drop QUEUED meeting-intelligence work while staying attached. Used when
    /// recording ends: a live-rail request queued at .liveRail outranks the
    /// post-session summary lane (.postSession), so a stale rail extraction left
    /// in the queue would run FIRST and delay the summary the user is waiting
    /// for. Dropped requests complete with nil, so the fold/reconcile counters
    /// still drain.
    func cancelQueued() {
        broker.cancelPending(client: clientID)
    }

    private func transcriptOneLine(_ lines: [String]) -> String {
        lines.joined(separator: " / ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Summarize a speaker-attributed transcript ("화자: 발언" lines), map-reducing
    /// over chunks so arbitrarily long meetings fit the engine's context.
    private var foldStyleSuffix = ""   // mode prompt nudge appended to the FINAL format prompt
    private var foldTemplate: SummaryTemplate = .meeting   // shapes final + condense prompts

    func summarize(lines: [String], template: SummaryTemplate = .meeting, styleSuffix: String = "") {
        beginFold(lines, finalTag: "summary", template: template, styleSuffix: styleSuffix)
    }

    /// Per-speaker breakdown: each speaker's key point + the actions they own.
    /// Leverages persistent speaker identity (voiceprints) — "who is on the hook".
    /// The speakers view is template-agnostic, but the template still shapes the
    /// map-reduce condense (what a long session must preserve on the way down).
    func summarizeBySpeaker(lines: [String], template: SummaryTemplate = .meeting, styleSuffix: String = "") {
        beginFold(lines, finalTag: "speakers", template: template, styleSuffix: styleSuffix)
    }

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

    /// LIVE rolling core summary — carry (the previous summary) + only the NEW
    /// lines since it, → an updated flat bullet list for the right-side 요약 tab.
    /// Rides the LOWEST broker lane (.postSession — see enqueue), input capped in
    /// LiveSummary.prompt, so one request's in-flight time stays ~1-2 s on the 4B
    /// (probed): the worst it can ever delay a caption turn. "live-summary" tag.
    func liveSummarize(carry: String?, lines: [String], template: SummaryTemplate) {
        let t = transcriptOneLine(lines)
        guard !t.isEmpty else { onResult?("live-summary", nil); return }
        enqueue("live-summary", LiveSummary.prompt(carry: carry, window: t, template: template))
    }

    /// POST-SESSION diarization/language reconcile — the model reads the numbered,
    /// speaker-labeled transcript and proposes conservative speaker merges /
    /// relabels / wrong-language flags. Reply is parsed caller-side by
    /// TranscriptReconciler.parse. "reconcile" tag. `numbered` is the full prompt
    /// input from TranscriptReconciler.promptInput.
    func reconcile(numbered: String) {
        let batches = TranscriptReconciler.promptBatches(numbered, budget: chunkChars)
        guard !batches.isEmpty else { onResult?("reconcile", nil); return }
        reconcileRemaining = batches.count
        reconcileAcc = []
        for body in batches {
            enqueue("reconcile-part", TranscriptReconciler.instruction() + " " + body)
        }
    }

    // The final-format prompt (single fitting text → the user-facing output).
    // The speakers view is template-agnostic; the default (summary) prompt comes
    // from the template registry — .meeting is byte-for-byte the legacy prompt.
    private func finalPrompt(_ tag: String, _ t: String) -> String {
        switch tag {
        case "speakers":
            return "다음 회의록을 화자별로 정리하세요. 회의록과 같은 언어로. "
                + "각 화자마다 '■ 이름: 핵심 발언 1문장. 맡은 일: - 할 일'(맡은 일 없으면 그 부분 생략). "
                + "다른 말 없이 이 형식만. 회의록: \(t)" + foldStyleSuffix
        default:
            return foldTemplate.finalPrompt(transcript: t, styleSuffix: foldStyleSuffix)
        }
    }
    // Intermediate "condense" prompt — what a chunk must preserve is
    // template-shaped (SummaryTemplate.condensePrompt; .meeting = legacy).
    private func condensePrompt(_ t: String) -> String {
        foldTemplate.condensePrompt(chunk: t)
    }

    private func beginFold(_ lines: [String], finalTag: String,
                           template: SummaryTemplate = .meeting, styleSuffix: String = "") {
        foldTemplate = template
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
        // live-rail rides its own lane (30); live-summary DELIBERATELY falls to
        // .postSession (10) with everything else — the rolling summary is the
        // least urgent work this engine does, and captions (80/100) outrank both.
        let priority: DNAEngineBroker.Priority = tag == "live-rail" ? .liveRail : .postSession
        broker.submit(client: clientID, prompt: prompt, priority: priority,
                      preserveNewlines: true) { [weak self] text in
            self?.complete(tag, text)
        }
    }

    private func complete(_ tag: String, _ text: String?) {
        let out = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tag == "reconcile-part" {
            if !out.isEmpty, out.uppercased() != "OK" { reconcileAcc.append(out) }
            reconcileRemaining -= 1
            if reconcileRemaining <= 0 {
                let joined = reconcileAcc.joined(separator: "\n")
                onResult?("reconcile", joined.isEmpty ? "OK" : joined)
            }
            return
        }
        if tag == "fold" {
            // Sanitize each condense reply so 2B repetition loops / think leaks
            // never feed the next fold round (they'd compound).
            let cleaned = SummaryReplySanitizer.sanitize(out, headMarker: "[요약]")
            if !cleaned.isEmpty { foldAcc.append(cleaned) }
            foldRemaining -= 1
            if foldRemaining <= 0 { runFoldRound(foldAcc) }
            return
        }
        if tag == "summary" || tag == "speakers" || tag == "live-summary" {
            // live-summary replies are headerless bullet lists — the sanitizer's
            // dedupe + default line cap still guard the runaway modes, and the
            // head-marker miss just falls through to the longest-segment rule.
            let cleaned = SummaryReplySanitizer.sanitize(
                out, headMarker: tag == "speakers" ? "■" : "[요약]")
            onResult?(tag, cleaned.isEmpty ? nil : cleaned)
            return
        }
        onResult?(tag, out.isEmpty ? nil : out)
    }
}
