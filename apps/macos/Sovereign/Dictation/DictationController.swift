// DictationController.swift — system-wide push-to-talk dictation.
//
// Hold the hotkey (default Right-Option) anywhere in macOS → Madi captures the
// mic, transcribes the clip on-device with the bundled Whisper engine, and drops
// the text into whatever app is frontmost via the pasteboard + a synthetic ⌘V.
//
// This is a SEPARATE path from meeting recording on purpose:
//   • Its own AVAudioEngine tap (DictationMicTap) — it never fights the meeting
//     AudioCapture for the segmenter, only for the single physical mic, which is
//     why we hard-guard against dictating while a meeting is recording.
//   • Its own one-shot EngineProcess (start → feed one wav → flush → read words
//     on FLUSH_END → terminate). The resident meeting/summary engines are
//     untouched, so dictation works even with the LLM unloaded.
//
// Headless-untestable by nature (global event monitors, CGEvent posting, live
// mic). The pure pieces (text assembly, pasteboard swap) live in
// DictationFormatting.swift with XCTest coverage; this file is the AppKit shell.

import AVFoundation
import AppKit
import ApplicationServices

@MainActor
@Observable
final class DictationController {

    // MARK: public state (Settings binds to these)

    /// Master enable. Persisted; monitors install only while true.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { installMonitorsIfTrusted() } else { removeMonitors() }
        }
    }

    /// Live phase, surfaced to the Settings status row.
    enum State: Equatable { case idle, listening, transcribing, inserting, blocked(String) }
    private(set) var state: State = .idle

    /// True once macOS Accessibility trust is granted (required to post ⌘V).
    private(set) var accessibilityTrusted = false

    /// Closure the host sets so the controller can refuse to fire while a meeting
    /// is recording. Returns true if the shared mic is currently busy. Defaults to
    /// "never busy" so the controller is usable standalone / in previews.
    var micBusy: () -> Bool = { false }

    static let enabledKey = "dictationEnabled"

    // MARK: internals

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var holding = false

    private let tap = DictationMicTap()
    private var engine: EngineProcess?
    private var words: [String] = []
    private let pasteboard = NSPasteboardBackend()
    private var swap: PasteboardSwap<NSPasteboardBackend>?

    /// Right-Option is the default trigger: it's a modifier the user almost never
    /// uses alone, never collides with ⌘K (command palette), and is reachable
    /// one-handed. Detected via flagsChanged (key 61 = kVK_RightOption).
    private static let rightOptionKeyCode: UInt16 = 61

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        refreshTrust(prompt: false)
        if enabled { installMonitorsIfTrusted() }
    }

    // MARK: trust

    /// Re-query Accessibility trust every cycle (never cache — the user can revoke
    /// it in System Settings at any time). `prompt` shows the system grant dialog.
    @discardableResult
    func refreshTrust(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(opts)
        return accessibilityTrusted
    }

    /// Open System Settings → Privacy & Security → Accessibility.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: monitor lifecycle

    /// Install the global monitors if (and only if) we're enabled AND trusted.
    /// Called on launch, on enable-toggle, and after a trust prompt resolves.
    func installMonitorsIfTrusted() {
        removeMonitors()
        guard enabled else { return }
        guard refreshTrust(prompt: false) else { return }   // no point monitoring without trust

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] ev in
            Task { @MainActor in self?.handleFlags(ev) }
        }
    }

    func removeMonitors() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// flagsChanged fires on every modifier transition. We track Right-Option's
    /// down→up edges: down (and option flag present) starts listening, up stops
    /// and triggers transcription.
    private func handleFlags(_ ev: NSEvent) {
        guard ev.keyCode == Self.rightOptionKeyCode else { return }
        let optionDown = ev.modifierFlags.contains(.option)
        if optionDown && !holding {
            holding = true
            beginListening()
        } else if !optionDown && holding {
            holding = false
            endListeningAndInsert()
        }
    }

    // MARK: capture → transcribe → insert

    private func beginListening() {
        // Single-flight gate: refuse a new dictation while a previous one is still
        // in flight (listening / transcribing / inserting). A rapid double-tap of
        // Right-Option that lands mid-flight would otherwise `words.removeAll()` the
        // in-flight word buffer (erasing the first transcription) and orphan a
        // pending PasteboardSwap (clobbering clipboard restore). Terminal states
        // (.idle, .blocked) DO allow a restart so a transient block self-heals on
        // the next press — only genuinely-busy states are dropped.
        switch state {
        case .listening, .transcribing, .inserting: holding = false; return
        case .idle, .blocked: break
        }
        // Read mic-busy IMMEDIATELY (not stale at insert time): a live meeting owns
        // the single physical mic, so dictation NO-OPs rather than corrupt capture.
        if micBusy() { state = .blocked("회의 녹음 중에는 받아쓰기를 사용할 수 없습니다"); return }
        guard refreshTrust(prompt: false) else { state = .blocked("손쉬운 사용 권한이 필요합니다"); return }
        words.removeAll()
        state = .listening
        do { try tap.start() } catch { state = .blocked("마이크를 시작할 수 없습니다"); holding = false }
    }

    private func endListeningAndInsert() {
        guard state == .listening else { return }
        let samples = tap.stop()
        guard samples.count > Int(WavWriter.sampleRate) / 4 else {   // <0.25s = accidental tap
            state = .idle; return
        }
        state = .transcribing
        do {
            let wav = tap.scratchURL
            try WavWriter.write(samples: samples, to: wav)
            startEngineAndFeed(wav: wav)
        } catch {
            state = .idle
        }
    }

    /// Spin up a throwaway one-shot engine: text-only (no diarize/OSD), forced to
    /// the user's dictation language, feed the single clip, flush. Final words
    /// arrive in engineDidFlush().
    private func startEngineAndFeed(wav: URL) {
        var c = EngineProcess.Config(
            binaryURL: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/transcribe"),
            modelURL: AssetManifest.modelURL,
            bpeURL: AssetManifest.bundledBPE,
            assetsDir: AssetManifest.bundledAssetsDir)
        c.diarize = false
        c.osd = false
        c.languageTokenID = dictationLanguageTokenID
        c.streamWavRoots = [tap.scratchDir]
        let e = EngineProcess(config: c)
        e.delegate = self
        engine = e
        do { try e.start(); e.feed(offset: 0, wav: wav); e.flush() }
        catch { state = .idle; engine = nil }
    }

    /// Dictation language: reuse the meeting language preference (same UserDefaults
    /// key SessionController reads), defaulting to Korean. Auto-detect misfires on
    /// short clips, so we force a concrete token unless the user picked auto.
    private var dictationLanguageTokenID: Int? {
        if UserDefaults.standard.object(forKey: "languageTokenID") == nil { return 50264 } // ko default
        let v = UserDefaults.standard.integer(forKey: "languageTokenID")
        return v == 0 ? nil : v   // 0 = auto-detect
    }

    /// Assemble the captured words and drop them into the frontmost app.
    private func insert(_ text: String) {
        guard !text.isEmpty else { state = .idle; return }
        guard refreshTrust(prompt: false) else { state = .blocked("손쉬운 사용 권한이 필요합니다"); return }
        state = .inserting

        let swap = PasteboardSwap(pasteboard)
        self.swap = swap
        swap.stash()
        swap.set(text)
        postCommandV()

        // Restore the user's clipboard once the target app has had time to read our
        // paste (~150ms). The changeCount guard inside restore() backs out if a
        // second dictation or another app wrote the pasteboard in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.swap?.restore()
            self?.swap = nil
            self?.state = .idle
        }
    }

    /// Synthesize ⌘V into the frontmost app via CGEvent (requires AX trust).
    private func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - EngineProcessDelegate

