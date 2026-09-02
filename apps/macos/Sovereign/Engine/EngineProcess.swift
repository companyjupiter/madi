// EngineProcess.swift — spawn and drive the resident `transcribe` STREAM engine.
//
// Process isolation by design: the engine is the bit-validated binary from
// metal/out/transcribe; the app NEVER links it. We keep one instance resident
// (model loaded once), feed "<offset> <wav>" job lines on stdin as capture
// segments close, and stream-parse stdout into EngineEvents on a background
// queue. FLUSH finalizes the session (SPKFIX/SPKOV relabel) and the engine
// answers <<FLUSH_END>>.

import Foundation

@MainActor
protocol EngineProcessDelegate: AnyObject {
    func engineDidBecomeReady()
    func engine(didEmit event: EngineEvent)
    func engineDidFlush()
    func engine(didTerminate code: Int32)
    func engine(didEmitStructured event: StructuredEvent)
}

extension EngineProcessDelegate {
    func engine(didEmitStructured event: StructuredEvent) {}
}

final class EngineProcess {
    weak var delegate: EngineProcessDelegate?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let decoder = EngineProtocol.Decoder()
    private let ioQueue = DispatchQueue(label: "sovereign.engine.io")
    private var lineBuffer = Data()
    private let eventsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("madi-engine-\(UUID().uuidString).events.jsonl")
    private var eventsOffset: UInt64 = 0
    private var eventsRemainder = Data()

    struct Config {
        var binaryURL: URL          // …/Contents/MacOS/transcribe
        var modelURL: URL           // Application Support/model.safetensors
        var bpeURL: URL             // bundled WHISPER_BPE.bin
        var assetsDir: URL          // bundled assets-small/ (cwd for relative asset loads)
        var diarize = true
        var osd = true
        var languageTokenID: Int?   // nil = auto
        var maxSpeakers = 8
        /// FIXED speaker count (화자 N명 고정). nil = auto (silhouette). When set,
        /// the engine clusters to EXACTLY this many speakers (no auto-K, no K=1
        /// collapse) and routes acoustically-distant windows to a single Unknown
        /// bucket (DIAR_K env). Distinct from `maxSpeakers` (DIAR_MAXK = the auto
        /// upper bound). Was never wired → "2명 고정" behaved as "up to 2, auto".
        var fixedK: Int?
        var vadProb: Double?        // per-speaker-count Silero gate; nil = engine default 0.5
        var voiceprintsDir: URL?
        var streamWavRoots: [URL] = []
        var fileURL: URL?           // set ⇒ native FILE mode (batched, fast); nil ⇒ live STREAM
        /// T12 bidirectional pair: whisper language token ids the engine may
        /// re-probe between EVERY segment (e.g. [50264, 50266] for a KO staff ↔
        /// JA patient conversation). Empty = session-locked single language.
        var langCandidates: [Int] = []
        /// S1 anchor mode: seed diarization centroids from the enrolled
        /// voiceprints, so a known voice (clinic staff) is VERIFIED against a
        /// fixed reference instead of re-discovered by clustering.
        var anchorVoiceprints = false
        /// 24GB+ mode: expand encoder Q8 weights once (~1.25GB) and remove
        /// per-segment dequant dispatches. The preview lane reuses this process.
        var encoderF16Cache = false
        /// S4 decode-time term biasing (PROMPT env): domain vocabulary encoded once
        /// as `<|startofprev|>` context so the decoder leans toward these surface
        /// forms. Empty = off. Terms must be RELEVANT to the session — measured
        /// 2026-08-27 (docs/ENGINE_EVAL.md S4): a matched glossary lifted rare-word
        /// recovery 32.7% → 51.0% (CER 7.50 → 7.00), while a deliberately
        /// MISMATCHED one made CER worse than no glossary at all (7.97%).
        var biasTerms: [String] = []
    }

    private let config: Config
    init(config: Config) { self.config = config }

    // MARK: lifecycle

