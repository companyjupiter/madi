// WorkspaceTree.swift — the save folder rendered as an IDE-style workspace tree.
// Enumerates the auto-save directory into a recursive FileNode hierarchy that
// SwiftUI's OutlineGroup can render and expand. The app isn't sandboxed, so a
// plain FileManager walk is enough — no security-scoped bookmarks.
//
// Hidden entries (dotfiles, the .last voiceprint dump) are skipped, directories
// sort before files, and depth is capped so a workspace pointed at a huge tree
// can't stall the walk. Rescan after every session save via reload().

import Foundation
import Observation

/// One row in the workspace tree. `children == nil` ⇒ a file (leaf);
/// `children != nil` ⇒ a directory whose contents were enumerated.
struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDir: Bool
    var children: [FileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    /// A transcript the app itself produced — the primary "open me" target.
    var isTranscript: Bool { isDir == false && ext == "md" }
    /// A SEPARATE AI-summary file ("<base> 요약.md") written next to the
    /// transcript. It is a sibling of a meeting, NOT a meeting in its own right —
    /// aggregators (Open Loops / People / Prep Brief) must skip it so its items
    /// don't get counted twice. The explorer still opens it as a normal .md.
    var isSummaryFile: Bool {
        isTranscript && url.deletingPathExtension().lastPathComponent.hasSuffix(" 요약")
    }
}

@Observable
@MainActor
final class WorkspaceTree {
    private(set) var root: URL
    private(set) var nodes: [FileNode] = []
    /// True while a (re)scan is in flight — the explorer shows a loading state
    /// instead of the empty state so a big folder doesn't look like "no files".
    private(set) var isLoading = false

    /// Cap the walk so pointing the workspace at a deep OR wide tree can't hang —
    /// depth bounds how far down it goes, item count bounds how much it reads in
    /// any single directory (e.g. autoSaveFolder accidentally set to a folder
    /// full of large repos).
    private let maxDepth = 4
    private let maxItemsPerDir = 2000

    /// Monotonic token so a stale scan (root changed again before it finished)
    /// can't clobber nodes/isLoading after a newer scan already landed.
    private var generation = 0

    init(root: URL) {
        self.root = root
        reload()
    }

    /// Point the tree at a new folder (workspace switch) and re-enumerate.
    func setRoot(_ url: URL) {
        root = url
        reload()
    }

    /// Re-walk the current root off the main thread so a huge/deep folder can't
    /// hang the UI; call after a session auto-saves so the new .md appears.
    func reload() {
        generation += 1
        let gen = generation
        let scanRoot = root
        let maxDepth = self.maxDepth
        let maxItems = self.maxItemsPerDir
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let result = Self.children(of: scanRoot, depth: 0, maxDepth: maxDepth, maxItems: maxItems)
            await MainActor.run {
                guard gen == self.generation else { return }   // a newer scan already won
                self.nodes = result
                self.isLoading = false
            }
        }
    }

    private nonisolated static func children(of dir: URL, depth: Int, maxDepth: Int, maxItems: Int) -> [FileNode] {
        guard depth < maxDepth else { return [] }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let mapped: [FileNode] = items.prefix(maxItems).compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                return FileNode(url: url, isDir: true,
                                children: children(of: url, depth: depth + 1, maxDepth: maxDepth, maxItems: maxItems))
            }
            return FileNode(url: url, isDir: false, children: nil)
        }
        // Directories first, then case-insensitive name order — IDE convention.
        return mapped.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