extension DictationController: EngineProcessDelegate {
    func engineDidBecomeReady() {}

    func engine(didEmit event: EngineEvent) {
        if case let .word(_, _, text, _) = event {
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { words.append(t) }
        }
    }

    func engineDidFlush() {
        let text = DictationText.assemble(words)
        engine?.terminate()
        engine = nil
        insert(text)
    }

    func engine(didTerminate code: Int32) {
        engine = nil
        if state == .transcribing { state = .idle }
    }
}

// MARK: - NSPasteboard adapter

/// Concrete `PasteboardBackend` over `NSPasteboard.general`. Kept here (AppKit
/// side) so the Foundation-only formatting core stays import-clean.
final class NSPasteboardBackend: PasteboardBackend {
    private let pb = NSPasteboard.general
    var changeCount: Int { pb.changeCount }
    func readString() -> String? { pb.string(forType: .string) }
    func writeString(_ s: String) { pb.clearContents(); pb.setString(s, forType: .string) }
    func clear() { pb.clearContents() }
}

// MARK: - Dictation mic tap

/// A self-contained 16 kHz mono mic tap for one push-to-talk clip. Separate from
/// the meeting AudioCapture: no segmenter, no preview, just "start → accumulate
/// Int16 → stop returns the whole clip". Reuses Resampler for hw→16k conversion.
@MainActor
final class DictationMicTap {
    private let avEngine = AVAudioEngine()
    private var resampler: Resampler?
    private var buffer: [Int16] = []
    private var running = false

    let scratchDir: URL
    var scratchURL: URL { scratchDir.appendingPathComponent("dictation.wav") }

    init() {
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sovereign-dictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    }

    func start() throws {
        guard !running else { return }
        buffer.removeAll(keepingCapacity: true)
        let input = avEngine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard let rs = Resampler(from: hwFormat) else {
            throw NSError(domain: "DictationMicTap", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "resampler init failed"])
        }
        resampler = rs
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self, rs] buf, _ in
            let s = rs.convert(buf)
            guard !s.isEmpty else { return }
            Task { @MainActor in self?.buffer.append(contentsOf: s) }
        }
        avEngine.prepare()
        try avEngine.start()
        running = true
    }

    /// Stop the tap and return the full captured clip (drains the converter tail).
    @discardableResult
    func stop() -> [Int16] {
        guard running else { return [] }
        avEngine.inputNode.removeTap(onBus: 0)
        avEngine.stop()
        running = false
        if let rs = resampler { buffer.append(contentsOf: rs.drain()) }
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        return out
    }
}
