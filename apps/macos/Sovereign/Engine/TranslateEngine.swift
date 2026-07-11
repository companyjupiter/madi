// TranslateEngine.swift — drives the bundled sovereign DNA3.0-4B Metal engine for
// on-device translation. Spawns the engine once, feeds each committed segment as a
// single-turn chat (the engine is STATELESS per line → independent translations,
// no reset), and returns the translated text.
//
// Engine I/O (verified from sovereignLLM/apps/metal-dna3-4b-q4km/main.zig):
//   launch: translate-engine <model.gguf> → prints READY
//   stdin : ONE line = one chat turn (\n-delimited!). The chat template +
//           tokenize + generate + DETOKENIZE happen inside; thinking is disabled.
//   stdout: framed by TranslateStreamParser — the reply STREAMS token-by-token
//           (~19 ms/tok measured), surfaced incrementally via onPartial and
//           finalized on the "[perf] generation" line via onResult.
//
// CRITICAL: the prompt MUST be a single line (no '\n') or the engine splits it
// into multiple turns — so the instruction + text are one line and any newline in
// the segment text is collapsed to a space.

import Foundation

@MainActor
final class TranslateEngine {
    /// (lineID, target language name, translated text, source text) per completed turn.
    var onResult: ((UUID, String, String, String) -> Void)?
    /// Streaming in-progress translation (same keys; text = accumulated so far).
    /// Echo-gated: not fired while the reply is still a prefix of the source, so a
    /// verbatim echo (the 4B failure mode) never streams to the UI.
    var onPartial: ((UUID, String, String) -> Void)?
    /// Language written FIRST when several targets queue for one line — the
    /// caption's display language. Without it, sorted-append + LIFO pop meant
    /// the alphabetically-last language always translated first (T3).
    var priorityLang: String?
    /// Queued + in-flight turn count, fired whenever it changes (D20 status).
    var onQueueChange: ((Int) -> Void)?

    private let broker = DNAEngineBroker.shared
    private let clientID = UUID()
    private var lastPartialEmit = ContinuousClock.now

    private struct Turn {
        let id: UUID; let lang: String; let source: String
        let prompt: String; let prefix: String?; let body: String?
        var retries: Int
    }
    private var ready = false
    // Live-priority scheduling: hold turns in a stack and write them NEWEST-FIRST,
    // one at a time. During a meeting the line you're looking at (the most recent)
    // gets translated before an older backlog; starved old turns drain at the next
    // pause / at stop (finalize re-runs the full pass), so nothing is permanently
    // skipped — it's reordered, not dropped.
    private var pending: [Turn] = []   // not-yet-sent; popLast() = newest
    private var inflightTurn: Turn?    // the single turn currently generating
    private var registeredPrefixes: Set<String> = []
    private var registeringPrefixes: Set<String> = []
    private var disabledPrefixes: Set<String> = []
    /// Live queue cap (turns). 0 = unbounded. When the newest-first stack grows
    /// past this — fast speech the engine can't keep up with — the OLDEST turns
    /// are shed (reported via onDrop for backfill at stop) so live captions track
    /// the newest speech instead of the backlog ballooning to 100+ lines.
    var maxPending = 0
    /// Called with the LINE id of each turn shed by the cap. The session records
    /// these and re-translates them (uncapped) at stop, so the saved record stays
    /// complete — the drop only defers them out of the live path.
    var onDrop: ((UUID) -> Void)?

    func start(engine: URL, model: URL) -> Bool {
        broker.attach(client: clientID, engine: engine, model: model) { [weak self] in
            guard let self else { return }
            self.ready = true
            self.pump()
        }
    }

    func stop() {
        broker.detach(client: clientID)
        ready = false; pending.removeAll(); inflightTurn = nil
        registeredPrefixes.removeAll(); registeringPrefixes.removeAll(); disabledPrefixes.removeAll()
    }

    /// Queue a translation of `text` into each of `targets` (English language
    /// names, e.g. ["Japanese","English","Chinese"]) for `id`. Results arrive via
    /// onResult per (id, lang) — the engine serializes the turns.
    // A one-word anchor in the TARGET language. DNA3.0-4B is Korean-centric and,
    // for longer Korean inputs, would "translate" KO→JA by just rephrasing in
    // Korean (verified via the engine CLI: 日 returned 한국어). A single in-target
    // example ("Hello => <anchor>") locks the model onto the target script and
    // fixes it, with no echo and no regression for 中/EN. (Quality lever beyond
    // this = the 9B model — deferred A/B.)
    private static let anchor: [String: String] =
        ["Korean": "안녕하세요", "English": "Hello", "Japanese": "こんにちは", "Chinese": "你好"]
    // Retry variant: the engine decodes GREEDILY with a per-turn state reset, so
    // re-sending the IDENTICAL prompt after an echo re-produces the identical
    // echo — the old retry only "worked" by cross-turn state accident. A retry
    // must CHANGE the tokens: swap the one-shot example (different trajectory).
    private static let anchor2: [String: String] =
        ["Korean": "감사합니다", "English": "Thank you", "Japanese": "ありがとうございます", "Chinese": "谢谢"]

