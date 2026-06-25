// VoiceprintManagementView — the visible home of enrolled voiceprints.
//
// Until now the `<name>.vec` files Madi enrolls (so a named voice is recognized
// across meetings) lived invisibly in ~/Application Support/Madi/voiceprints/.
// This view surfaces them: list every enrolled voice, rename one, or delete one.
// Backed by the Foundation-only VoiceprintStore (reads disk fresh — never drifts).
//
// Korean UI, two font weights, Theme tokens only so light/dark both look right.

import SwiftUI

struct VoiceprintManagementView: View {
    @Bindable var session: SessionController

    // Re-read on every appear / mutation. VoiceprintStore has no cache, so this
    // @State is just the displayed snapshot; refresh() re-pulls from disk.
    @State private var voices: [String] = []
    @State private var renaming: String? = nil
    @State private var draftName: String = ""
    @State private var errorText: String? = nil

    private var store: VoiceprintStore { VoiceprintStore(directory: session.voiceprintsDir) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Colors.separator)
            if voices.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(voices, id: \.self) { name in
                            row(name)
                            if name != voices.last {
                                Divider().overlay(Theme.Colors.separator).padding(.leading, 14)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.recording)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .onAppear(perform: refresh)
        .alert("이름 변경", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } })
        ) {
            TextField("새 이름", text: $draftName)
            Button("취소", role: .cancel) { renaming = nil }
            Button("저장") { commitRename() }
        } message: {
            if let renaming { Text("‘\(renaming)’의 새 이름을 입력하세요.") }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.person")
                .foregroundStyle(Theme.Colors.accent)
            Text("등록된 음성")
                .font(Theme.Fonts.section)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
            Text("\(voices.count)")
                .font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: rows

    private func row(_ name: String) -> some View {
        HStack(spacing: Theme.Space.chipGap) {
            Circle()
                .fill(Theme.Colors.accent.opacity(0.85))
                .frame(width: Theme.Size.speakerDot, height: Theme.Size.speakerDot)
            Text(name)
                .font(Theme.Fonts.speaker)
                .foregroundStyle(Theme.Colors.textPrimary)
            Spacer()
            Button {
                draftName = name
                renaming = name
            } label: {
                Image(systemName: "pencil").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.textSecondary)
            .help("이름 변경")
            Button {
                delete(name)
            } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.recording)
            .help("삭제")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 26))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("등록된 음성이 없습니다")
                .font(Theme.Fonts.display)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("회의 중 화자 이름을 지정하면\n다음 회의에서 그 목소리를 자동 인식합니다.")
                .font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: actions

    private func refresh() {
        voices = store.list()
    }

    private func delete(_ name: String) {
        if store.delete(name) {
            errorText = nil
        } else {
            errorText = "‘\(name)’ 삭제에 실패했습니다."
        }
        refresh()
    }

    private func commitRename() {
        defer { renaming = nil }
        guard let old = renaming else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old else { return }
        if store.rename(old, to: trimmed) {
            errorText = nil
        } else {
            errorText = "‘\(trimmed)’ 이름은 이미 사용 중이거나 변경할 수 없습니다."
        }
        refresh()
    }
}
