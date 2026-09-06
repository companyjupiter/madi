import Foundation
import AppKit

// Debug mode (2026-09-06, docs/DEBUG_MODE.md): one bundle per session under
// ~/Library/Application Support/Madi/debug/<stamp>/ with every stream a live
// bug hunt has needed — the exact engine bytes (EngineProcess tees them), the
// store's boundary/merge decisions (TranscriptStore/WordMerger), every
// translation turn (TranslateEngine), watchdog events and a memory time
// series (here). Off by default; Settings → 진단, or MADI_DEBUG=1.
extension SessionController {

    static var debugCaptureEnabled: Bool {
        if ProcessInfo.processInfo.environment["MADI_DEBUG"] != nil { return true }
        return UserDefaults.standard.bool(forKey: "debugCapture")
    }

    static var debugRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Madi/debug", isDirectory: true)
    }

    /// Open the bundle for this session and write the manifest.
    func debugSessionStart() {
        DebugLog.stop()
        guard Self.debugCaptureEnabled, let dbg = DebugLog.start(root: Self.debugRoot) else { return }
        let cfg = makeConfig()
        let manifest: [String: Any] = [
            "app": AppVersion.full, "build": AppVersion.build,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "ramGB": Int(ProcessInfo.processInfo.physicalMemory >> 30),
            "chip": Self.sysctlString("machdep.cpu.brand_string") ?? "?",
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "translateTargets": translateTargets.sorted(),
            "translateModel": "\(AssetManifest.translateModelVariant)",
            "glossaryEntries": glossary.entries.count,
            "biasTerms": cfg.biasTerms.count,
            "diarize": diarize, "speakerCount": speakerCount.rawValue, "maxSpeakers": cfg.maxSpeakers,
            "livePreview": livePreviewEnabled,
            "languageTokenID": cfg.languageTokenID ?? -1,
            "encoderF16Cache": cfg.encoderF16Cache,
            "sttModel": cfg.modelURL.path,
            "translateEngine": AssetManifest.translateEngineURL?.path ?? "",
            "liveFeatureWiring": ["interimTranslation": LiveFeatureWiring.interimTranslation,
                                  "liveSummary": LiveFeatureWiring.liveSummary,
                                  "tailTranslationWaitsForPreview": LiveFeatureWiring.tailTranslationWaitsForPreview,
                                  "joinSameSpeakerNeighbors": LiveFeatureWiring.joinSameSpeakerNeighbors,
                                  "settledLedger": LiveFeatureWiring.settledLedger,
                                  "turnHeadAdoption": LiveFeatureWiring.turnHeadAdoption,
                                  "translationStreaming": LiveFeatureWiring.translationStreaming],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            dbg.write(text + "\n", to: "session.json")
        }
        dbg.emit("session", "start", ["app": AppVersion.full])
        debugMemTask?.cancel()
        debugMemTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.debugMemSample()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// Record the session's final tag and close the bundle once the stop-time
    /// backfill has had its 10 s.
    func debugSessionEnd(tag: String) {
        guard let dbg = DebugLog.shared else { return }
        dbg.emit("session", "final", ["tag": tag, "rows": transcript.lines.count])
        debugMemSample()
        debugMemTask?.cancel(); debugMemTask = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            DebugLog.shared?.emit("session", "close", [:])
            DebugLog.stop()
        }
    }

    func debugWatchdog(_ ev: String, _ fields: [String: Any]) {
        DebugLog.shared?.emit("watchdog", ev, fields)
    }

    /// App footprint/RSS via task_info; engine RSS/CPU via one `ps` over the
    /// processes living in this bundle's MacOS/ directory (no pid plumbing).
    func debugMemSample() {
        guard let dbg = DebugLog.shared else { return }
        var fields: [String: Any] = [:]
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            fields["appFootprintMB"] = Int(info.phys_footprint >> 20)
            fields["appResidentMB"] = Int(info.resident_size >> 20)
        }
        let macos = Bundle.main.executableURL?.deletingLastPathComponent().path ?? ""
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,rss=,%cpu=,comm="]
        let pipe = Pipe(); ps.standardOutput = pipe; ps.standardError = FileHandle.nullDevice
        if (try? ps.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            var procs: [[String: Any]] = []
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4, parts[3].hasPrefix(macos), let pid = Int(parts[0]),
                      let rss = Int(parts[1]), let cpu = Double(parts[2]) else { continue }
                procs.append(["pid": pid, "name": String(parts[3].split(separator: "/").last ?? ""),
                              "rssMB": rss / 1024, "cpu": cpu])
            }
            fields["procs"] = procs
        }
        dbg.emit("mem", "sample", fields)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func revealDebugBundles() {
        try? FileManager.default.createDirectory(at: debugRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(debugRoot)
    }
}
