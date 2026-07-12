// StatusLine.swift — the transcript-tail status area (Figma 258:908 / 260:1316).
//
// Two independent rows, stacked (gap 8):
//   · warning (gradient text + exclamation-circle) — persistent problems. The
//     "누락 의심" variant carries a chevron-right that expands an outline box
//     listing the suspected-missing timestamps; other warnings trail loading dots.
//   · activity (dimmed 15px + loading dots) — what a stage is doing right now.
// Replaces the pipeline HUD chips / silence banner / file-progress banner.

import SwiftUI

struct StatusArea: View {
    let warningText: String?
    /// Pre-formatted mm:ss of suspected-missing segments; non-empty → the warning
    /// row gets the expand chevron + outline box.
    let gapTimes: [String]
    let activityText: String?
    @Binding var expanded: Bool

    private static let warnOrange = Color(red: 242/255, green: 153/255, blue: 74/255)
    private static let warnPurple = Color(red: 201/255, green: 151/255, blue: 227/255)
    private static let warnPeriwinkle = Color(red: 136/255, green: 145/255, blue: 234/255)
    static let warnGradient = LinearGradient(
        colors: [warnOrange, warnPurple, warnPeriwinkle],
        startPoint: .leading, endPoint: .trailing)

    /// The warning text's font — one source of truth so the visible text and its
    /// gradient mask can never drift (GradientText draws the string twice).
    static let warnFont = Font.system(size: 14, weight: .regular)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warningText {
                HStack(spacing: 5) {
                    SVGIcon(name: "exclamation-circle", size: 18, tint: nil)   // baked #F2994A
                    GradientText(warningText)   // Figma 260:1336
                    if gapTimes.isEmpty {
                        LoadingDots(color: Self.warnPeriwinkle).padding(.top, 4)
                    } else {
                        Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                            SVGIcon(name: "chevron-right", size: 16, tint: Self.warnPurple)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .buttonStyle(.plain)
                        .help(expanded ? "접기" : "누락 의심 구간 보기")
                    }
                }
                .frame(height: 21)
                if expanded, !gapTimes.isEmpty { coverageBox }
            }
            if let activityText {
                StatusLineView(text: activityText, warning: false)
            }
        }
    }

    /// Outline box (Figma): the suspected-missing timestamps + a one-line why.
    private var coverageBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("소리는 있었지만 전사가 비어 재시도도 실패한 구간이에요")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.textTertiary)
            ForEach(Array(gapTimes.enumerated()), id: \.offset) { _, t in
                HStack(spacing: 8) {
                    Circle().fill(Self.warnOrange).frame(width: 5, height: 5)
                    Text(t).font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("근처").font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.Colors.surfaceSunken, lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// One dimmed activity line (14px medium, textTertiary) with trailing dots.
struct StatusLineView: View {
    let text: String
    var warning = false

    var body: some View {
        HStack(spacing: 5) {
            if warning {
                SVGIcon(name: "exclamation-circle", size: 18, tint: nil)
                GradientText(text)   // Figma 260:1299
            } else {
                Text(text)
                    .font(StatusArea.warnFont).tracking(-0.28)
                    .monospacedDigit()   // "번역 중 · N줄 대기" — stop the counter twitching the dots
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
            }
            LoadingDots(color: warning ? Color(red: 136/255, green: 145/255, blue: 234/255)
                                       : Theme.Colors.textTertiary)
                .padding(.top, 4)
        }
        .frame(height: 21)
    }
}

/// Warning text filled with `warnGradient`. Uses overlay+mask rather than
/// `.foregroundStyle(gradient)` because on macOS a gradient foregroundStyle on a
/// Text can collapse to its leading color (flat orange) — the mask paints the
/// real gradient behind the glyph shapes, so all three stops always show.
struct GradientText: View {
    let text: String
    var font: Font
    init(_ text: String, font: Font = StatusArea.warnFont) { self.text = text; self.font = font }

    var body: some View {
        // `base` is drawn hidden (for layout size) and reused as the mask, so the
        // visible gradient is clipped to exactly these glyphs. monospacedDigit:
        // the "N구간 · M회" counters change every commit — fixed-width digits keep
        // the row (and the trailing dots/chevron) from twitching sideways.
        let base = Text(text).font(font).tracking(-0.28).monospacedDigit()
        base
            .hidden()
            .overlay { StatusArea.warnGradient.mask(base) }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Three 3pt dots pulsing in sequence — the "…" is alive, not punctuation.
struct LoadingDots: View {
    var color: Color
    @State private var phase = -1

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(color)
                    .frame(width: 3, height: 3)
                    .opacity(phase == i ? 1.0 : 0.35)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: phase)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 320_000_000)
                phase = (phase + 1) % 3
            }
        }
    }
}
