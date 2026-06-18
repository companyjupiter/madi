// TranscriptView.swift — scrolling speaker-attributed transcript with
// interruption markers, auto-scrolling to the newest line.
// All visual constants come from Theme (generated from design/tokens.json) —
// the designer restyles via Figma token export, not by editing this file.

import SwiftUI

/// How the transcript is rendered.
/// `.content` — clean meeting-minutes reading: speaker-grouped paragraphs, no
///   timecodes / no confidence highlight / no overlap markers. The default for
///   general users who just want the content. `.detailed` — the review/editor
///   view: per-turn rows with timecode, amber low-confidence words, overlap
///   markers. Editor features never intrude on the clean reading view.
enum TranscriptViewMode { case content, detailed }

struct TranscriptView: View {
    let lines: [Line]
    let names: [Int: String]
    var mode: TranscriptViewMode = .detailed
    var onRename: ((Int, String) -> Void)? = nil   // speaker id → new name
    // Review navigator: bump `scrollTick` to scroll the line `scrollTarget` into
    // view (centered). Used by the 상세-mode low-confidence review queue.
    var scrollTarget: UUID? = nil
    var scrollTick: Int = 0
    var focusedLine: UUID? = nil   // line to briefly emphasize after a jump
    var interim: String = ""       // live streaming-preview text (gray "진행 중")
    var fontSize: CGFloat = 13     // transcript body text size (user-adjustable)
    private var bodyFont: Font { .system(size: fontSize) }

    @State private var editingSpeaker: Int? = nil
    @State private var draftName: String = ""

    /// Consecutive same-speaker lines collapsed into one reading paragraph.
    /// The block id is its last line's id so live auto-scroll (which targets
    /// `lines.last.id`) still lands on the newest block.
    private struct SpeakerBlock: Identifiable { let id: UUID; let speaker: Int; let text: String; let lineIDs: [UUID] }
    private var blocks: [SpeakerBlock] {
        var out: [SpeakerBlock] = []
        var i = 0
        while i < lines.count {
            let sp = lines[i].speaker
            var j = i
            var parts: [String] = []
            var ids: [UUID] = []
            while j < lines.count && lines[j].speaker == sp { parts.append(lines[j].text); ids.append(lines[j].id); j += 1 }
            out.append(SpeakerBlock(id: lines[j - 1].id, speaker: sp,
                                    text: parts.joined(separator: " "), lineIDs: ids))
            i = j
        }
        return out
    }
    private var multiSpeaker: Bool { Set(lines.map { $0.speaker }).count > 1 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.lineGap) {
                    if mode == .content {
                        ForEach(blocks) { b in contentBlock(b).id(b.id) }
                    } else {
                        ForEach(lines) { line in row(line).id(line.id) }
                    }
                    if !interim.isEmpty {
                        Text(interim)
                            .font(bodyFont)
                            .foregroundStyle(Theme.Colors.textSecondary)  // adaptive — readable on light & dark
                            .italic()
                            .id("interim")
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
            .onChange(of: scrollTick) { _, _ in
                if let t = scrollTarget {
                    withAnimation { proxy.scrollTo(t, anchor: .center) }
                }
            }
            .onChange(of: interim) { _, v in
                if !v.isEmpty { proxy.scrollTo("interim", anchor: .bottom) }
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

    /// Clean reading block: just speaker name (only when >1 speaker) + content.
    /// No timecode, no amber, no overlap markers — pure meeting content.
    private func contentBlock(_ b: SpeakerBlock) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lineInner) {
            if multiSpeaker {
                Button {
                    draftName = names[b.speaker] ?? ""
                    editingSpeaker = b.speaker
                } label: {
                    Text(name(b.speaker)).font(Theme.Fonts.speaker)
                        .foregroundStyle(Theme.Colors.speaker(b.speaker))
                }
                .buttonStyle(.plain)
                .help("클릭하여 이름 지정")
            }
            Text(b.text).font(bodyFont)
            if let tr = blockTranslation(b) {
                Text(tr).font(.system(size: fontSize * 0.92))
                    .foregroundStyle(Theme.Colors.accent).opacity(0.85)
            }
        }
    }

    /// Translation for a content block = the joined translations of its lines.
    private func blockTranslation(_ b: SpeakerBlock) -> String? {
        let parts = lines.filter { b.lineIDs.contains($0.id) }.compactMap { $0.translation }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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
            Text(attributed(line)).font(bodyFont)
            if let tr = line.translation {
                Text(tr).font(.system(size: fontSize * 0.92))
                    .foregroundStyle(Theme.Colors.accent).opacity(0.85)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(focusedLine == line.id ? Theme.Colors.lowConf.opacity(0.14) : .clear)
        )
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
