// TranslateEngine.swift — drives the selected sovereign DNA3 Metal engine for
// on-device translation. Spawns the engine once, feeds interim/committed captions as a
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
    /// verbatim echo never streams to the UI.
    var onPartial: ((UUID, String, String, String) -> Void)?
    /// Language written FIRST when several targets queue for one line — the
    /// caption's display language. Without it, sorted-append + LIFO pop meant
    /// the alphabetically-last language always translated first (T3).
    var priorityLang: String?
    /// Queued + in-flight turn count, fired whenever it changes (D20 status).
    var onQueueChange: ((Int) -> Void)?

    private let broker = DNAEngineBroker.shared
    private let clientID = UUID()
    private var lastPartialEmit = ContinuousClock.now

    private var ready = false
    // Semantic-priority scheduling: committed captions always beat disposable
    // interim previews; newest-first within each lane keeps live captions current.
    private var pending = TranslationTurnQueue()
    private var inflightTurn: TranslationTurn? // the single turn currently generating
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
    var onDrop: ((UUID, String, String) -> Void)?
    /// A pending turn was superseded or preempted, so it must drain any interim
    /// barrier but MUST NOT enter stop-time backfill.
    var onDiscard: ((UUID, String, String) -> Void)?

    func start(engine: URL, model: URL) -> Bool {
        broker.attach(client: clientID, engine: engine, model: model) { [weak self] in
            guard let self else { return }
            self.ready = true
            // READY can also mean a RELAUNCHED process (broker wedge recovery),
            // whose prefix-cache slots are empty. Stale "registered" state would
            // send "%%TRN <slot> …" to an engine with pfx_ready[slot] == false,
            // which falls through to the legacy path and translates the literal
            // "%%TRN 0 " marker as part of the prompt. Re-register instead.
            self.registeredPrefixes.removeAll()
            self.registeringPrefixes.removeAll()
            self.disabledPrefixes.removeAll()
            self.pump()
        }
    }

    func stop() {
        broker.reportCaptionPressure(0)
        broker.detach(client: clientID)
        ready = false; pending.removeAll(); inflightTurn = nil
        registeredPrefixes.removeAll(); registeringPrefixes.removeAll(); disabledPrefixes.removeAll()
        lastPair.removeAll()
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
    /// T5: the example slot is per turn now (previous committed pair when usable,
    /// else the anchor) — see TranslatePrompt. The cached prefix is the head only.
    private static func prompt(for target: String, text: String, example: TranslatePrompt.Example?) -> String {
        prefix(for: target) + TranslatePrompt.body(text: text, example: example, anchor: anchor[target] ?? "Hello")
    }

    private static func prefix(for target: String) -> String {
        "Translate the following into \(target). Reply with only the translation in \(target), no notes. Example — "
    }

    /// T5: the last committed (source, translation) per target language — the
    /// discourse context the next turn's example carries. Session-scoped.
    private var lastPair: [String: TranslatePrompt.Example] = [:]

    /// Retry prompt deliberately changes both the instruction and token layout.
    /// The 2B model responds more reliably when the source language is explicit;
    /// this path is only paid after an objective echo/wrong-script failure.
    private static func repairPrompt(for target: String, text: String) -> String {
        let source = TranslationOutputPolicy.sourceLanguageName(for: text)
        return "You are a \(source)-to-\(target) translator. Return \(target) text only. Source \(source): \(text) Target \(target):"
    }

    private static let prefixSlot = ["Korean": 0, "English": 1, "Japanese": 2, "Chinese": 3]

    /// P10-1: interim starvation guarantee. The committed lane is busy almost
    /// continuously in a live session (every word event queues stable lines), and
    /// interim work is otherwise rejected whenever ANY committed turn is queued
    /// or in flight — measured on device: 4 interim turns and ONE caption update
    /// for a whole session. At most one interim turn per interval may therefore
    /// bypass the block and jump the queue, so the caption keeps breathing under
    /// a backlog. 0 disables the guarantee.
    var interimGuarantee: TimeInterval = 3.0
    /// Injectable for deterministic tests.
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private var lastInterimAcceptedAt: Double?

    /// True when no interim turn has been accepted within the guarantee window.
    /// P12 (adaptive): the effective interval stretches with committed backlog —
    /// ≤2 pending → base, ≤6 → 2× base, deeper → no reservation at all (the
    /// caption's guaranteed slot must not be what pushes committed lines into
    /// the shed path). Ordinary admission still applies when the lane is quiet.
    private func interimIsStarved() -> Bool {
        let committedBacklog = pending.turns.filter { $0.kind == .committed }.count
            + (inflightTurn?.kind == .committed ? 1 : 0)
        guard let interval = InterimTuning.adaptiveGuarantee(
            base: interimGuarantee, committedBacklog: committedBacklog) else { return false }
        guard let last = lastInterimAcceptedAt else { return true }
        return clock() - last >= interval
    }

    /// T1: only an interim turn carries a forced prefix, and only a non-empty,
    /// single-line one. The engine protocol appends it as ` %%FP <text>` to the
    /// turn line, so the marker itself must not appear inside the text.
    private static func forcedPrefix(_ shown: String?, kind: TranslationTurnKind) -> String? {
        guard kind == .interim, let s = shown else { return nil }
        let one = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !one.isEmpty, !one.contains("%%FP") else { return nil }
        return one
    }

    @discardableResult
    func translate(_ text: String, into targets: [String], id: UUID,
                   kind: TranslationTurnKind = .committed,
                   forced: [String: String] = [:]) -> Bool {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return false }
        // priority language is appended LAST → popLast() serves it FIRST
        var ordered = targets
        if let p = priorityLang, let i = ordered.firstIndex(of: p) {
            ordered.remove(at: i); ordered.append(p)
        }
        var accepted = false
        // Only the priority language claims the reservation — one guaranteed
        // turn, not one per target, so a multi-target session cannot flood the
        // committed lane with jumped interim work.
        var reservationAvailable = kind == .interim && interimIsStarved()
        for target in ordered {
            let claimsReservation = reservationAvailable && target == ordered.last
            let example = TranslatePrompt.usableExample(lastPair[target], for: oneLine)
            let turn = TranslationTurn(
                id: id, lang: target, source: oneLine,
                prompt: Self.prompt(for: target, text: oneLine, example: example),
                prefix: Self.prefix(for: target),
                body: TranslatePrompt.body(text: oneLine, example: example, anchor: Self.anchor[target] ?? "Hello"),
                retries: 1, kind: kind, reserved: claimsReservation,
                forced: Self.forcedPrefix(forced[target], kind: kind))
            let result = pending.enqueue(
                turn, blockInterim: inflightTurn?.kind == .committed)
            if result.accepted {
                if claimsReservation { reservationAvailable = false }
                if kind == .interim { lastInterimAcceptedAt = clock() }
            }
            accepted = accepted || result.accepted
            for old in result.displaced { onDiscard?(old.id, old.lang, old.source) }
        }
        // Live cap: shed the OLDEST turns (front of the stack) past maxPending.
        // popLast() serves newest-first, so the front holds the stalest backlog —
        // exactly what a live caption no longer needs. Dropped lines → onDrop.
        if maxPending > 0 {
            for shed in pending.shedOldest(to: maxPending) {
                onDrop?(shed.id, shed.lang, shed.source)
            }
        }
        pump()
        reportQueue()
        return accepted
    }

    private func reportQueue() {
        let depth = pending.count + (inflightTurn != nil ? 1 : 0)
        // P11: the broker cannot see this queue — tell it, so long background
        // turns (rail/reconcile) wait instead of damming the caption stream.
        broker.reportCaptionPressure(depth)
        onQueueChange?(depth)
    }

    /// Write the NEXT turn (newest pending) iff the engine is free. One turn in
    /// flight at a time — the DNA3 REPL generates one reply per prompt.
    private func pump() {
        guard ready, inflightTurn == nil, let turn = pending.next else { return }
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
        guard let next = pending.popNext() else { return }
        inflightTurn = next
        var wirePrompt: String
        if let body = next.body, let slot = Self.prefixSlot[next.lang], registeredPrefixes.contains(next.lang) {
            wirePrompt = "%%TRN \(slot) \(body)"
        } else {
            wirePrompt = next.prompt
        }
        // T1: forced assistant prefix — the engine prefills it and echoes it as
        // the reply head, so the streamed reply still reads as the full text.
        if let forced = next.forced, broker.supportsForcedPrefix {
            wirePrompt += " %%FP \(forced)"
            TranslationStabilityMetrics.shared.interimForcedTurns += 1
            TranslationStabilityMetrics.shared.interimForcedChars += forced.count
        }
        let priority: DNAEngineBroker.Priority = next.kind == .committed
            ? .committedCaption : .interimCaption
        broker.submit(client: clientID, prompt: wirePrompt, priority: priority,
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
        let cleaned = TranslationOutputPolicy.clean(text)
        guard !cleaned.isEmpty else { return }
        // echo gate: while the reply is still a (normalized) prefix of the source
        // it may be a verbatim echo — hold streaming until it diverges. A real
        // cross-script translation diverges at the first token.
        if Self.norm(turn.source).hasPrefix(Self.norm(cleaned)) { return }
        if TranslationOutputPolicy.shouldRetry(cleaned, source: turn.source, target: turn.lang) { return }
        onPartial?(turn.id, turn.lang, cleaned, turn.source)
    }

    private func completeTurn(_ text: String) {
        guard let turn = inflightTurn else { return }
        inflightTurn = nil
        defer { pump(); reportQueue() }              // start the next turn
        let cleaned = TranslationOutputPolicy.clean(text)
        // Both models can rarely echo; 2B can additionally stay in the source
        // script. Retry only on an objective failure, then suppress rather than
        // present invalid output as a translation.
        if TranslationOutputPolicy.shouldRetry(text, source: turn.source, target: turn.lang) {
            if turn.retries > 0 {
                let retry = TranslationTurn(
                    id: turn.id, lang: turn.lang, source: turn.source,
                    prompt: Self.repairPrompt(for: turn.lang, text: turn.source),
                    prefix: nil, body: nil, retries: turn.retries - 1, kind: turn.kind)
                // An old in-flight revision may echo after a newer revision for
                // the same line+language is already pending. Its retry must never
                // replace that newer work.
                let result = pending.enqueue(retry, replaceExisting: false)
                for old in result.displaced { onDiscard?(old.id, old.lang, old.source) }
                if !result.accepted { onDiscard?(retry.id, retry.lang, retry.source) }
            }
            if turn.retries == 0 { onResult?(turn.id, turn.lang, "", turn.source) }
            return   // retry pending, or report a completed suppressed echo
        }
        // T5: a committed line's translation becomes the next turn's example for
        // this language (interim previews are disposable and never become context).
        if turn.kind == .committed, !cleaned.isEmpty {
            lastPair[turn.lang] = TranslatePrompt.Example(source: turn.source, target: cleaned)
        }
        // Empty is a terminal result too: request-generation and backfill
        // barriers must drain even when the model returns no usable text.
        onResult?(turn.id, turn.lang, cleaned, turn.source)
    }

    private static func norm(_ x: String) -> String {
        x.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.。!?！？\"'"))
    }
}
