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
enum TranscriptViewMode { case content, detailed, chat }

struct TranscriptView: View {
    let lines: [Line]
    let names: [Int: String]
    var autoRecognizedSpeakers: Set<Int> = []
    var mode: TranscriptViewMode = .detailed
    var onRename: ((Int, String) -> Void)? = nil   // speaker id → new name
    // Review navigator: bump `scrollTick` to scroll the line `scrollTarget` into
    // view (centered). Used by the 상세-mode low-confidence review queue.
    var scrollTarget: UUID? = nil
    var scrollTick: Int = 0
    var focusedLine: UUID? = nil   // line to briefly emphasize after a jump
    var interim: String = ""       // live streaming-preview text (gray "진행 중")
    var interimTranslations: [String: String] = [:]   // provisional translation of the interim
    var fontSize: CGFloat = 13     // transcript body text size (user-adjustable)
    // A7: the (line, language) whose translation is currently streaming in — a
    // blinking caret ▍ is appended so a half-arrived translation reads as "still
    // typing" rather than a finished (truncated) sentence.
    var streamingTransID: UUID? = nil
    var streamingTransLang: String? = nil
    // #2 inline editing of committed lines (live or post). onEdit commits the new
    // text; lockedLineID is the in-progress last line during recording (not yet
    // safe to edit). onRequestDetailed flips content→detailed so the edit gesture
    // works from the reading view too.
    var onEdit: ((UUID, String) -> Void)? = nil
    // Review flow: replace one low-confidence word (lineID, word index, new text).
    var onEditWord: ((UUID, Int, String) -> Void)? = nil
    var lockedLineID: UUID? = nil
    var onRequestDetailed: (() -> Void)? = nil
    // Click-to-play: when set, each line shows a play button that hears that
    // moment of the source media. playingLine drives the play/pause icon.
    var onPlay: ((Line) -> Void)? = nil
    var playingLine: UUID? = nil
    // Reports whether the content is scrolled down from the very top, so the
    // caller can show its top fade only while earlier text is hidden above.
    var onScrolledFromTopChange: ((Bool) -> Void)? = nil
    private var bodyFont: Font { .system(size: fontSize) }

    private struct ScrollTopKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    @State private var editingSpeaker: Int? = nil
    @State private var draftName: String = ""
    @State private var editingLine: UUID? = nil
    @State private var editDraft: String = ""
    // Word-review popover: index into `flaggedRefs` currently being edited (nil =
    // closed), plus the draft text for that word.
    @State private var reviewRefIndex: Int? = nil
    @State private var reviewDraft: String = ""

