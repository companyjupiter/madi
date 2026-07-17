// CommandPalette.swift — a ⌘K fuzzy launcher overlay.
//
// A centered card over a dimmed backdrop that lets the user jump to a meeting,
// a speaker, or a quick action by typing. Pure SwiftUI overlay (no separate
// window): the host shows it by toggling `isPresented` on the mainLayout ZStack.
//
// Commands are gathered live from the SessionController each time the palette
// opens: archived transcripts from the workspace tree, named speakers, and a
// fixed set of actions (요약 / 화자별 요약 / 새 세션 / 작업 폴더 변경). Matching is a
// lowercase substring filter with a small word-boundary score so the most
// relevant hit floats to the top; ↑/↓ move the selection, ↵ runs it, ⎋ closes.

import SwiftUI
import AppKit

// MARK: - command model

/// One runnable row. `action` is the side effect; `subtitle` is the dim hint on
/// the right (e.g. the kind of command or a path). `searchText` is what the
/// fuzzy filter scores against (precomputed lowercase for snappiness).
private struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let searchText: String
    let action: () -> Void

    init(title: String, subtitle: String, symbol: String, extraTerms: String = "", action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.searchText = (title + " " + subtitle + " " + extraTerms).lowercased()
        self.action = action
    }
}

/// Lowercase-substring match with a light word-boundary bonus. Returns nil when
/// the query isn't a substring at all (filtered out), else a score where lower =
/// better, so callers sort ascending. Empty query matches everything (score 0).
private func fuzzyScore(_ haystack: String, query: String) -> Int? {
    if query.isEmpty { return 0 }
    guard let r = haystack.range(of: query) else { return nil }
    let start = haystack.distance(from: haystack.startIndex, to: r.lowerBound)
    // Bonus when the match starts at a word boundary (string start or after a space).
    let atBoundary = start == 0 || haystack[haystack.index(haystack.startIndex, offsetBy: start - 1)] == " "
    return start - (atBoundary ? 100 : 0)
}

// MARK: - overlay view

struct CommandPalette: View {
    @Bindable var session: SessionController
    @Binding var isPresented: Bool
    /// Host opens the 회의 요약 sheet (bySpeaker → which tab). The palette can't do
    /// it itself: presenting the sheet and picking 전체/화자별 are the host's state.
    var onOpenSummary: (Bool) -> Void = { _ in }

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    /// Built once per open from the current session state.
    private var allCommands: [PaletteCommand] {
        var out: [PaletteCommand] = []

        // (c) static actions — listed first so an empty query shows the verbs.
        // 요약 only when it can actually produce something: an empty/live session
        // would run the LLM into nothing, which is what made these look broken.
        if session.canSummarize {
            out.append(PaletteCommand(title: "요약 생성", subtitle: "동작 · AI 요약",
                                      symbol: "sparkles", extraTerms: "summary 요약 action") {
                onOpenSummary(false)
            })
            out.append(PaletteCommand(title: "화자별 요약", subtitle: "동작 · 누가 무엇을",
                                      symbol: "person.2", extraTerms: "speaker summary 화자 요약") {
                onOpenSummary(true)
            })
        }
        out.append(PaletteCommand(title: "새 세션", subtitle: "동작 · 현재 전사 비우기",
                                  symbol: "plus.circle", extraTerms: "new reset 초기화 세션") {
            session.reset()
        })
        out.append(PaletteCommand(title: "작업 폴더 변경", subtitle: "동작 · 저장 위치 선택",
                                  symbol: "folder", extraTerms: "folder workspace 폴더 저장") {
            chooseWorkspaceFolder()
        })

        // (b) named speakers — jump-to / context. (Naming lives elsewhere; here a
        //     speaker row is a lightweight "go" that just closes the palette.)
        for (id, name) in session.speakerNames.sorted(by: { $0.key < $1.key }) where !name.isEmpty {
            out.append(PaletteCommand(title: name, subtitle: "화자 \(id)",
                                      symbol: "person.crop.circle", extraTerms: "speaker 화자") {
                // no destructive side effect — selecting just dismisses to the
                // transcript where the speaker's lines already live.
            })
        }

        // (a) archived meetings — every .md in the workspace tree.
        for url in transcriptURLs(session.workspace.nodes) {
            let base = url.deletingPathExtension().lastPathComponent
            out.append(PaletteCommand(title: base, subtitle: "회의 · \(url.lastPathComponent)",
                                      symbol: "doc.text", extraTerms: "meeting transcript 회의 전사") {
                session.openArchived(url)
            })
        }
        return out
    }

