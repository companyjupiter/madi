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

    // Resizable column width — drag the trailing edge; persisted across launches.
    @AppStorage("explorerWidth") private var explorerWidth = 260.0
    @State private var dragStartWidth: Double? = nil
    @State private var handleHovering = false
    @State private var mode: ExplorerMode = .files
    @State private var showExportDialog = false
    private let minWidth = 180.0, maxWidth = 460.0
    // BETA: the 음성(voiceprints) mode is GONE — the voiceprint feature is unwired
    // (SessionController.voiceprintsEnabled): enrollment couldn't be undone and
    // cross-session matching misidentified speakers. VoiceprintManagementView is
    // kept in the source, just unreferenced; restore this case with the flag.
    private enum ExplorerMode: String, CaseIterable {
        case files, people, openLoops, stats
        var label: String {
            switch self {
            case .files: return "파일"
            case .people: return "사람"
            case .openLoops: return "열린 항목"
            case .stats: return "통계"
            }
        }
    }

    // Pill-shaped segmented switch (Figma node 26:14) — replaces the native
    // .segmented Picker. A single accent capsule slides between segments via
    // matchedGeometryEffect instead of each segment owning its own fill.
    @Namespace private var modeSwitcherNS

    // Redesign hides 열린 항목/음성 from the tab bar. BETA: 사람(people) is unwired —
    // it was built for cross-session VOICEPRINT aggregation, and with voiceprints
    // off a name-only list just duplicates the transcript. Its slot now holds 통계
    // (workspace activity, no voiceprints/LLM). PeopleDashboard stays in source,
    // unreferenced; the .people/.openLoops switch branches are harmless dead code.
    private static let visibleModes: [ExplorerMode] = [.files, .stats]

    // rev.2 pill (Figma 188:761): gray track, WHITE sliding thumb with a soft
    // drop shadow — matches the center 내용/상세 switch.
    private var modeSwitcher: some View {
        HStack(spacing: 1) {
            ForEach(Self.visibleModes, id: \.self) { m in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { mode = m }
                } label: {
                    Text(m.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(mode == m ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background {
                            if mode == m {
                                Capsule().fill(Theme.Colors.surface)
                                    .shadow(color: .black.opacity(0.06), radius: 1, y: 2)
                                    .matchedGeometryEffect(id: "modeSwitcherPill", in: modeSwitcherNS)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.Colors.surfaceSunken))
    }

    // Right panel (Figma 188:734): pill tabs on top, a FLAT recent-transcript
    // list (the folder tree/breadcrumb is gone — 변경 is the only folder
    // control), and a pinned bottom block: 자동저장 toggle / 폴더 row / 내보내기.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One visible mode → no lone pill; a plain header keeps the top rhythm.
            // Restore the switcher automatically when a second mode is re-added.
            if Self.visibleModes.count > 1 {
                modeSwitcher
                    .padding(.horizontal, 17).padding(.top, 19)
            } else {
                Text("회의록")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.horizontal, 20).padding(.top, 21)
            }
            switch mode {
            case .files:
                if session.workspace.isLoading {
                    loadingState
                } else if recentTranscripts.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(recentTranscripts, id: \.self) { url in
                                Button { session.openArchived(url) } label: {
                                    HStack(spacing: 7) {
                                        SVGIcon(name: "content", size: 16)
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.Colors.textPrimary)
                                            .lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(url.path)
                            }
                        }
                        .padding(.horizontal, 20).padding(.top, 22)
                    }
                }
            case .people:
                PeopleDashboard(
                    people: session.peopleAnalytics(),
                    autoRecognizedNames: Set(session.autoRecognizedSpeakers.compactMap { session.speakerNames[$0] }))
            case .openLoops:
                OpenLoopsView(session: session)
            case .stats:
                WorkspaceStatsView(stats: session.workspaceStats())
            }
            Spacer(minLength: 0)
            bottomBlock
        }
        .frame(width: 267)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Theme.Colors.surface)
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(Theme.Colors.surfaceSunken, lineWidth: 1))
                .shadow(color: .black.opacity(0.03), radius: 9, x: 4, y: 4)
        )
        .padding(.vertical, 13)
        .padding(.trailing, 13)
    }

    /// Newest transcripts across the workspace tree, flattened (modification
    /// date order) — same shape as the start screen's 최근 항목.
    private var recentTranscripts: [URL] {
        var mds: [URL] = []
        func walk(_ nodes: [FileNode]) {
            for n in nodes {
                if let kids = n.children { walk(kids) }
                else if n.isTranscript { mds.append(n.url) }
            }
        }
        walk(session.workspace.nodes)
        let fm = FileManager.default
        return mds
            .compactMap { u -> (URL, Date)? in
                guard let d = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
                else { return nil }
                return (u, d)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // MARK: pinned bottom block — 자동저장 / 폴더 / 내보내기 (Figma 188:742)

    private var bottomBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            Rectangle().fill(Theme.Colors.surfaceSunken).frame(height: 1)
            HStack {
                Text("자동저장")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                BlackToggle(isOn: $session.autoSaveEnabled)
            }
            HStack(spacing: 6) {
                Text("폴더")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                Text(session.autoSaveFolder.lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(session.autoSaveFolder.path)
                Spacer()
                Button("변경") { chooseFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)   // de-accent
            }
            exportButton
        }
        .padding(.horizontal, 19).padding(.bottom, 19)
    }

    // Outline pill (Figma 198:1328): a plain Button (not a Menu — .borderlessButton
    // menu style collapses the label, dropping the full-width capsule) that opens
    // the format picker via a confirmationDialog.
    private var exportButton: some View {
        Button { showExportDialog = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                Text("내보내기").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.Colors.textPrimary)
            .frame(maxWidth: .infinity).frame(height: 36)
            .background(Capsule().fill(Theme.Colors.surface))
            .overlay(Capsule().strokeBorder(Theme.Colors.surfaceSunken, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.transcript.lines.isEmpty)
        .opacity(session.transcript.lines.isEmpty ? 0.4 : 1)
        .confirmationDialog("내보내기 형식", isPresented: $showExportDialog, titleVisibility: .visible) {
            Button("Markdown (.md)") { export("md", session.exportMarkdown) }
            Button("Subtitles (.srt)") { export("srt", session.exportSRT) }
            Button("Subtitles (.vtt)") { export("vtt", session.exportVTT) }
            Button("Plain text (.txt)") { export("txt", session.exportText) }
            Button("JSON (.json)") { export("json", session.exportJSON) }
            Button("취소", role: .cancel) { }
        }
    }

    /// Save-panel export writer — mirrors ContentView's helper so the export
    /// entry point can live in this panel per the redesign.
    private func export(_ ext: String, _ writer: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "transcript.\(ext)"
        if panel.runModal() == .OK, let url = panel.url { try? writer(url) }
    }

    // A thin hit-zone on the leading edge (panel now sits on the right side of
    // the window): drag to resize, hover shows the left-right resize cursor.
    // Width is clamped to [min,max] and persisted.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 10)
            .contentShape(Rectangle())
            .overlay(alignment: .center) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.Colors.separator)
                    .frame(width: 2, height: 26)
                    .opacity(dragStartWidth == nil ? 0 : 1)
            }
            // Guarded push/pop so the cursor stack stays balanced even if the
            // explorer is hidden while the pointer is still over the handle.
            .onHover { inside in
                if inside, !handleHovering { handleHovering = true; NSCursor.resizeLeftRight.push() }
                else if !inside, handleHovering { handleHovering = false; NSCursor.pop() }
            }
            .onDisappear { if handleHovering { NSCursor.pop(); handleHovering = false } }
            .gesture(
                DragGesture()
                    .onChanged { v in
                        let start = dragStartWidth ?? explorerWidth
                        if dragStartWidth == nil { dragStartWidth = explorerWidth }
                        // Panel is now on the right: dragging the leading edge LEFT
                        // (negative translation) grows it, so the sign flips vs. the
                        // old left-side layout.
                        explorerWidth = min(maxWidth, max(minWidth, start - v.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
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
            Button { session.autoSaveFolder = session.workspace.root.deletingLastPathComponent() } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.plain).help("상위 폴더로")
            .disabled(session.workspace.root.path == "/")
            Button { session.workspace.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("새로고침")
            Button { chooseFolder() } label: { Image(systemName: "folder.badge.gearshape") }
                .buttonStyle(.plain).help("작업 폴더 변경…")
            Button { isVisible = false } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.plain).help("탐색기 닫기")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.Colors.textSecondary)
        // Match sidePanel's inner inset (Theme.Space.window) so both panels'
        // content starts the same distance from their card edges.
        .padding(.horizontal, Theme.Space.window).padding(.top, Theme.Space.window).padding(.bottom, 10.5)
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView().controlSize(.small)
            Text("폴더를 읽는 중…")
                .font(Theme.Fonts.status).foregroundStyle(Theme.Colors.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 12)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(Theme.Fonts.status)
                    .foregroundStyle(node.isDir ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                if node.isTranscript {
                    GistView(url: node.url)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isTranscript { session.openArchived(node.url) }
            else if node.isDir { session.autoSaveFolder = node.url }   // enter folder = make it the workspace + save/export folder
            else { reveal(node.url) }
            // (a folder's subtree also still expands inline via the disclosure chevron)
        }
        .contextMenu {
            if node.isDir {
                Button("이 폴더 열기 (작업 폴더로)") { session.autoSaveFolder = node.url }
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
        case "wav", "m4a", "mp3", "aac", "flac": return "waveform"
        case "mp4", "mov", "m4v", "mkv", "webm", "flv", "avi": return "film"
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
