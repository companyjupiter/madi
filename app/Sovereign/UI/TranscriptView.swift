// TranscriptView.swift — scrolling speaker-attributed transcript with
// interruption markers, auto-scrolling to the newest line.

import SwiftUI

struct TranscriptView: View {
    let lines: [Line]
    let names: [Int: String]

    private let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(lines) { line in
                        row(line).id(line.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func row(_ line: Line) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color(line.speaker)).frame(width: 8, height: 8)
                Text(name(line.speaker)).font(.caption).bold()
                    .foregroundStyle(color(line.speaker))
                Text(timecode(line.start)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(attributed(line))
        }
    }

    private func attributed(_ line: Line) -> AttributedString {
        var s = AttributedString(line.text)
        for ov in line.overlapSpeakers {
            var marker = AttributedString("  ⟨+\(name(ov)) 겹침⟩")
            marker.foregroundColor = color(ov)
            marker.font = .caption.italic()
            s += marker
        }
        return s
    }

    private func name(_ id: Int) -> String { names[id] ?? "Speaker \(id)" }
    private func color(_ id: Int) -> Color { palette[((id % palette.count) + palette.count) % palette.count] }
    private func timecode(_ t: Double) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
