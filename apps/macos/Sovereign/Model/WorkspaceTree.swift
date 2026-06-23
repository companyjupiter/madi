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

    /// Cap the walk so pointing the workspace at a deep tree can't hang.
    private let maxDepth = 4

    init(root: URL) {
        self.root = root
        reload()
    }

    /// Point the tree at a new folder (workspace switch) and re-enumerate.
    func setRoot(_ url: URL) {
        root = url
        reload()
    }

    /// Re-walk the current root. Cheap for a transcripts folder; call after a
    /// session auto-saves so the new .md appears.
    func reload() {
        nodes = Self.children(of: root, depth: 0, maxDepth: maxDepth)
    }

    private static func children(of dir: URL, depth: Int, maxDepth: Int) -> [FileNode] {
        guard depth < maxDepth else { return [] }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let mapped: [FileNode] = items.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                return FileNode(url: url, isDir: true,
                                children: children(of: url, depth: depth + 1, maxDepth: maxDepth))
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
