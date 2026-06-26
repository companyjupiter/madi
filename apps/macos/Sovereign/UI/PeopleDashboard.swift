// PeopleDashboard.swift — the "사람" view that swaps in for the file tree in the
// workspace explorer. Renders one card per enrolled voiceprint person (initials
// avatar in their speaker color, meeting count, total talk-time, and a bar scaled
// to the busiest person) across every saved transcript.
//
// Data is computed by SessionController.peopleAnalytics() (FileManager over the
// voiceprints + the workspace .md files → PeopleAnalytics.aggregate). The view is
// pure presentation over the resulting [Person]; the toggle that shows it lives in
// the WorkspaceExplorer header (lead-applied segmented Picker).

import SwiftUI

struct PeopleDashboard: View {
    let people: [Person]
    var autoRecognizedNames: Set<String> = []

    /// Largest total talk-time, for scaling the bars (≥1 to avoid /0).
    private var maxTalk: Double { max(1, people.map(\.totalTalk).max() ?? 1) }

    var body: some View {
        if people.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.chipGap) {
                    ForEach(Array(people.enumerated()), id: \.element.id) { idx, person in
                        card(person, colorIndex: idx)
                    }
                }
                .padding(12)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.Colors.textTertiary)
            Text("등록된 화자가 없습니다")
                .font(Theme.Fonts.display)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("화자 이름을 지정하면 목소리가 등록되어\n여기에 회의별 발화량이 모입니다.")
                .font(Theme.Fonts.status)
                .foregroundStyle(Theme.Colors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    @ViewBuilder
    private func card(_ person: Person, colorIndex: Int) -> some View {
        let color = Theme.Colors.speaker(colorIndex)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                avatar(person.name, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(person.name)
                            .font(Theme.Fonts.speaker)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .lineLimit(1)
                        if autoRecognizedNames.contains(person.name) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.accent)
                                .help("음성 인식됨")
                        }
                    }
                    Text("\(person.meetings)개 회의 · \(timeText(person.totalTalk))")
                        .font(Theme.Fonts.status)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            bar(person.totalTalk, color: color)
        }
        .padding(Theme.Space.cardPad)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Colors.surfaceSunken)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.separator, lineWidth: 1))
        )
    }

    /// Up-to-two-character initials of the name in their speaker color.
    private func avatar(_ name: String, color: Color) -> some View {
        Text(initials(name))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(color))
    }

    private func bar(_ talk: Double, color: Color) -> some View {
        GeometryReader { geo in
            let frac = min(1, talk / maxTalk)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.Radius.meter)
                    .fill(Theme.Colors.meterTrack)
                RoundedRectangle(cornerRadius: Theme.Radius.meter)
                    .fill(color)
                    .frame(width: max(talk > 0 ? 4 : 0, geo.size.width * frac))
            }
        }
        .frame(height: Theme.Size.meterH)
    }

    /// First grapheme of up to the first two whitespace-split tokens (handles both
    /// "김부장" → "김" and "Park JM" → "PJ"). Falls back to the leading character.
    private func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " })
        if parts.count >= 2 {
            return parts.prefix(2).compactMap { $0.first.map(String.init) }.joined()
        }
        return name.first.map { String($0) } ?? "·"
    }

    /// "12분 30초" / "45초" — Korean talk-time label.
    private func timeText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        return m > 0 ? "\(m)분 \(s)초" : "\(s)초"
    }
}