    private static func prompt(for target: String, text: String, variant: Bool) -> String {
        prefix(for: target, variant: variant) + text + " =>"
    }

    private static func prefix(for target: String, variant: Bool) -> String {
        let a = (variant ? anchor2[target] : anchor[target]) ?? "Hello"
        let ex = variant ? "Thank you" : "Hello"
        return "Translate the following into \(target). Reply with only the translation in \(target), no notes. Example — \(ex) => \(a) . Now: "
    }

    private static let prefixSlot = ["Korean": 0, "English": 1, "Japanese": 2, "Chinese": 3]

    func translate(_ text: String, into targets: [String], id: UUID) {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return }
        // priority language is appended LAST → popLast() serves it FIRST
        var ordered = targets
        if let p = priorityLang, let i = ordered.firstIndex(of: p) {
            ordered.remove(at: i); ordered.append(p)
        }
        for target in ordered {
            pending.append(Turn(id: id, lang: target, source: oneLine,
                                prompt: Self.prompt(for: target, text: oneLine, variant: false),
                                prefix: Self.prefix(for: target, variant: false), body: oneLine + " =>", retries: 1))
        }
        // Live cap: shed the OLDEST turns (front of the stack) past maxPending.
        // popLast() serves newest-first, so the front holds the stalest backlog —
        // exactly what a live caption no longer needs. Dropped lines → onDrop.
        if maxPending > 0 {
            while pending.count > maxPending {
                let shed = pending.removeFirst()
                onDrop?(shed.id)
            }
        }
        pump()
        reportQueue()
    }

    private func reportQueue() { onQueueChange?(pending.count + (inflightTurn != nil ? 1 : 0)) }

    /// Write the NEXT turn (newest pending) iff the engine is free. One turn in
    /// flight at a time — the DNA3 REPL generates one reply per prompt.
    private func pump() {
        guard ready, inflightTurn == nil, let turn = pending.last else { return }
        if let prefix = turn.prefix, let slot = Self.prefixSlot[turn.lang],
           !registeredPrefixes.contains(turn.lang), !disabledPrefixes.contains(turn.lang) {
            guard registeringPrefixes.insert(turn.lang).inserted else { return }
            broker.registerPrefix(client: clientID, slot: slot, text: prefix) { [weak self] ok in
                guard let self else { return }
                self.registeringPrefixes.remove(turn.lang)
                if ok { self.registeredPrefixes.insert(turn.lang) }
                else { self.disabledPrefixes.insert(turn.lang) }
                self.pump()
            }
            return
        }
        _ = pending.popLast()
        inflightTurn = turn
        let wirePrompt: String
        if let body = turn.body, let slot = Self.prefixSlot[turn.lang], registeredPrefixes.contains(turn.lang) {
            wirePrompt = "%%TRN \(slot) \(body)"
        } else {
            wirePrompt = turn.prompt
        }
        broker.submit(client: clientID, prompt: wirePrompt, priority: .committedCaption,
            onPartial: { [weak self] text in
                guard let self else { return }
                let now = ContinuousClock.now
                guard now - self.lastPartialEmit > .milliseconds(80) else { return }
                self.lastPartialEmit = now
                self.emitPartial(text)
            }, completion: { [weak self] text in self?.completeTurn(text ?? "") })
        reportQueue()
    }

    private func emitPartial(_ text: String) {
        guard let turn = inflightTurn, !text.isEmpty else { return }
        // echo gate: while the reply is still a (normalized) prefix of the source
        // it may be a verbatim echo — hold streaming until it diverges. A real
        // cross-script translation diverges at the first token.
        if Self.norm(turn.source).hasPrefix(Self.norm(text)) { return }
        onPartial?(turn.id, turn.lang, text)
    }

    private func completeTurn(_ text: String) {
        guard let turn = inflightTurn else { return }
        inflightTurn = nil
        defer { pump(); reportQueue() }              // start the next turn
        // Failure mode: the 4B sometimes echoes the source verbatim instead of
        // translating (a cross-turn sampling-state effect — see LIVE_TRANSLATE
        // P4). Normalize-compare; retry, then SUPPRESS (don't show the source
        // masquerading as a translation) rather than emit an echo.
        if !text.isEmpty, Self.norm(text) == Self.norm(turn.source) {
            if turn.retries > 0 {
                // retry with the VARIANT prompt (different example tokens →
                // different greedy trajectory); same-prompt retries are no-ops.
                pending.append(Turn(id: turn.id, lang: turn.lang, source: turn.source,
                                    prompt: Self.prompt(for: turn.lang, text: turn.source, variant: true),
                                    prefix: nil, body: nil,
                                    retries: turn.retries - 1))
            }
            return   // retry pending, or suppress the echo
        }
        if !text.isEmpty { onResult?(turn.id, turn.lang, text, turn.source) }
    }

    private static func norm(_ x: String) -> String {
        x.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.。!?！？\"'"))
    }
}
