// DNAEngineBroker.swift — one resident DNA3 process shared by live translation,
// action rail, summary, reconcile, and Q&A. Requests are priority-serialized so
// Metal never runs two model-sized DNA processes concurrently.
//
// WEDGE RECOVERY (2026-07-25). `active` is cleared only by the engine's own
// turn-terminating output, and pump() is gated on `active == nil`. So a turn
// that never produces "[perf] generation" stopped EVERY DNA client — live
// captions, interim captions, the action rail and the summary — permanently,
// with no log and no user-visible error. A per-request watchdog now bounds that.
//
// On expiry the process is TERMINATED and relaunched rather than drained. Why:
//
//  * The engine REPL is strictly serial (line in → prefill → generate →
//    "[perf] generation" → "> "), and silence on stdout is indistinguishable
//    from the app's side between "still generating, just slow" and "line
//    dropped, blocked on read". Draining until the next terminator therefore
//    has no bounded end on exactly the paths that wedge — it renames the wedge
//    instead of ending it.
//  * Draining while ALSO admitting new turns is worse than the wedge: a late
//    reply from the timed-out turn would be parsed as the NEXT turn's reply and
//    shown against the wrong caption. Silent wrong output beats a stall.
//  * Terminating removes both risks by construction — the fd closes, no stale
//    bytes can arrive, and the parser is reset with the process.
//  * The budget (DNATurnBudget) is derived from the engine's OWN generation cap
//    at measured throughput with a contention multiplier, so a fired watchdog
//    means the engine is outside its modelled behaviour. "Wait longer" is not a
//    recovery strategy for that. The cost paid is one model reload (READY takes
//    1.4-3.5 s), on a path that is already broken.
//
// The engine side was fixed too — its two skip paths (over-long line, empty
// line) now emit the terminator instead of dropping the turn silently
// (sovereignLLM main.zig emitEmptyTurn, both dna3-2b and dna3-4b). The watchdog
// stays as the backstop for wedges that are NOT a known skip path.

import Foundation

@MainActor
final class DNAEngineBroker {
    static let shared = DNAEngineBroker()
    var onBusyChange: ((Bool) -> Void)?

    enum Priority: Int {
        case postSession = 10
        case liveRail = 30
        case interimCaption = 80
        case committedCaption = 100
    }

    typealias ClientID = UUID
    private enum Kind { case turn, prefix(slot: Int) }
    private struct Request {
        let id: UUID
        let client: ClientID
        let kind: Kind
        let priority: Int
        let sequence: UInt64
        let text: String
        let preserveNewlines: Bool
        let enqueuedAt: Double
        let onPartial: ((String) -> Void)?
        let completion: (String?) -> Void
    }