    func start() throws {
        process.executableURL = config.binaryURL
        process.currentDirectoryURL = config.assetsDir   // engine reads some assets by relative path

        var env = ProcessInfo.processInfo.environment
        env["EVENTS_FILE"] = eventsURL.path
        env["CONF"] = "1" // emit per-word confidence «conf x.xx» for low-conf highlighting
        env["DIAR"] = config.diarize ? "1" : "0"
        env["OSD"] = config.osd ? "1" : "0"
        if config.encoderF16Cache { env["ENC_F16_CACHE"] = "1" }
        env["DIAR_MAXK"] = String(config.maxSpeakers)
        // FIXED-K (화자 N명 고정): set BEFORE the file/stream branch so it reaches
        // both native FILE mode (diarizeEmb) and live STREAM mode (liveRecluster).
        // Unset = auto-K. This is the fix for "화자 고정해도 자동 분리".
        if let k = config.fixedK { env["DIAR_K"] = String(k) }
        // per-speaker-count speech-gate optimum (bench/VAD_TUNING.md)
        if let p = config.vadProb { env["VAD_PROB"] = String(format: "%.2f", p) }
        if let lang = config.languageTokenID { env["WHISPER_LANG_ID"] = String(lang) }
        // S4: decode-time biasing toward the user's own vocabulary. Set for BOTH
        // file and stream modes — the engine encodes it once at startup.
        if !config.biasTerms.isEmpty { env["PROMPT"] = config.biasTerms.joined(separator: " ") }

        if let file = config.fileURL {
            // native FILE mode: 30s-chunk batched decode + offline diarization —
            // ~3x faster than feeding the file through the live path, fewer amber
            // artifacts. APP_FILE makes it emit streaming SPK lines + <<FLUSH_END>>
            // so this same parser/flow finalizes it.
            process.arguments = [config.modelURL.path, file.path, config.bpeURL.path]
            env["APP_FILE"] = "1"
        } else {
            // live STREAM mode: model resident, segments fed on stdin
            process.arguments = [config.modelURL.path, "/dev/null", config.bpeURL.path]
            env["STREAM"] = "1"
            // truncated encoder context (whisper.cpp audio_ctx pattern): a 10 s
            // live segment only fills 500/1500 encoder rows — auto fits the
            // window to the audio (+4.5 s EOT margin), cutting encoder latency
            // ~2× per segment. FLEURS-ko CER-gated engine-side; file mode stays
            // full-context.
            env["AUDIO_CTX"] = "auto"
            // «partial» in-decode hypothesis lines: the segment's text streams
            // onto screen while it decodes instead of all-at-once at SEG_END.
            env["PARTIALS"] = "1"
            // bidirectional language pair (T12): per-segment re-probe whitelist
            if config.langCandidates.count >= 2 {
                env["LANG_CANDIDATES"] = config.langCandidates.map(String.init).joined(separator: ",")
            }
            // S1: anchored diarization — enrolled voice = fixed reference
            if config.anchorVoiceprints { env["DIAR_ANCHOR"] = "1" }
            if !config.streamWavRoots.isEmpty {
                env["STREAM_WAV_ROOTS"] = EnginePathPolicy.pathList(config.streamWavRoots)
            }
            if let vp = config.voiceprintsDir { env["VOICEPRINTS"] = vp.path }
        }
        process.environment = env

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice  // perf/log noise on stderr

        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.delegate?.engine(didTerminate: code) }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ioQueue.async { self?.ingest(chunk) }
        }

        try process.run()
    }

    /// Feed one segment job. `offset` = global start seconds, `wav` = closed segment file.
    func feed(offset: Double, wav: URL) {
        guard EnginePathPolicy.streamWavIsAllowed(wav, roots: config.streamWavRoots) else {
            NSLog("blocked engine wav outside allowed stream roots: \(wav.path)")
            return
        }
        write(String(format: "%.3f %@\n", offset, wav.path))
    }

    /// Decode the newest still-open capture window in the same resident process.
    /// The engine serializes PREVIEW behind committed SEG jobs and emits dedicated
    /// markers, so its text is throwaway and cannot enter transcript/diar state.
    /// S2: `forced` = the open window's AGREED source prefix (the app's
    /// LocalAgreement gate — never provisional). The engine teacher-forces it and
    /// decodes only the tail, so the preview stops re-decoding the whole window
    /// every second and its shown text becomes append-only by construction. Sent
    /// only when the running engine declared `preview-fp`.
    func feedPreview(wav: URL, forced: String = "") {
        guard EnginePathPolicy.streamWavIsAllowed(wav, roots: config.streamWavRoots) else {
            NSLog("blocked preview wav outside allowed stream roots: \(wav.path)")
            return
        }
        let one = forced.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if supportsPreviewForcedPrefix, !one.isEmpty, !one.contains("%%FP") {
            write("PREVIEW \(wav.path) %%FP \(one)\n")
        } else {
            write("PREVIEW \(wav.path)\n")
        }
    }

    /// Finalize: triggers SPKFIX/SPKOV relabel then <<FLUSH_END>>.
    func flush() { write("FLUSH\n") }

    func stop() {
        flush()
        // give the engine a moment to answer FLUSH_END before tearing down;
        // the delegate's engineDidFlush() is the clean teardown signal.
    }

    func terminate() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: eventsURL)
    }

    // MARK: stdin

    private func write(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        ioQueue.async { [weak self] in
            try? self?.stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    // MARK: stdout line framing

    /// Capability tokens the running engine printed ("[caps] …", before ready).
    /// `preview-fp` = accepts `PREVIEW <wav> %%FP <text>`; an engine without it
    /// would take the marker for part of the path, so the flag gates the send.
    private(set) var capabilities: Set<String> = []
    var supportsPreviewForcedPrefix: Bool { capabilities.contains("preview-fp") }

    private func ingest(_ chunk: Data) {
        lineBuffer.append(chunk)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if line.hasPrefix("[caps] ") {
                capabilities = Set(line.dropFirst(7).split(separator: " ").map(String.init))
                continue
            }
            let event = decoder.decode(line: line)
            let structured: [StructuredEvent]
            if event == .segmentEnd || event == .flushEnd { structured = drainStructuredEvents() }
            else { structured = [] }
            Task { @MainActor in
                for item in structured { self.delegate?.engine(didEmitStructured: item) }
                self.dispatch(event)
            }
        }
    }

    /// Read only bytes appended since the previous segment barrier. A partial
    /// final JSON line is retained until the next barrier.
    private func drainStructuredEvents() -> [StructuredEvent] {
        guard let handle = try? FileHandle(forReadingFrom: eventsURL) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: eventsOffset)
            let fresh = try handle.readToEnd() ?? Data()
            eventsOffset += UInt64(fresh.count)
            eventsRemainder.append(fresh)
        } catch { return [] }
        var out: [StructuredEvent] = []
        while let nl = eventsRemainder.firstIndex(of: 0x0A) {
            let line = eventsRemainder.subdata(in: eventsRemainder.startIndex..<nl)
            eventsRemainder.removeSubrange(eventsRemainder.startIndex...nl)
            if let raw = String(data: line, encoding: .utf8), let event = EngineEvents.decode(line: raw) {
                out.append(event)
            }
        }
        return out
    }

    @MainActor
    private func dispatch(_ event: EngineEvent) {
        switch event {
        case .ready:     delegate?.engineDidBecomeReady()
        case .flushEnd:  delegate?.engineDidFlush()
        case .other:     break // diagnostics only
        default:         delegate?.engine(didEmit: event)
        }
    }
}
