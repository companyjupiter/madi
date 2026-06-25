// VoiceprintStore — Foundation-only management of the enrolled-voiceprint files
// that live in `~/Application Support/Madi/voiceprints/<name>.vec`.
//
// The enrollment engine writes `<name>.vec` (one centroid per named speaker) and
// the next live session loads them to auto-label recognized voices. Until now those
// files were invisible — the user could not see, rename, or delete an enrolled voice.
// This core backs the management UI (VoiceprintManagementView): list / rename / delete.
//
// Design notes:
//   • Always reads the directory fresh (no cache) so it can never drift from disk —
//     a .vec deleted in Finder, or written by the engine mid-use, is reflected at the
//     next list() call. PeopleAnalytics.aggregate() also lists dynamically, so both
//     stay consistent with the filesystem with no shared manifest to keep in sync.
//   • Only top-level `*.vec` basenames are surfaced; the engine's `.last/` scratch
//     directory (per-session centroids spk<id>.vec) is a hidden dotfile dir and is
//     skipped, so it never appears as a "voice" the user can manage.
//   • All mutations are best-effort and non-throwing at the call site's discretion:
//     the methods return a Bool so the UI can show success/failure without a crash.
//
// No SwiftUI / AppKit — pure Foundation so it unit-tests headless in SovereignCore.
import Foundation

/// Lists / renames / deletes the `<name>.vec` voiceprint files in a directory.
/// Reads disk on every call — no in-memory cache to fall out of sync.
struct VoiceprintStore {

    /// The directory holding `<name>.vec` files (SessionController.voiceprintsDir).
    let directory: URL
    private let fm = FileManager.default

    init(directory: URL) { self.directory = directory }

    /// Enrolled voice names (the `<name>` of each top-level `<name>.vec`), sorted
    /// case-insensitively. Skips the engine's hidden `.last/` scratch directory and
    /// any non-.vec file. Reads disk fresh each call.
    func list() -> [String] {
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        return entries
            .filter { $0.pathExtension == "vec" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// True if a voiceprint with this (sanitized) name exists on disk.
    func exists(_ name: String) -> Bool {
        fm.fileExists(atPath: url(for: name).path)
    }

    /// The on-disk URL for a given voice name (sanitizes "/" the same way
    /// SessionController.enrollVoiceprint does, so names round-trip identically).
    func url(for name: String) -> URL {
        directory.appendingPathComponent("\(sanitize(name)).vec")
    }

    /// Delete an enrolled voice. Returns true if the file is gone afterward
    /// (already-absent counts as success — the desired end state holds).
    @discardableResult
    func delete(_ name: String) -> Bool {
        let target = url(for: name)
        if !fm.fileExists(atPath: target.path) { return true }
        do { try fm.removeItem(at: target); return true }
        catch { return false }
    }

    /// Rename an enrolled voice (`<old>.vec` → `<new>.vec`). No-op success if the
    /// trimmed names are equal. Fails (returns false) if `old` is missing, `new` is
    /// empty, or a different voice already owns `new` (no silent overwrite).
    @discardableResult
    func rename(_ old: String, to new: String) -> Bool {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let src = url(for: old)
        let dst = url(for: trimmed)
        guard fm.fileExists(atPath: src.path) else { return false }
        if src.path == dst.path { return true }                  // same name → done
        if fm.fileExists(atPath: dst.path) { return false }       // collision → refuse
        do { try fm.moveItem(at: src, to: dst); return true }
        catch { return false }
    }

    /// Replace "/" (path separator) with "_" so a name can never escape the
    /// directory — identical to SessionController.enrollVoiceprint's sanitation.
    func sanitize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
    }
}