    /// Every low-confidence word in transcript order, with the location needed to
    /// edit it (line id + word index). Drives the click-to-edit review popover.
    private var flaggedRefs: [(lineID: UUID, wordIndex: Int, text: String)] {
        var out: [(UUID, Int, String)] = []
        for line in lines {
            for (i, w) in line.words.enumerated() where w.conf < Theme.confThreshold {
                let t = w.text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append((line.id, i, t)) }
            }
        }
        return out
    }

    private var currentReviewRef: (lineID: UUID, wordIndex: Int, text: String)? {
        guard let idx = reviewRefIndex, idx >= 0, idx < flaggedRefs.count else { return nil }
        return flaggedRefs[idx]
    }

    /// A tapped low-confidence word carries a `madi-review://w/<lineUUID>/<index>`
    /// link; open its editor by finding the matching flagged ref.
    private func openReview(_ url: URL) {
        guard url.scheme == "madi-review",
              url.host == "w" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, let wi = Int(parts[1]) else { return }
        let lineID = parts[0]
        if let idx = flaggedRefs.firstIndex(where: { $0.lineID.uuidString == lineID && $0.wordIndex == wi }) {
            reviewRefIndex = idx
            reviewDraft = flaggedRefs[idx].text
        }
    }

    private func moveReview(_ delta: Int) {
        let refs = flaggedRefs
        guard !refs.isEmpty, let idx = reviewRefIndex else { return }
        let next = ((idx + delta) % refs.count + refs.count) % refs.count
        reviewRefIndex = next
        reviewDraft = refs[next].text
    }

    private func applyReview() {
        // Capture the list BEFORE editing: this View is a struct, so a deferred
        // read of `flaggedRefs` would see the pre-edit snapshot. Compute the next
        // word synchronously from `old` instead (the edited item drops out).
        let old = flaggedRefs
        guard let idx = reviewRefIndex, idx < old.count else { return }
        let ref = old[idx]
        onEditWord?(ref.lineID, ref.wordIndex, reviewDraft)
        let newCount = old.count - 1
        if newCount <= 0 { reviewRefIndex = nil; return }
        let ni = min(idx, newCount - 1)
        // Position ni after removing index idx maps back to old[ni] (before idx)
        // or old[ni+1] (at/after idx).
        let sourceIdx = ni < idx ? ni : ni + 1
        reviewRefIndex = ni
        reviewDraft = old[sourceIdx].text
    }
    // TextEditor has no auto-grow — measured via an invisible Text twin so the
    // box matches the wrapped content's height instead of scrolling internally.
    @State private var editDraftHeight: CGFloat = 0

    private func canEdit(_ line: Line) -> Bool { onEdit != nil && line.id != lockedLineID }
    private func beginEdit(_ line: Line) {
        guard canEdit(line) else { return }
        editDraft = line.text; editingLine = line.id
    }
    private func commitEdit() {
        if let id = editingLine { onEdit?(id, editDraft) }
        editingLine = nil
    }

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

    /// Scroll id for a content-mode block — a String so it can't collide with the
    /// UUID scroll ids the detailed rows use (see the mode branch in body).
    private func blockScrollID(_ id: UUID) -> String { "block-\(id.uuidString)" }

    /// Does this line contain a low-confidence (clickable review) word?
    private func lineHasFlagged(_ line: Line) -> Bool {
        line.words.contains { $0.conf < Theme.confThreshold }
    }

    private var firstSpeaker: Int? { lines.first?.speaker }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {   // Figma 195:866 block gap
                    if mode == .content {
                        // Distinct id namespace from the detailed rows: a content
                        // block's id would otherwise equal its last line's id, which
                        // collides with that line's row id and makes LazyVStack keep
                        // the merged-paragraph view alongside the rows after a mode
                        // switch (the whole transcript rendered a second time).
                        ForEach(blocks) { b in contentBlock(b).id(blockScrollID(b.id)) }
                    } else if mode == .chat {
                        ForEach(lines) { line in chatRow(line).id(line.id) }
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
                    // provisional translation of the interim. Rendered independently
                    // of the interim TEXT (T1 carryover): on window commit the last
                    // interim translation stays visible under the committed line
                    // until its authoritative translation streams in. C16: same
                    // language-tag chip as committed translations, so the jump from
                    // provisional→committed doesn't change the visual grammar.
                    if !interimTranslations.isEmpty {
                        ForEach(interimTranslations.keys.sorted(), id: \.self) { lang in
                            interimTranslationLine(lang, interimTranslations[lang] ?? "")
                        }
                    }
                    // Clearance below the newest line: auto-scroll anchors THIS
                    // tail to the bottom, so the live/interim line lands ~50pt
                    // above the window edge — clear of the bottom fade instead of
                    // hidden under it. (Also gives a static transcript's last line
                    // breathing room above the fade.)
                    Color.clear.frame(height: 50).id("liveTail")
                }
                .padding(Theme.Space.window)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ScrollTopKey.self,
                        value: geo.frame(in: .named("transcriptScroll")).minY)
                })
            }
            .coordinateSpace(name: "transcriptScroll")
            .onPreferenceChange(ScrollTopKey.self) { minY in
                onScrolledFromTopChange?(minY < -2)
            }
            // mouse-drag selection + ⌘C copy across the whole transcript
            .textSelection(.enabled)
            // Intercept taps on low-confidence-word links → open the review popover
            // instead of trying to open a URL.
            .environment(\.openURL, OpenURLAction { url in
                openReview(url); return .handled
            })
            // Keep the word being reviewed on screen as 이전/다음 moves through them.
            .onChange(of: reviewRefIndex) { _, _ in
                if let ref = currentReviewRef {
                    withAnimation { proxy.scrollTo(ref.lineID, anchor: .center) }
                }
            }
            .onChange(of: lines.count) { _, _ in
                // 50ms: 기본(≈250ms) 스크롤 애니메이션이 새 줄 표시를 그만큼
                // 늦춰 보이게 한다 — 라이브 전사는 즉시성이 우선.
                withAnimation(.linear(duration: 0.05)) { proxy.scrollTo("liveTail", anchor: .bottom) }
            }
            .onChange(of: scrollTick) { _, _ in
                guard let t = scrollTarget else { return }
                // In content mode the line's row doesn't exist — scroll to the
                // merged block that contains it instead.
                if mode == .content {
                    if let blk = blocks.first(where: { $0.lineIDs.contains(t) }) {
                        withAnimation { proxy.scrollTo(blockScrollID(blk.id), anchor: .center) }
                    }
                } else {
                    withAnimation { proxy.scrollTo(t, anchor: .center) }
                }
            }
            .onChange(of: interim) { _, v in
                if !v.isEmpty { withAnimation { proxy.scrollTo("liveTail", anchor: .bottom) } }
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
        VStack(alignment: .leading, spacing: 9) {   // Figma 188:663 header→body gap
            if multiSpeaker {
                Button {
                    draftName = names[b.speaker] ?? ""
                    editingSpeaker = b.speaker
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.Colors.speaker(b.speaker))
                            .frame(width: 6, height: 6)
                        Text(name(b.speaker)).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        if autoRecognizedSpeakers.contains(b.speaker) {
                            Label("음성 인식됨", systemImage: "checkmark.seal.fill")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.accent)
                                .help("음성 인식됨 — 등록된 목소리와 일치")
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("클릭하여 이름 지정")
            }
            // double-click in the reading view flips to 상세 so the per-line edit
            // gesture is available (editing is line-granular; blocks join lines).
            Text(b.text).font(bodyFont)
                .lineSpacing(fontSize * 0.3)
                .onTapGesture(count: 2) { if onEdit != nil { onRequestDetailed?() } }
            ForEach(blockTranslations(b), id: \.0) { lang, text in
                translationLine(lang, text, speaker: b.speaker, lineID: b.id)
            }
        }
    }

    /// Per-language translations for a content block = each line's translations[lang]
    /// joined across the block's lines, sorted by language tag.
    private func blockTranslations(_ b: SpeakerBlock) -> [(String, String)] {
        let blockLines = lines.filter { b.lineIDs.contains($0.id) }
        var byLang: [String: [String]] = [:]
        for l in blockLines { for (lang, t) in l.translations { byLang[lang, default: []].append(t) } }
        return byLang.keys.sorted().map { ($0, byLang[$0]!.joined(separator: " ")) }
    }

    private static let langTag = ["Korean": "한", "English": "EN", "Japanese": "日", "Chinese": "中"]

    /// One translation line: a short language tag + the translated text. C15: the
    /// tag chip carries the SOURCE speaker's color so a two-party conversation's
    /// translations are attributable pre-attentively. A7: a caret ▍ trails the
    /// text while this (line, lang) is still streaming in.
    private func translationLine(_ lang: String, _ text: String, speaker: Int? = nil,
                                 lineID: UUID? = nil) -> some View {
        let tag = Self.langTag[lang] ?? lang
        let tagColor = speaker.map { Theme.Colors.speaker($0) } ?? Theme.Colors.accent
        let streaming = lineID != nil && lineID == streamingTransID && lang == streamingTransLang
        return HStack(alignment: .top, spacing: 6) {
            Text(tag).font(.system(size: fontSize * 0.72, weight: .semibold))
                .foregroundStyle(tagColor).opacity(0.75)
                .frame(width: fontSize * 1.4, alignment: .leading)
            (Text(text) + (streaming ? Text(" ▍") : Text("")))
                .font(.system(size: fontSize * 0.92))
                .foregroundStyle(Theme.Colors.accent).opacity(0.85)
        }
    }

    /// Interim (provisional) translation — italic + gray, but the SAME tag chip as
    /// the committed translationLine (C16).
    private func interimTranslationLine(_ lang: String, _ text: String) -> some View {
        let tag = Self.langTag[lang] ?? lang
        return HStack(alignment: .top, spacing: 6) {
            Text(tag).font(.system(size: fontSize * 0.72, weight: .semibold))
                .foregroundStyle(Theme.Colors.accent).opacity(0.55)
                .frame(width: fontSize * 1.4, alignment: .leading)
            Text(text).font(.system(size: fontSize * 0.92))
                .foregroundStyle(Theme.Colors.accent.opacity(0.7)).italic()
        }
    }

    /// C18: two-party chat layout — the first speaker leads (left), the other
    /// trails (right), like a messenger. Each bubble carries the speaker color +
    /// name, the text, and its translations underneath.
    private func chatRow(_ line: Line) -> some View {
        let side = ChatLayout.side(for: line.speaker, firstSpeaker: firstSpeaker)
        let color = Theme.Colors.speaker(line.speaker)
        return HStack {
            if side == .trailing { Spacer(minLength: 40) }
            VStack(alignment: side == .leading ? .leading : .trailing, spacing: 3) {
                Text(name(line.speaker)).font(Theme.Fonts.speaker).foregroundStyle(color)
                Text(line.text).font(bodyFont)
                    .frame(maxWidth: .infinity, alignment: side == .leading ? .leading : .trailing)
                    .multilineTextAlignment(side == .leading ? .leading : .trailing)
                ForEach(line.translations.keys.sorted(), id: \.self) { lang in
                    translationLine(lang, line.translations[lang]!, speaker: line.speaker, lineID: line.id)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
            .overlay(alignment: side == .leading ? .leading : .trailing) {
                Rectangle().fill(color).frame(width: 2).cornerRadius(1)
            }
            .frame(maxWidth: 520, alignment: side == .leading ? .leading : .trailing)
            if side == .leading { Spacer(minLength: 40) }
        }
    }

    private func row(_ line: Line) -> some View {
        VStack(alignment: .leading, spacing: 9) {   // Figma 188:663 header→body gap
            HStack(spacing: 6) {
                Circle().fill(Theme.Colors.speaker(line.speaker))
                    .frame(width: 6, height: 6)
                // click the speaker chip to give them a name (applies to all
                // their lines). A Button (not onTapGesture) so the tap wins over
                // the transcript's .textSelection.
                Button {
                    draftName = names[line.speaker] ?? ""
                    editingSpeaker = line.speaker
                } label: {
                    HStack(spacing: 4) {
                        Text(name(line.speaker)).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        if autoRecognizedSpeakers.contains(line.speaker) {
                            Label("음성 인식됨", systemImage: "checkmark.seal.fill")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.accent)
                                .help("음성 인식됨 — 등록된 목소리와 일치")
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("클릭하여 이름 지정")
                Text(timecode(line.start)).font(Theme.Fonts.timestamp)
                    .foregroundStyle(Theme.Colors.textTertiary)
                if let onPlay {
                    Button { onPlay(line) } label: {
                        Image(systemName: playingLine == line.id ? "pause.circle.fill" : "play.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(playingLine == line.id ? Theme.Colors.accent : Theme.Colors.textTertiary)
                    .help("이 구간 오디오 재생")
                }
                if line.isEdited {
                    Text("편집됨").font(Theme.Fonts.timestamp).foregroundStyle(Theme.Colors.accent)
                }
                if canEdit(line) {
                    Spacer()
                    Button { beginEdit(line) } label: {
                        Image(systemName: "pencil").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.Colors.textTertiary)
                    .help("이 문장 편집")
                }
            }
            if editingLine == line.id {
                // TextField(axis: .vertical) silently ignores .lineSpacing() on macOS
                // (NSTextField limitation) — TextEditor's NSTextView backing honors it,
                // so editing now matches the read view's line-height. Trade-off: Return
                // inserts a newline instead of submitting; save via button or ⌘-Return.
                TextEditor(text: $editDraft)
                    .font(bodyFont).lineSpacing(fontSize * 0.3)
                    .scrollContentBackground(.hidden)
                    .frame(height: max(fontSize * 1.8, editDraftHeight))
                    .padding(.horizontal, -5)
                    .padding(.top, 2)
                    .overlay(
                        // .fixedSize forces this Text to report its true wrapped
                        // height even though the overlay slot it sits in is itself
                        // height-constrained by the .frame() above — without it the
                        // measurement is squeezed to fit the CURRENT height, so it
                        // can never grow past the initial minimum (feedback loop).
                        Text(editDraft.isEmpty ? " " : editDraft)
                            .font(bodyFont).lineSpacing(fontSize * 0.3)
                            .opacity(0)
                            .padding(.vertical, 8)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { geo in
                                Color.clear
                                    .onAppear { editDraftHeight = geo.size.height }
                                    // React to geo.size itself (not just editDraft) —
                                    // a window resize rewraps the text at the SAME
                                    // content, which onChange(of: editDraft) misses,
                                    // leaving the box stuck at the old height.
                                    .onChange(of: geo.size) { _, newSize in editDraftHeight = newSize.height }
                            })
                            .allowsHitTesting(false)
                    )
                    .onSubmit { commitEdit() }
                HStack(spacing: 6) {
                    Button("저장") { commitEdit() }.controlSize(.small).keyboardShortcut(.return, modifiers: .command)
                    Button("취소") { editingLine = nil }.controlSize(.small).keyboardShortcut(.cancelAction)
                }
                .padding(.top, -2)
            } else {
                let body = Text(attributed(line)).font(bodyFont)
                    .lineSpacing(fontSize * 0.3)
                    .onTapGesture(count: 2) { beginEdit(line) }
                // On a line WITH review links, disable text selection so the low-
                // confidence words read as clickable (pointer cursor, single-click
                // opens the editor) instead of fighting the drag-select I-beam.
                // Lines without links stay selectable (inherit the ScrollView's).
                if lineHasFlagged(line) {
                    body.textSelection(.disabled)
                } else {
                    body
                }
            }
            ForEach(line.translations.keys.sorted(), id: \.self) { lang in
                translationLine(lang, line.translations[lang]!, speaker: line.speaker, lineID: line.id)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(reviewHighlight(line) ? Theme.Colors.lowConf.opacity(0.14) : .clear)
        )
        // Word-review popover anchors to the row holding the current flagged word.
        .popover(isPresented: Binding(
            get: { currentReviewRef?.lineID == line.id },
            set: { if !$0 { reviewRefIndex = nil } }
        ), arrowEdge: .top) {
            reviewPopover
        }
    }

    /// Highlight the row while its word is being reviewed (or on a review jump).
    private func reviewHighlight(_ line: Line) -> Bool {
        focusedLine == line.id || currentReviewRef?.lineID == line.id
    }

    @ViewBuilder
    private var reviewPopover: some View {
        if let idx = reviewRefIndex, idx < flaggedRefs.count {
            let total = flaggedRefs.count
            VStack(alignment: .leading, spacing: 12) {
                Text("검토 \(idx + 1) / \(total)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
                TextField("수정할 단어", text: $reviewDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .frame(width: 240)
                    .onSubmit { applyReview() }
                HStack(spacing: 8) {
                    Button { moveReview(-1) } label: { Image(systemName: "chevron.left") }
                        .help("이전")
                    Button { moveReview(1) } label: { Image(systemName: "chevron.right") }
                        .help("다음")
                    Spacer()
                    Button("적용 후 다음") { applyReview() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(14)
            .frame(minWidth: 260)
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
                // like 섹스→색스, 빛공예→빛공해 fall here). Also a tappable link that
                // opens the word-review popover (handled via the openURL override).
                run.underlineStyle = .single
                run.foregroundColor = Theme.Colors.lowConf.opacity(0.85)
                if let url = URL(string: "madi-review://w/\(line.id.uuidString)/\(i)") {
                    run.link = url
                }
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

    // "Speaker N" (1-based) matches the redesign's side-panel share list, so the
    // same person carries one label across transcript and stats.
    private func name(_ id: Int) -> String { names[id] ?? "Speaker \(id + 1)" }
    private func timecode(_ t: Double) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
