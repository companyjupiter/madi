// TranscriptView.swift — scrolling speaker-attributed transcript with
// interruption markers, auto-scrolling to the newest line.
// All visual constants come from Theme (generated from design/tokens.json) —
// the designer restyles via Figma token export, not by editing this file.

import SwiftUI

struct TranscriptView: View {
    let lines: [Line]
    let names: [Int: String]

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
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func row(_ line: Line) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lineInner) {
            HStack(spacing: Theme.Space.chipGap) {
                Circle().fill(Theme.Colors.speaker(line.speaker))
                    .frame(width: Theme.Size.speakerDot, height: Theme.Size.speakerDot)
                Text(name(line.speaker)).font(Theme.Fonts.speaker)
                    .foregroundStyle(Theme.Colors.speaker(line.speaker))
                Text(timecode(line.start)).font(Theme.Fonts.timestamp)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Text(attributed(line)).font(Theme.Fonts.body)
        }
    }

    private func attributed(_ line: Line) -> AttributedString {
        var s = AttributedString(line.text)
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
