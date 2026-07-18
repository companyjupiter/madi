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
    // Consolidated status area at the transcript tail (Figma 258:908): a gradient
    // WARNING row (누락 의심 / 무음) stacked over a dimmed ACTIVITY row (전사·번역·
    // 듣는 중 …). The 누락 warning carries an expand chevron → outline box of the
    // suspected-missing timestamps (gapTimes, pre-formatted mm:ss).
    var warningText: String? = nil
    var gapTimes: [String] = []
    var activityText: String? = nil
    // Per-segment status (Phase 3): languages being translated + whether the
    // translate pipeline is busy — drives the ephemeral pending-dots row on
    // segments whose translation hasn't arrived yet.
    var activeLangs: [String] = []
    var translateBusy: Bool = false
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
    var onEditTranslation: ((UUID, String, String) -> Void)? = nil
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
    // ⌘F find: highlight every occurrence of `findQuery` (case-insensitive) in each
    // line; the line at `findCurrentLine` (the active match) gets a stronger fill.
    var findQuery: String = ""
    var findCurrentLine: UUID? = nil
    private var bodyFont: Font { .system(size: fontSize) }

    @State private var viewportH: CGFloat = 0
    // Jump pill (#8): while the user reads ABOVE the follow zone, new commits
    // don't drag the view (OS anchor releases) — they count up here instead,
    // surfaced as a "새 전사 N" pill that jumps back to the live tail.
    @State private var atBottom = true
    @State private var unseenCount = 0
    // Corrective re-glue: defaultScrollAnchor(.bottom) loses its grip when an
    // EARLIER line grows (translation backlog attaching above the viewport,
    // mid-session speaker fixes regrouping blocks) — content grows at the top,
    // the offset stays, and the OS reads the new gap as "user left the bottom".
    // followLive tracks REAL user intent instead: only an upward wheel scroll
    // over the transcript (or a scrollbar-sized jump) releases it; while it
    // holds, any drift off the bottom snaps back instantly.
    @State private var followLive = true
    @State private var hovering = false
    @State private var lastGap: CGFloat = 0
    @State private var wheelMonitor: Any? = nil
    @State private var metrics: CGPoint = .zero   // latest ScrollMetricsKey value

    @State private var editingSpeaker: Int? = nil
    @State private var draftName: String = ""
    @State private var editingLine: UUID? = nil
    @State private var editDraft: String = ""
    @State private var editingTranslationLine: UUID? = nil
    @State private var editingTranslationLang: String = ""
    @State private var translationDraft: String = ""
    // Typewriter buffer for the interim preview: the raw `interim` prop arrives
    // in whole-hypothesis jumps; this drips the delta out a few characters per
    // ~24ms tick so live text types smoothly instead of flashing in chunks.
    @State private var shownInterim = ""
    @State private var typerTask: Task<Void, Never>? = nil
    @State private var coverageExpanded = false

    private func syncInterim(_ target: String) {
        typerTask?.cancel()
        if target.isEmpty { shownInterim = ""; return }
        // The hypothesis can be REWRITTEN (not just extended) — snap, don't type.
        if !target.hasPrefix(shownInterim) { shownInterim = target; return }
        if target == shownInterim { return }
        typerTask = Task { @MainActor in
            while !Task.isCancelled, shownInterim.count < target.count {
                let pending = target.count - shownInterim.count
                // Way behind (window commit dumped a paragraph) → catch up now.
                if pending > 120 { shownInterim = target; return }
                let step = pending > 40 ? 5 : 2
                let cut = target.index(target.startIndex,
                                       offsetBy: min(shownInterim.count + step, target.count))
                shownInterim = String(target[..<cut])
                try? await Task.sleep(nanoseconds: 24_000_000)
            }
        }
    }
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

    /// squares(copy) header button: the line's text + its translations.
    private func copyLine(_ line: Line) {
        var parts = [line.text]
        for lang in line.translations.keys.sorted() { parts.append(line.translations[lang]!) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n"), forType: .string)
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

    // MARK: inline live continuation

    /// The part of the live hypothesis that ISN'T already committed — rendered
    /// gray, inline after the last committed line, so a window commit simply
    /// "turns the gray text black" in place instead of swapping blocks (which
    /// duplicated text and jolted the scroll). Token-overlap heuristic: the
    /// longest normalized match between the committed tail and the hypothesis
    /// head is dropped from the front of the hypothesis.
    private var interimSuffix: String {
        guard !shownInterim.isEmpty, !lines.isEmpty else { return "" }
        let tail = lines.suffix(3).map(\.text).joined(separator: " ")
        return Self.dedupedContinuation(committedTail: tail, hypothesis: shownInterim)
    }

    static func dedupedContinuation(committedTail: String, hypothesis: String) -> String {
        func norm(_ s: Substring) -> String {
            s.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        let tailToks = committedTail.split(separator: " ").map(norm).filter { !$0.isEmpty }
        let hypRaw = hypothesis.split(separator: " ")
        let hypToks = hypRaw.map(norm)
        guard !tailToks.isEmpty, !hypToks.isEmpty else { return hypothesis }
        // Largest m where the last m committed tokens == the first m hypothesis
        // tokens (normalized). Fully-covered hypothesis → nothing new to show.
        let maxM = min(tailToks.count, hypToks.count)
        for m in stride(from: maxM, through: 1, by: -1) {
            if Array(tailToks.suffix(m)) == Array(hypToks.prefix(m)) {
                return hypRaw.dropFirst(m).joined(separator: " ")
            }
        }
        return hypothesis
    }

    /// Append the gray live continuation to a committed body Text (last row only).
    private func withLiveTail(_ base: Text, isLast: Bool) -> Text {
        let suffix = isLast ? interimSuffix : ""
        guard !suffix.isEmpty else { return base }
        return base + Text(" " + suffix).foregroundColor(Theme.Colors.textTertiary)
    }

    /// Ephemeral per-segment status row (Phase 3): quiet pulsing dots where the
    /// translation WILL appear, shown while this segment is queued/streaming and
    /// no text has landed yet. Once any translation text exists, the gray
    /// streaming line itself is the status.
    @ViewBuilder private func segmentStatusRow(_ line: Line) -> some View {
        let st = line.status(activeLangs: activeLangs,
                             isLiveTail: line.id == lines.last?.id && !interimSuffix.isEmpty,
                             translateBusy: translateBusy)
        if st == .translating, line.translations.isEmpty {
            LoadingDots(color: Theme.Colors.textTertiary)
                .padding(.top, 2)
                .transition(.opacity)
        }
    }

    // ── Panel spacing — the ONLY three numbers that shape the column ────────
    // Figma 258:908: root gap 30 between blocks (also above the status area),
    // pb-40 bottom clearance under it.
    private static let blockGap: CGFloat = 30
    private static let statusGapTop: CGFloat = 30
    private static let tailClearance: CGFloat = 40

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // ── Column structure (Figma 258:908), one deterministic stack ──
                //   LazyVStack — transcript blocks only, gap = blockGap
                //   StatusArea — exactly statusGapTop above (it sits OUTSIDE the
                //                LazyVStack so list spacing can never stack with
                //                its padding; the old layout piled spacing +
                //                padding + tail frames into 30–60pt surprises)
                //   tail       — tailClearance of bottom clearance
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: Self.blockGap) {
                        // .transaction nil-animation on every row: streaming text
                        // grows row heights dozens of times a second — any inherited
                        // animation context turns that into visible wobble. Height
                        // changes must land instantly; only the status area and the
                        // jump pill animate.
                        if mode == .content {
                            // Distinct id namespace from the detailed rows: a content
                            // block's id would otherwise equal its last line's id, which
                            // collides with that line's row id and makes LazyVStack keep
                            // the merged-paragraph view alongside the rows after a mode
                            // switch (the whole transcript rendered a second time).
                            ForEach(blocks) { b in
                                contentBlock(b).id(blockScrollID(b.id))
                                    .transaction { $0.animation = nil }
                            }
                        } else if mode == .chat {
                            ForEach(lines) { line in
                                chatRow(line).id(line.id)
                                    .transaction { $0.animation = nil }
                            }
                        } else {
                            ForEach(lines) { line in
                                row(line).id(line.id)
                                    .transaction { $0.animation = nil }
                            }
                        }
                        // The live hypothesis renders INLINE as a gray continuation
                        // of the last committed line (see interimSuffix) — no
                        // separate block, so committing just "turns gray text
                        // black" in place. A standalone gray paragraph only before
                        // the first commit.
                        if lines.isEmpty, !shownInterim.isEmpty {
                            Text(shownInterim)
                                .font(bodyFont)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .id("interim")
                        }
                        // (Interim TRANSLATIONS are not rendered in the transcript
                        // — committed translations only. The caption overlay still
                        // consumes livePartialTranslations for live subtitles.)
                    }
                    if warningText != nil || activityText != nil {
                        StatusArea(warningText: warningText, gapTimes: gapTimes,
                                   activityText: activityText, expanded: $coverageExpanded)
                            .padding(.top, Self.statusGapTop)
                            .id("statusLine")
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: Self.tailClearance).id("liveTail")
                }
                .padding(Theme.Space.window)
                // Direct geometry observation — NOT a PreferenceKey: preference
                // values published from ScrollView content stopped reaching
                // .onPreferenceChange on macOS 26 (the handler simply never
                // fired, freezing atBottom/gap at their initial values), so the
                // scroll metrics are written straight into @State from here.
                .background(GeometryReader { geo in
                    let f = geo.frame(in: .named("transcriptScroll"))
                    Color.clear
                        .onAppear { metrics = CGPoint(x: f.minY, y: f.height) }
                        .onChange(of: f) { _, nf in
                            metrics = CGPoint(x: nf.minY, y: nf.height)
                        }
                })
                // Reading order first, chat behavior second: stretching the
                // content to at least the viewport height (top-aligned) makes
                // short transcripts read from the TOP, while the .bottom anchor
                // keeps an overflowing live one chat-pinned — no flip moment,
                // no measurement feedback loop.
                .frame(minHeight: viewportH, alignment: .topLeading)
            }
            // Live session: bottom-anchored — the OS keeps the view glued through
            // growth (scroll up to release, return to re-engage), LLM-chat style.
            // Static archive (no activity): a document — open at the TOP. The
            // anchor is fixed at view creation (archives and live sessions each
            // mount a fresh TranscriptView; runtime anchor flips are unreliable).
            .defaultScrollAnchor(activityText != nil ? .bottom : .top)
            .coordinateSpace(name: "transcriptScroll")
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { viewportH = geo.size.height }
                    .onChange(of: geo.size) { _, s in viewportH = s.height }
            })
            .onChange(of: metrics) { _, m in
                onScrolledFromTopChange?(m.x < -2)
                // Bottom proximity — inside 120pt counts as "at the bottom"
                // (matches the OS anchor's follow zone closely enough).
                let bottomGap = (m.y + m.x) - viewportH
                lastGap = bottomGap
                let near = bottomGap <= 120
                if near != atBottom { withAnimation(.easeOut(duration: 0.2)) { atBottom = near } }
                if near, unseenCount != 0 { unseenCount = 0 }
                // Follow intent from geometry: exact bottom re-arms; a jump of
                // half a viewport+ (scrollbar drag, review jump) releases.
                if bottomGap <= 8 { followLive = true }
                else if bottomGap > max(240, viewportH * 0.5) { followLive = false }
                // The corrective pin (live sessions only): while following, any
                // gap that appears WITHOUT an upward user scroll is drift from
                // above-viewport growth — snap back, un-animated.
                if followLive, activityText != nil, bottomGap > 2 {
                    proxy.scrollTo("liveTail", anchor: .bottom)
                }
            }
            // User-intent detection: an upward wheel/trackpad scroll over the
            // transcript is the ONLY ordinary way to release the follow; a
            // downward scroll near the bottom re-arms it.
            .onHover { hovering = $0 }
            .onAppear {
                guard wheelMonitor == nil else { return }
                wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { ev in
                    if hovering {
                        if ev.scrollingDeltaY > 2 { followLive = false }
                        else if ev.scrollingDeltaY < -2, lastGap <= 160 { followLive = true }
                    }
                    return ev
                }
            }
            .onDisappear {
                if let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil }
            }
            // Count commits that landed below the fold while the user reads above.
            .onChange(of: lines.count) { old, new in
                if new > old, !atBottom {
                    withAnimation(.easeOut(duration: 0.2)) { unseenCount += new - old }
                } else if new < old {
                    unseenCount = 0   // session reset / reload
                }
            }
            // The jump pill itself — floats over the bottom edge, tap = re-glue.
            .overlay(alignment: .bottom) {
                if !atBottom, unseenCount > 0 {
                    Button {
                        unseenCount = 0
                        followLive = true
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("liveTail", anchor: .bottom)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                            Text("새 전사 \(unseenCount)")
                                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        }
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.Colors.surface)
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 2))
                        .overlay(Capsule().strokeBorder(Theme.Colors.separator, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
            // (per-event scrolls removed — defaultScrollAnchor(.bottom) keeps the
            // view glued through commits, typing, translations, status changes.)
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
            .onChange(of: interim) { _, v in syncInterim(v) }
            .onAppear { shownInterim = interim }
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
                        Text(name(b.speaker)).font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        if autoRecognizedSpeakers.contains(b.speaker) {
                            Label("음성 인식됨", systemImage: "checkmark.seal.fill")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.textTertiary)   // de-accent
                                .help("음성 인식됨 — 등록된 목소리와 일치")
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("클릭하여 이름 지정")
            }
            // double-click in the reading view flips to 상세 so the per-line edit
            // gesture is available (editing is line-granular; blocks join lines).
            withLiveTail(Text(b.text), isLast: b.lineIDs.contains(lines.last?.id ?? UUID()))
                .font(bodyFont)
                .lineSpacing(fontSize * 0.3)
                .onTapGesture(count: 2) { if onEdit != nil { onRequestDetailed?() } }
            let bt = blockTranslations(b)
            ForEach(bt, id: \.0) { lang, text in
                translationLine(lang, text, speaker: b.speaker, lineID: b.id, showTag: bt.count > 1)
            }
            if bt.isEmpty, let lastLine = lines.last(where: { b.lineIDs.contains($0.id) }) {
                segmentStatusRow(lastLine)
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

    /// One translation line (Figma 258:907): quiet body text — 0.875× the original
    /// size, textPrimary at 85%, tight tracking — reading as a subtitle, not an
    /// accent-colored insert. The language tag chip (speaker-colored, C15) only
    /// appears when the line carries 2+ target languages — with a single target
    /// it's redundant. A7: a caret ▍ trails while (line, lang) is streaming in.
    @ViewBuilder
    private func translationLine(_ lang: String, _ text: String, speaker: Int? = nil,
                                 lineID: UUID? = nil, showTag: Bool = false,
                                 editable: Bool = false, userEdited: Bool = false) -> some View {
        let tag = Self.langTag[lang] ?? lang
        let tagColor = speaker.map { Theme.Colors.speaker($0) } ?? Theme.Colors.accent
        let streaming = lineID != nil && lineID == streamingTransID && lang == streamingTransLang
        let isEditing = editable && lineID == editingTranslationLine && lang == editingTranslationLang
        HStack(alignment: .top, spacing: 6) {
            if showTag {
                Text(tag).font(.system(size: fontSize * 0.72, weight: .semibold))
                    .foregroundStyle(tagColor).opacity(streaming ? 0.4 : 0.75)
                    .frame(width: fontSize * 1.4, alignment: .leading)
            }
            // While this (line, lang) is still streaming, the translation is
            // provisional — render it GRAY, exactly like the transcript's
            // uncommitted gray tail (withLiveTail). It flips to dark on commit.
            if isEditing {
                TextField("번역 교정", text: $translationDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: fontSize * 0.875))
                    .onSubmit {
                        guard let lineID else { return }
                        onEditTranslation?(lineID, lang, translationDraft)
                        editingTranslationLine = nil
                    }
                Button("저장") {
                    guard let lineID else { return }
                    onEditTranslation?(lineID, lang, translationDraft)
                    editingTranslationLine = nil
                }
                .controlSize(.small)
            } else {
                (Text(text) + (streaming ? Text(" ▍") : Text("")))
                    .font(.system(size: fontSize * 0.875)).tracking(-0.28)
                    .lineSpacing(fontSize * 0.875 * 0.4)
                    .foregroundStyle(streaming ? Theme.Colors.textTertiary
                                               : Theme.Colors.textPrimary.opacity(0.85))
                if userEdited {
                    Image(systemName: "pencil")
                        .font(.system(size: fontSize * 0.65, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .help("사용자 교정 번역")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard editable, !streaming, let lineID, onEditTranslation != nil else { return }
            editingTranslationLine = lineID
            editingTranslationLang = lang
            translationDraft = text
        }
    }

    /// Interim (provisional) translation — same grammar as the committed line
    /// (C16) but italic + lighter, so provisional→committed only changes weight.
    private func interimTranslationLine(_ lang: String, _ text: String, showTag: Bool = false) -> some View {
        let tag = Self.langTag[lang] ?? lang
        return HStack(alignment: .top, spacing: 6) {
            if showTag {
                Text(tag).font(.system(size: fontSize * 0.72, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent).opacity(0.55)
                    .frame(width: fontSize * 1.4, alignment: .leading)
            }
            Text(text).font(.system(size: fontSize * 0.875)).tracking(-0.28)
                .foregroundStyle(Theme.Colors.textSecondary).italic()
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
                withLiveTail(Text(line.text), isLast: line.id == lines.last?.id)
                    .font(bodyFont)
                    .frame(maxWidth: .infinity, alignment: side == .leading ? .leading : .trailing)
                    .multilineTextAlignment(side == .leading ? .leading : .trailing)
                ForEach(line.translations.keys.sorted(), id: \.self) { lang in
                    translationLine(lang, line.translations[lang]!, speaker: line.speaker,
                                    lineID: line.id, showTag: line.translations.count > 1,
                                    editable: true, userEdited: line.editedTranslations.contains(lang))
                }
                segmentStatusRow(line)
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
            // Figma 258:1118 header: dot 6 · name 14 bold · timecode 12 medium
            // (hh:mm:ss) on the left; squares(copy) + pen(edit) 16pt, gap 16, on
            // the right.
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
                        Text(name(line.speaker)).font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        if autoRecognizedSpeakers.contains(line.speaker) {
                            Label("음성 인식됨", systemImage: "checkmark.seal.fill")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Colors.textTertiary)   // de-accent
                                .help("음성 인식됨 — 등록된 목소리와 일치")
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("클릭하여 이름 지정")
                Text(timecode(line.start))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.Colors.textSecondary)
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
                    Text("편집됨").font(Theme.Fonts.timestamp).foregroundStyle(Theme.Colors.textTertiary)   // de-accent
                }
                Spacer(minLength: 8)
                HStack(spacing: 16) {
                    Button { copyLine(line) } label: {
                        SVGIcon(name: "squares", size: 16, tint: Theme.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("이 문장 복사")
                    if canEdit(line) {
                        Button { beginEdit(line) } label: {
                            SVGIcon(name: "pen", size: 16, tint: Theme.Colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("이 문장 편집")
                    }
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
                let body = withLiveTail(Text(attributed(line)), isLast: line.id == lines.last?.id)
                    .font(bodyFont)
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
                translationLine(lang, line.translations[lang]!, speaker: line.speaker,
                                lineID: line.id, showTag: line.translations.count > 1,
                                editable: true, userEdited: line.editedTranslations.contains(lang))
            }
            segmentStatusRow(line)
        }
        // No layout padding (Figma 258:908: rows sit flush — the speaker dot
        // aligns with the status area's icon, and block gaps stay exactly 30).
        // The review highlight instead BLEEDS past the text via negative insets,
        // so the visual pill is unchanged without inflating the row's box.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(reviewHighlight(line) ? Theme.Colors.lowConf.opacity(0.14) : .clear)
                .padding(.horizontal, -6).padding(.vertical, -4)
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
                // low confidence (Figma 258:568): the word is COLORED #E0992A only
                // — no underline; the orange itself is the review affordance. Still
                // a tappable link opening the word-review popover (openURL override).
                run.foregroundColor = Color(red: 224/255, green: 153/255, blue: 42/255)
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
        applyFindHighlight(&s, lineID: line.id)
        return s
    }

    /// ⌘F: paint every case-insensitive occurrence of the query behind the text.
    /// Offsets computed on `String(s.characters)` map 1:1 to the character view (same
    /// character sequence), so highlight ranges align with what's rendered.
    private func applyFindHighlight(_ s: inout AttributedString, lineID: UUID) {
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let strong = lineID == findCurrentLine
        let chars = s.characters
        let text = String(chars)
        var from = text.startIndex
        while let r = text.range(of: q, options: .caseInsensitive, range: from..<text.endIndex) {
            let startOff = text.distance(from: text.startIndex, to: r.lowerBound)
            let len = text.distance(from: r.lowerBound, to: r.upperBound)
            let lo = chars.index(chars.startIndex, offsetBy: startOff)
            let hi = chars.index(lo, offsetBy: len)
            s[lo..<hi].backgroundColor = strong ? Color.orange.opacity(0.6) : Color.yellow.opacity(0.4)
            from = r.upperBound
        }
    }

    // "Speaker N" (1-based) matches the redesign's side-panel share list, so the
    // same person carries one label across transcript and stats.
    private func name(_ id: Int) -> String { SpeakerID.display(id, names: names, fallback: "Speaker \(id + 1)") }
    private func timecode(_ t: Double) -> String {
        // Figma 258:1122: always hh:mm:ss ("00:00:00")
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
