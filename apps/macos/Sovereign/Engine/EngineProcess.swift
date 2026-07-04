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
}

final class EngineProcess {
    weak var delegate: EngineProcessDelegate?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let decoder = EngineProtocol.Decoder()
    private let ioQueue = DispatchQueue(label: "sovereign.engine.io")
    private var lineBuffer = Data()

    struct Config {
        var binaryURL: URL          // …/Contents/MacOS/transcribe
        var modelURL: URL           // Application Support/model.safetensors
        var bpeURL: URL             // bundled WHISPER_BPE.bin
        var assetsDir: URL          // bundled assets-small/ (cwd for relative asset loads)
        var diarize = true
        var osd = true
        var languageTokenID: Int?   // nil = auto
        var maxSpeakers = 8
        var vadProb: Double?        // per-speaker-count Silero gate; nil = engine default 0.5
        var voiceprintsDir: URL?
        var streamWavRoots: [URL] = []
        var fileURL: URL?           // set ⇒ native FILE mode (batched, fast); nil ⇒ live STREAM
        /// T12 bidirectional pair: whisper language token ids the engine may
        /// re-probe between EVERY segment (e.g. [50264, 50266] for a KO staff ↔
        /// JA patient conversation). Empty = session-locked single language.
        var langCandidates: [Int] = []
    }

    private let config: Config
    init(config: Config) { self.config = config }

    // MARK: lifecycle

    func start() throws {
        process.executableURL = config.binaryURL
        process.currentDirectoryURL = config.assetsDir   // engine reads some assets by relative path

        var env = ProcessInfo.processInfo.environment
        env["CONF"] = "1" // emit per-word confidence «conf x.xx» for low-conf highlighting
        env["DIAR"] = config.diarize ? "1" : "0"
        env["OSD"] = config.osd ? "1" : "0"
        env["DIAR_MAXK"] = String(config.maxSpeakers)
        // per-speaker-count speech-gate optimum (bench/VAD_TUNING.md)
        if let p = config.vadProb { env["VAD_PROB"] = String(format: "%.2f", p) }
        if let lang = config.languageTokenID { env["WHISPER_LANG_ID"] = String(lang) }

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
    }

    // MARK: stdin

    private func write(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        ioQueue.async { [weak self] in
            try? self?.stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    // MARK: stdout line framing

    private func ingest(_ chunk: Data) {
        lineBuffer.append(chunk)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let event = decoder.decode(line: line)
            Task { @MainActor in self.dispatch(event) }
        }
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
