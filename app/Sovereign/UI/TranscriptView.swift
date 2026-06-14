// TranscriptView.swift — scrolling speaker-attributed transcript with
// interruption markers, auto-scrolling to the newest line.
// All visual constants come from Theme (generated from design/tokens.json) —
// the designer restyles via Figma token export, not by editing this file.

import SwiftUI

struct TranscriptView: View {
    let lines: [Line]
    let names: [Int: String]
    var onRename: ((Int, String) -> Void)? = nil   // speaker id → new name

    @State private var editingSpeaker: Int? = nil
    @State private var draftName: String = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.lineGap) {
                    ForEach(lines) { line in
                        row(line).id(line.id)
                    }
                }
                .padding(Theme.Space.window)
            }
            // mouse-drag selection + ⌘C copy across the whole transcript
            .textSelection(.enabled)
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .alert("화자 이름", isPresented: Binding(
                get: { editingSpeaker != nil },
                set: { if !$0 { editingSpeaker = nil } })
            ) {
                TextField("이름 (예: 김부장)", text: $draftName)
                Button("저장") { if let s = editingSpeaker { onRename?(s, draftName) }; editingSpeaker = nil }
                Button("취소", role: .cancel) { editingSpeaker = nil }
            } message: {
                Text("이 화자의 모든 발언과 내보내기에 적용됩니다.")
            }
        }
    }

    private func row(_ line: Line) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lineInner) {
            HStack(spacing: Theme.Space.chipGap) {
                Circle().fill(Theme.Colors.speaker(line.speaker))
                    .frame(width: Theme.Size.speakerDot, height: Theme.Size.speakerDot)
                // click the speaker chip to give them a name (applies to all
                // their lines). A Button (not onTapGesture) so the tap wins over
                // the transcript's .textSelection.
                Button {
                    draftName = names[line.speaker] ?? ""
                    editingSpeaker = line.speaker
                } label: {
                    Text(name(line.speaker)).font(Theme.Fonts.speaker)
                        .foregroundStyle(Theme.Colors.speaker(line.speaker))
                }
                .buttonStyle(.plain)
                .help("클릭하여 이름 지정")
                Text(timecode(line.start)).font(Theme.Fonts.timestamp)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Text(attributed(line)).font(Theme.Fonts.body)
        }
    }

    private func attributed(_ line: Line) -> AttributedString {
        var s = AttributedString("")
        for (i, w) in line.words.enumerated() {
            // space before, except before glued punctuation
            if i > 0, w.text.first.map({ !",.!?…".contains($0) }) ?? true {
                s += AttributedString(" ")
            }
            var run = AttributedString(w.text)
            if w.conf < Theme.confThreshold {
                // low confidence: amber + underline + slight fade — the user's eye
                // lands on exactly the words to double-check (validated: real errors
                // like 섹스→색스, 빛공예→빛공해 fall here).
                run.foregroundColor = Theme.Colors.lowConf
                run.underlineStyle = .single
                run.foregroundColor = Theme.Colors.lowConf.opacity(0.85)
            }
            s += run
        }
        for ov in line.overlapSpeakers {
            var marker = AttributedString("  ⟨+\(name(ov)) 겹침⟩")
            marker.foregroundColor = Theme.Colors.speaker(ov)
            marker.font = Theme.Fonts.overlap
            s += marker
        }
        return s
    }

    private func name(_ id: Int) -> String { names[id] ?? "Speaker \(id)" }
    private func timecode(_ t: Double) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