    // ── P11: caption-pressure gate ──────────────────────────────────────────
    // Priorities protect captions from QUEUED background work, but a turn that
    // is already in flight cannot be preempted — and between two caption turns
    // there is a one-runloop gap where a queued rail/reconcile request used to
    // win the pump and then hold the single serial engine for its whole (long:
    // big prompt + up to SOV_NSTEPS output) duration. On device that read as
    // captions damming up every ~18s/45s and then bursting. While the caption
    // lane reports pressure (translate backlog), sub-caption work now WAITS —
    // it is periodic background analysis and the next tick retries — unless it
    // has already waited `backgroundAgingSeconds` (starvation valve: nonstop
    // speech never drops pressure to zero).
    private(set) var captionPressure = 0
    func reportCaptionPressure(_ depth: Int) {
        captionPressure = depth
        if depth == 0 { pump() }   // pressure cleared → release deferred work
    }
    nonisolated static let backgroundAgingSeconds: Double = 90
    /// Injectable for deterministic tests.
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }

    /// Pure selection rule (unit-tested): pick the served request among
    /// (priority, sequence, waitedSeconds) triples. Highest priority wins,
    /// FIFO inside a lane; sub-caption priorities are ineligible while
    /// captionPressure > 0 until they age past the valve.
    nonisolated static func eligibleIndex(_ items: [(priority: Int, sequence: UInt64, waitedSeconds: Double)],
                              captionPressure: Int,
                              aging: Double = DNAEngineBroker.backgroundAgingSeconds) -> Int? {
        let eligible = items.indices.filter { i in
            let it = items[i]
            if it.priority >= Priority.interimCaption.rawValue { return true }
            return captionPressure == 0 || it.waitedSeconds >= aging
        }
        return eligible.max { a, b in
            let x = items[a], y = items[b]
            return x.priority == y.priority ? x.sequence > y.sequence : x.priority < y.priority
        }
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var parser = TranslateStreamParser()
    private var clients: Set<ClientID> = []
    private var readyCallbacks: [ClientID: () -> Void] = [:]
    private var ready = false
    private var pending: [Request] = []
    private var active: Request?
    private var sequence: UInt64 = 0
    private var enginePath: String?
    private var modelPath: String?
    /// Fires when the active request outlives its budget. Cancelled the moment
    /// the engine terminates the turn.
    private var watchdog: Task<Void, Never>?
    /// Set by the watchdog so the termination handler knows this death was ours
    /// and the engine should come back.
    private var restartAfterTermination = false
    /// CONSECUTIVE wedges — reset by any turn the engine completes normally. A
    /// model/engine that wedges every turn must not respawn forever.
    private(set) var wedgeRestarts = 0
    /// Fixed per-turn budget in seconds; nil = derive it per request from
    /// DNATurnBudget. Read once from MADI_DNA_TIMEOUT_MS so a wedge can be
    /// reproduced without a rebuild, and settable so tests need not wait ~30 s.
    var turnTimeoutOverride: TimeInterval? = DNATurnBudget.override()
    private static let maxWedgeRestarts = 2
    /// The engine's own generation cap, passed as SOV_NSTEPS and used as the
    /// decode term of the watchdog budget — one source of truth.
    private static let nsteps = 512

    // internal (not private) so tests can drive an isolated broker instead of
    // the app-wide singleton.
    init() {}

    func attach(client: ClientID, engine: URL, model: URL, onReady: @escaping () -> Void) -> Bool {
        clients.insert(client)
        readyCallbacks[client] = onReady
        if let enginePath, let modelPath {
            guard enginePath == engine.path, modelPath == model.path else {
                clients.remove(client); readyCallbacks.removeValue(forKey: client)
                return false
            }
            if ready { onReady() }
            return true
        }
        guard launch(engine: engine, model: model) else {
            clients.remove(client); readyCallbacks.removeValue(forKey: client)
            return false
        }
        return true
    }

    /// Spawn the engine process. Shared by the first attach and by the
    /// post-wedge restart, so both paths get identical env/pipes/handlers.
    @discardableResult
    private func launch(engine: URL, model: URL) -> Bool {
        let p = Process()
        let input = Pipe(), output = Pipe()
        p.executableURL = engine
        p.arguments = [model.path]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SOV_DEBUG")
        env["SOV_NSTEPS"] = String(Self.nsteps)
        p.environment = env
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processTerminated() }
        }
        do {
            try p.run()
            process = p; stdinPipe = input; stdoutPipe = output
            enginePath = engine.path; modelPath = model.path
            return true
        } catch {
            return false
        }
    }

    func detach(client: ClientID) {
        clients.remove(client)
        readyCallbacks.removeValue(forKey: client)
        pending.removeAll { $0.client == client }
        reportBusy()
        guard clients.isEmpty else { return }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        resetProcess()
        wedgeRestarts = 0   // last client left: the next session starts with a full budget
    }

    @discardableResult
    func submit(client: ClientID, prompt: String, priority: Priority,
                preserveNewlines: Bool = false,
                onPartial: ((String) -> Void)? = nil,
                completion: @escaping (String?) -> Void) -> UUID {
        sequence &+= 1
        let id = UUID()
        pending.append(Request(id: id, client: client, kind: .turn,
            priority: priority.rawValue, sequence: sequence,
            text: oneLine(prompt), preserveNewlines: preserveNewlines, enqueuedAt: clock(),
            onPartial: onPartial, completion: completion))
        reportBusy()
        pump()
        return id
    }

    func registerPrefix(client: ClientID, slot: Int, text: String,
                        priority: Priority = .committedCaption,
                        completion: @escaping (Bool) -> Void) {
        sequence &+= 1
        pending.append(Request(id: UUID(), client: client, kind: .prefix(slot: slot),
            priority: priority.rawValue, sequence: sequence,
            text: oneLine(text), preserveNewlines: false, enqueuedAt: clock(), onPartial: nil,
            completion: { completion($0 != nil) }))
        reportBusy()
        pump()
    }

    /// Drop this client's QUEUED requests while it stays attached — the in-flight
    /// turn is not cancellable (the engine has already been written to and owes
    /// us a terminator). Every dropped request is completed with nil: a caller
    /// that fans out (SummaryEngine's map/fold) counts completions to know when a
    /// round is done, so silently discarding them would wedge the caller in the
    /// same way a missing terminator wedges the broker.
    func cancelPending(client: ClientID) {
        let dropped = pending.filter { $0.client == client }
        pending.removeAll { $0.client == client }
        for request in dropped where clients.contains(request.client) { request.completion(nil) }
        reportBusy()
    }

    private func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pump() {
        guard ready, active == nil, !pending.isEmpty, stdinPipe != nil else { return }
        // FIFO inside one priority lane preserves transcript order for the
        // summary map/fold. Translation already applies newest-first before
        // submitting its single active turn to the broker. P11: sub-caption
        // work is ineligible while the caption lane reports pressure.
        let now = clock()
        let triples = pending.map { (priority: $0.priority, sequence: $0.sequence,
                                     waitedSeconds: now - $0.enqueuedAt) }
        guard let index = Self.eligibleIndex(triples, captionPressure: captionPressure) else { return }
        let request = pending.remove(at: index)
        guard clients.contains(request.client) else { pump(); return }
        active = request
        reportBusy()
        parser = TranslateStreamParser(preserveNewlines: request.preserveNewlines)
        armWatchdog(for: request)
        switch request.kind {
        case .turn:
            write(request.text + "\n")
        case .prefix(let slot):
            write("%%PFX \(slot) \(request.text)\n")
        }
    }

    // MARK: - per-request watchdog

    private func armWatchdog(for request: Request) {
        watchdog?.cancel()
        // A prefix registration only prefills, so the decode term makes its
        // budget strictly more generous than it needs to be — deliberate.
        let budget = turnTimeoutOverride
            ?? DNATurnBudget.seconds(promptBytes: request.text.utf8.count,
                                     steps: Self.nsteps,
                                     rates: DNATurnBudget.rates(forEnginePath: enginePath ?? ""))
        let id = request.id
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.watchdogFired(id, budget: budget)
        }
    }

    private func disarmWatchdog() {
        watchdog?.cancel(); watchdog = nil
    }

    /// The active turn outlived its budget: the engine owes a terminator it is
    /// never going to send. Kill the process — see the file header for why this
    /// is a terminate rather than a drain. `terminationHandler` does the rest
    /// (fail the in-flight + queued requests, then relaunch).
    private func watchdogFired(_ id: UUID, budget: TimeInterval) {
        guard let request = active, request.id == id else { return }
        watchdog = nil
        NSLog("DNA engine: turn timed out after %.1fs with no [perf] generation — restarting engine (client %@)",
              budget, request.client.uuidString)
        guard let p = process else { return }   // already reset; nothing to kill
        restartAfterTermination = true
        guard p.isRunning else { return }       // dying already — the handler will land
        p.terminate()
        let pid = p.processIdentifier
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // SIGTERM is enough for a REPL blocked on read; this only covers an
            // engine stuck somewhere that ignores it.
            if self?.process === p, p.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8), let handle = stdinPipe?.fileHandleForWriting else { return }
        try? handle.write(contentsOf: data)
    }

    private func ingest(_ data: Data) {
        for event in parser.ingest(data) {
            switch event {
            case .ready:
                ready = true
                for callback in readyCallbacks.values { callback() }
                pump()
            case .prefixReady(let slot):
                guard let request = active, case .prefix(let expected) = request.kind,
                      slot == expected else { continue }
                active = nil
                disarmWatchdog(); wedgeRestarts = 0
                if clients.contains(request.client) { request.completion("PFX_OK") }
                pump()
                reportBusy()
            case .replyDelta(let text):
                guard let request = active, clients.contains(request.client) else { continue }
                request.onPartial?(text)
            case .turnComplete(let text):
                guard let request = active else { continue }
                active = nil
                disarmWatchdog(); wedgeRestarts = 0
                if clients.contains(request.client) {
                    if case .turn = request.kind { request.completion(text.isEmpty ? nil : text) }
                    else { request.completion(nil) }
                }
                pump()
                reportBusy()
            }
        }
    }

    private func processTerminated() {
        guard process != nil else { return }
        disarmWatchdog()
        let engine = enginePath.map { URL(fileURLWithPath: $0) }
        let model = modelPath.map { URL(fileURLWithPath: $0) }
        let restart = restartAfterTermination
        restartAfterTermination = false
        let orphans = pending + (active.map { [$0] } ?? [])

        // Order matters: reset (and relaunch) BEFORE firing the completions.
        // Clients submit their next request from inside the completion handler
        // (TranslateEngine.completeTurn → pump → submit), so completing first
        // would append that request to `pending` and then have resetProcess()
        // wipe it — the client would sit on an inflight turn that can never
        // complete, i.e. the same wedge one level up.
        resetProcess()
        // Only a watchdog kill respawns. A death we did not cause keeps the
        // pre-existing behaviour (fail everything, clients decide) — this change
        // is scoped to the wedge, not to crash policy.
        if restart, let engine, let model, !clients.isEmpty {
            if wedgeRestarts >= Self.maxWedgeRestarts {
                NSLog("DNA engine: wedged %d times in a row — staying down for this session", wedgeRestarts)
            } else {
                wedgeRestarts += 1
                NSLog("DNA engine: relaunching after wedge (%d/%d)", wedgeRestarts, Self.maxWedgeRestarts)
                if !launch(engine: engine, model: model) {
                    NSLog("DNA engine: relaunch failed to spawn %@", engine.path)
                }
            }
        }
        for request in orphans where clients.contains(request.client) { request.completion(nil) }

        // No engine came back: anything a completion just resubmitted is queued
        // for a pump that will never run. Fail it too, so no client is left
        // waiting on a reply that cannot arrive. Bounded — each sweep drains a
        // client's finite backlog one step further.
        var sweeps = 0
        while process == nil, !pending.isEmpty, sweeps < 64 {
            sweeps += 1
            let stranded = pending
            pending.removeAll()
            for request in stranded where clients.contains(request.client) { request.completion(nil) }
        }
        reportBusy()
    }

    private func resetProcess() {
        disarmWatchdog()
        // Consumed by processTerminated() before this runs; cleared here so a
        // watchdog kill that races a detach can't arm a restart for some LATER,
        // unrelated process death.
        restartAfterTermination = false
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil; stdinPipe = nil; stdoutPipe = nil
        enginePath = nil; modelPath = nil; ready = false
        pending.removeAll(); active = nil
        parser = TranslateStreamParser()
        reportBusy()
    }

    private func reportBusy() { onBusyChange?(active != nil || !pending.isEmpty) }
}
