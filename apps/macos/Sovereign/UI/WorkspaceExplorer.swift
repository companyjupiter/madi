// WorkspaceExplorer.swift — an IDE-style file tree for the save folder, sitting
// between the transcript and the control panel. Shows the auto-save directory as
// a workspace: subfolders expand, and clicking a transcript .md re-opens it in
// the view. Right-click a folder to make it the save root (workspace switch).
//
// Backed by SessionController.workspace (a WorkspaceTree) so it stays in sync
// when a session auto-saves or the save folder changes.

import SwiftUI
import AppKit

struct WorkspaceExplorer: View {
    @Bindable var session: SessionController
    @Binding var isVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Colors.separator)
            if session.workspace.nodes.isEmpty {
                emptyState
            } else {
                List {
                    OutlineGroup(session.workspace.nodes, children: \.children) { node in
                        row(node)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 260)
        .background(
            Theme.Colors.surface
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(Theme.Colors.separator, lineWidth: 1))
        )
        .padding(.vertical, 12)
        .padding(.leading, 12)
    }

    // MARK: header — workspace name + actions

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.Colors.accent)
            Text(session.workspace.root.lastPathComponent)
                .font(Theme.Fonts.section).foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .help(session.workspace.root.path)
            Spacer(minLength: 4)
            Button { session.workspace.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("새로고침")
            Button { chooseFolder() } label: { Image(systemName: "folder.badge.gearshape") }
                .buttonStyle(.plain).help("작업 폴더 변경…")
            Button { isVisible = false } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.plain).help("탐색기 닫기")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.Colors.textSecondary)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 26, weight: .light)).foregroundStyle(Theme.Colors.textTertiary)
            Text("이 폴더에 저장된 회의록이 없습니다")
                .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 12)
    }

    // MARK: a tree row

    private func row(_ node: FileNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(node))
                .font(.system(size: 12))
                .foregroundStyle(node.isTranscript ? Theme.Colors.accent : Theme.Colors.textTertiary)
                .frame(width: 16)
            Text(node.name)
                .font(Theme.Fonts.status)
                .foregroundStyle(node.isDir ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isTranscript { session.openArchived(node.url) }
            else if !node.isDir { reveal(node.url) }
            // folders expand via the disclosure chevron (OutlineGroup)
        }
        .contextMenu {
            if node.isDir {
                Button("이 폴더를 저장 위치로") { session.autoSaveFolder = node.url }
            } else if node.isTranscript {
                Button("회의록 열기") { session.openArchived(node.url) }
            }
            Button("Finder에서 보기") { reveal(node.url) }
        }
        .help(node.url.path)
    }

    private func icon(_ node: FileNode) -> String {
        if node.isDir { return "folder" }
        switch node.ext {
        case "md":            return "doc.text"
        case "txt":           return "doc.plaintext"
        case "srt", "vtt":    return "captions.bubble"
        case "csv":           return "tablecells"
        case "html":          return "rectangle.on.rectangle.angled"
        case "wav", "m4a", "mp3": return "waveform"
        default:              return "doc"
        }
    }

    private func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Pick a new workspace folder — same NSOpenPanel as Settings, but it also
    /// repoints the tree (the autoSaveFolder didSet calls workspace.setRoot).
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.autoSaveFolder
        if panel.runModal() == .OK, let url = panel.url { session.autoSaveFolder = url }
    }
}
