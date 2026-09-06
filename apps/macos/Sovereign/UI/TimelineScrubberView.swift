// TimelineScrubberView.swift — 트랜스크립트 위에 얹는 컴팩트한 화자별 타임라인.
//
// 각 화자가 한 줄(lane)이고, 그 트랙 위에 line 하나하나가 (start/total)…(end/total)
// 위치에 색 span 으로 깔린다. span 색 = Theme.Colors.speaker(화자). 겹침
// (overlapSpeakers 비어있지 않음) 은 작은 마커로 표시. span 탭 → onSeek(line.id).
//
// 순수 표현(presentational) 뷰 — 데이터만 받고 SessionController 의존 없음. 챕터
// 틱은 EditorCuts.chapters(lines) 가 있으면 그걸로 그린다(없으면 생략).

import SwiftUI

struct TimelineScrubberView: View {
    let lines: [Line]
    let speakerNames: [Int: String]
    /// Stable display numbers — engine ids are renumbered mid-session, so lane
    /// labels must not be derived from the id (see SpeakerDisplayNumber).
    var speakerNumbers = SpeakerDisplayNumber()
    var onSeek: (UUID) -> Void

    // lane 폭주 방지 — 가장 많이 등장한 화자 순으로 이만큼만 그린다.
    private let maxLanes = 6
    private let laneHeight: CGFloat = 26
    private let trackHeight: CGFloat = 16

    // 전체 타임라인 길이(초). 0 이면 분모가 0 이 되므로 1 로 보정.
    private var total: Double {
        let end = lines.map(\.end).max() ?? 0
        let start = lines.map(\.start).min() ?? 0
        return max(end - start, 0.001)
    }
    private var origin: Double { lines.map(\.start).min() ?? 0 }

    // 등장 빈도 내림차순 → 같으면 화자 id 오름차순. 상위 maxLanes 만 노출.
    private var laneSpeakers: [Int] {
        var counts: [Int: Int] = [:]
        for l in lines { counts[l.speaker, default: 0] += 1 }
        return counts.keys
            .sorted { (counts[$0] ?? 0, $1) > (counts[$1] ?? 0, $0) }
            .prefix(maxLanes)
            .sorted()
    }

    // 챕터 틱(있으면). EditorCuts 가 같은 타깃에 컴파일되어 있으니 직접 호출.
    private var chapters: [EditorCuts.Chapter] {
        EditorCuts.chapters(lines)
    }

    private func speakerLabel(_ id: Int) -> String {
        if id == SpeakerID.unknown { return SpeakerID.unknownLabel }
        if let n = speakerNames[id], !n.isEmpty { return n }
        return speakerNumbers.number(id).map { "화자 \($0)" } ?? "화자분리중…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lineInner) {
            HStack(spacing: Theme.Space.chipGap) {
                Text("타임라인")
                    .font(Theme.Fonts.section)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Text(durationLabel(total))
                    .font(Theme.Fonts.timestamp)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }

            VStack(spacing: 0) {
                ForEach(laneSpeakers, id: \.self) { sp in
                    laneRow(sp)
                }
            }
            .overlay(alignment: .topLeading) { chapterTicks }
        }
        .padding(.horizontal, Theme.Space.window)
        .padding(.vertical, Theme.Space.controlBar)
        .background(Theme.Colors.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    // 한 화자의 lane: 좌측 라벨 + 우측 트랙.
    private func laneRow(_ sp: Int) -> some View {
        HStack(spacing: Theme.Space.chipGap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.Colors.speaker(sp))
                    .frame(width: Theme.Size.speakerDot, height: Theme.Size.speakerDot)
                Text(speakerLabel(sp))
                    .font(Theme.Fonts.speaker)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 96, alignment: .leading)

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.meter, style: .continuous)
                        .fill(Theme.Colors.meterTrack)
                        .frame(height: trackHeight)

                    ForEach(lines.filter { $0.speaker == sp }) { line in
                        span(line, width: w)
                    }
                }
                .frame(height: trackHeight)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: laneHeight)
    }

    // line 하나의 색 span. (start..end) 를 트랙 폭에 매핑. 탭하면 onSeek.
    private func span(_ line: Line, width: CGFloat) -> some View {
        let x = CGFloat((line.start - origin) / total) * width
        let raw = CGFloat((line.end - line.start) / total) * width
        let wSpan = max(raw, 3)   // 아주 짧은 발화도 탭 가능하게 최소 폭 보장
        return RoundedRectangle(cornerRadius: Theme.Radius.meter, style: .continuous)
            .fill(Theme.Colors.speaker(line.speaker))
            .frame(width: wSpan, height: trackHeight)
            .overlay(alignment: .topTrailing) {
                if !line.overlapSpeakers.isEmpty {
                    Circle()
                        .fill(Theme.Colors.overlapMarker)
                        .frame(width: 5, height: 5)
                        .offset(x: 1, y: -1)
                }
            }
            .offset(x: x)
            .contentShape(Rectangle())
            .onTapGesture { onSeek(line.id) }
            .help(spanTooltip(line))
    }

    // 챕터 경계 틱 — 트랙 영역(라벨 폭 이후) 위에 얇은 세로선.
    private var chapterTicks: some View {
        GeometryReader { geo in
            let labelW: CGFloat = 96 + Theme.Space.chipGap
            let trackW = max(geo.size.width - labelW, 1)
            ForEach(Array(chapters.enumerated()), id: \.offset) { _, ch in
                let frac = (ch.start - origin) / total
                Rectangle()
                    .fill(Theme.Colors.separator)
                    .frame(width: 1)
                    .offset(x: labelW + CGFloat(frac) * trackW)
            }
        }
        .allowsHitTesting(false)
    }

    private func spanTooltip(_ line: Line) -> String {
        var s = "\(timeLabel(line.start - origin)) · \(speakerLabel(line.speaker))"
        if !line.overlapSpeakers.isEmpty {
            let names = line.overlapSpeakers.map(speakerLabel).joined(separator: ", ")
            s += " ⟨+\(names) 겹침⟩"
        }
        return s
    }

    private func timeLabel(_ t: Double) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func durationLabel(_ t: Double) -> String {
        let total = Int(t.rounded())
        return "총 \(total / 60)분 \(total % 60)초"
    }
}