    /// Flatten the recursive workspace tree to every transcript (.md) leaf.
    private func transcriptURLs(_ nodes: [FileNode]) -> [URL] {
        var out: [URL] = []
        for n in nodes {
            if let kids = n.children { out.append(contentsOf: transcriptURLs(kids)) }
            else if n.isTranscript { out.append(n.url) }
        }
        return out
    }

    private var results: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let scored = allCommands.compactMap { cmd -> (PaletteCommand, Int)? in
            guard let s = fuzzyScore(cmd.searchText, query: q) else { return nil }
            return (cmd, s)
        }
        return scored.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    var body: some View {
        ZStack {
            // dimmed backdrop — tap to dismiss
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            card
                .frame(maxWidth: 560)
                .padding(Theme.Space.window)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 80)
        }
        .onAppear { selection = 0; fieldFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private var card: some View {
        VStack(spacing: 0) {
            // search field
            HStack(spacing: Theme.Space.chipGap) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Colors.textTertiary)
                CommandPaletteField(text: $query,
                                    onUp: { move(-1) },
                                    onDown: { move(1) },
                                    onSubmit: { runSelected() },
                                    onCancel: { close() })
                    .focused($fieldFocused)
            }
            .padding(Theme.Space.cardPad)

            Divider().overlay(Theme.Colors.separator)

            // results
            let rows = results
            if rows.isEmpty {
                Text("일치하는 항목이 없습니다")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.cardPad)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, cmd in
                                row(cmd, selected: idx == selection)
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture { run(cmd) }
                            }
                        }
                        .padding(.vertical, Theme.Space.lineInner)
                        .padding(.horizontal, Theme.Space.lineInner)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selection) { _, new in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                    }
                }
            }
        }
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(Theme.Colors.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
    }

    private func row(_ cmd: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: Theme.Space.chipGap) {
            Image(systemName: cmd.symbol)
                .font(Theme.Fonts.speaker)
                .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd.title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                Text(cmd.subtitle)
                    .font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.chipGap)
        .padding(.horizontal, Theme.Space.controlBar)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .fill(selected ? Theme.Colors.accent.opacity(0.14) : .clear)
        )
    }

    // MARK: actions

    private func move(_ delta: Int) {
        let n = results.count
        guard n > 0 else { return }
        selection = ((selection + delta) % n + n) % n
    }

    private func runSelected() {
        let rows = results
        guard selection >= 0, selection < rows.count else { close(); return }
        run(rows[selection])
    }

    private func run(_ cmd: PaletteCommand) {
        close()
        cmd.action()
    }

    private func close() {
        isPresented = false
        query = ""
        selection = 0
    }

    /// NSOpenPanel → set the auto-save folder (the workspace explorer follows via
    /// SessionController.autoSaveFolder.didSet → workspace.setRoot).
    private func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        panel.message = "전사·요약을 저장할 작업 폴더를 선택하세요."
        if panel.runModal() == .OK, let url = panel.url {
            session.autoSaveFolder = url
        }
    }
}

// MARK: - autofocusing text field with arrow/enter/escape capture

/// SwiftUI's TextField swallows ↑/↓/↵/⎋ inconsistently in an overlay, so the
/// palette uses a thin NSTextField wrapper that forwards those keys to closures
/// while staying first responder for typing. Autofocuses on appearance.
private struct CommandPaletteField: NSViewRepresentable {
    @Binding var text: String
    var onUp: () -> Void
    var onDown: () -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = KeyCapturingTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        field.placeholderString = "회의·화자·동작 검색…"
        field.onUp = onUp
        field.onDown = onDown
        field.onSubmit = onSubmit
        field.onCancel = onCancel
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        if let f = nsView as? KeyCapturingTextField {
            f.onUp = onUp; f.onDown = onDown; f.onSubmit = onSubmit; f.onCancel = onCancel
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: CommandPaletteField
        init(_ parent: CommandPaletteField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

/// NSTextField that routes the navigation keys to closures instead of the field's
/// default editing behavior (which would move the insertion point / beep).
private final class KeyCapturingTextField: NSTextField {
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: onUp?()                 // ↑
        case 125: onDown?()               // ↓
        case 36, 76: onSubmit?()          // ↵ / numpad enter
        case 53: onCancel?()              // ⎋
        default: super.keyDown(with: event)
        }
    }
}
