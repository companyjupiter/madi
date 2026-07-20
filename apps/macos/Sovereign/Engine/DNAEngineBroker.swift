// DNAEngineBroker.swift — one resident DNA3 process shared by live translation,
// action rail, summary, reconcile, and Q&A. Requests are priority-serialized so
// Metal never runs two model-sized DNA processes concurrently.

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
        let onPartial: ((String) -> Void)?
        let completion: (String?) -> Void
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

    private init() {}

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

        let p = Process()
        let input = Pipe(), output = Pipe()
        p.executableURL = engine
        p.arguments = [model.path]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SOV_DEBUG")
        env["SOV_NSTEPS"] = "512"
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
            clients.remove(client); readyCallbacks.removeValue(forKey: client)
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
            text: oneLine(prompt), preserveNewlines: preserveNewlines,
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
            text: oneLine(text), preserveNewlines: false, onPartial: nil,
            completion: { completion($0 != nil) }))
        reportBusy()
        pump()
    }

    func cancelPending(client: ClientID) {
        pending.removeAll { $0.client == client }
        reportBusy()
    }

    private func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pump() {
        guard ready, active == nil, !pending.isEmpty, stdinPipe != nil else { return }
        let index = pending.indices.max { a, b in
            let x = pending[a], y = pending[b]
            // FIFO inside one priority lane preserves transcript order for the
            // summary map/fold. Translation already applies newest-first before
            // submitting its single active turn to the broker.
            return x.priority == y.priority ? x.sequence > y.sequence : x.priority < y.priority
        }!
        let request = pending.remove(at: index)
        guard clients.contains(request.client) else { pump(); return }
        active = request
        reportBusy()
        parser = TranslateStreamParser(preserveNewlines: request.preserveNewlines)
        switch request.kind {
        case .turn:
            write(request.text + "\n")
        case .prefix(let slot):
            write("%%PFX \(slot) \(request.text)\n")
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
                if clients.contains(request.client) { request.completion("PFX_OK") }
                pump()
                reportBusy()
            case .replyDelta(let text):
                guard let request = active, clients.contains(request.client) else { continue }
                request.onPartial?(text)
            case .turnComplete(let text):
                guard let request = active else { continue }
                active = nil
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
        let callbacks = pending + (active.map { [$0] } ?? [])
        for request in callbacks where clients.contains(request.client) { request.completion(nil) }
        resetProcess()
    }

    private func resetProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil; stdinPipe = nil; stdoutPipe = nil
        enginePath = nil; modelPath = nil; ready = false
        pending.removeAll(); active = nil
        parser = TranslateStreamParser()
        reportBusy()
    }

    private func reportBusy() { onBusyChange?(active != nil || !pending.isEmpty) }
}
