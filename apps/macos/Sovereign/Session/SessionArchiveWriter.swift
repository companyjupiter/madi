import Foundation
import Observation

/// Session-scoped Markdown persistence. A failed write never advances the
/// saved-file pointer; checkpoints update the same file until reset().
@Observable @MainActor
final class SessionArchiveWriter {
    private(set) var transcriptURL: URL?
    private(set) var lastError: String?
    private let fm: FileManager

    init(fileManager: FileManager = .default) { fm = fileManager }
    func reset() { transcriptURL = nil; lastError = nil }

    @discardableResult
    func saveTranscript(_ markdown: String, folder: URL, base: String) -> Bool {
        let destination = transcriptURL ?? availableURL(folder: folder, base: base)
        return attempt {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try markdown.write(to: destination, atomically: true, encoding: .utf8)
            transcriptURL = destination
        }
    }

    @discardableResult
    func saveSummary(_ summary: String) -> Bool {
        guard let transcriptURL else { return false }
        let base = transcriptURL.deletingPathExtension().lastPathComponent
        let destination = availableURL(folder: transcriptURL.deletingLastPathComponent(), base: "\(base) 요약")
        return attempt {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# \(base) — 회의 요약\n\n\(summary)\n".write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    func rename(to title: String, folder: URL) -> Bool {
        guard let source = transcriptURL else { return false }
        let destination = availableURL(folder: folder, base: title)
        return attempt {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: destination)
            transcriptURL = destination // transcript move succeeded, even if companion fails
            let oldBase = source.deletingPathExtension().lastPathComponent
            let oldSummary = source.deletingLastPathComponent().appendingPathComponent("\(oldBase) 요약.md")
            if fm.fileExists(atPath: oldSummary.path) {
                let newBase = destination.deletingPathExtension().lastPathComponent
                let newSummary = availableURL(folder: folder, base: "\(newBase) 요약")
                try fm.moveItem(at: oldSummary, to: newSummary)
            }
        }
    }

    private func availableURL(folder: URL, base: String) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension("md")
        var suffix = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension("md")
            suffix += 1
        }
        return url
    }
    private func attempt(_ operation: () throws -> Void) -> Bool {
        do { try operation(); lastError = nil; return true }
        catch { lastError = error.localizedDescription; return false }
    }
}
