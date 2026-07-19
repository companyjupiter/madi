// SettingsView.swift — all "set once" controls live here (⌘,), keeping the main
// window's side panel to the few things you touch every session. Localized for the
// 한국어/English UI toggle (설정 → 표시 → 언어); strings go through `uiLang(ko, en)`.

import SwiftUI
import CoreAudio
import AppKit

struct SettingsView: View {
    @Bindable var session: SessionController
    @Bindable var downloader: ModelDownloader
    @Bindable var translateDownloader: TranslateModelDownloader
    @Bindable var dictation: DictationController
    @AppStorage("appearance") private var appearance = Appearance.system
    // VAD/confidence threshold — same key Theme.confThreshold reads (Theme.confKey).
    @AppStorage("vadConfThreshold") private var vadThreshold = 0.55
    // UI language (한국어/English) — read by localized views via the same key.
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko

    /// Translation needs the DNA3 engine binary in the bundle (make_app.sh only
    /// copies it when TRANSLATE_ENGINE is set). Without it the tab would invite a
    /// 2.6 GB model download that can never run — hide the whole tab instead.
    private var translateEngineBundled: Bool {
        Bundle.main.url(forAuxiliaryExecutable: "translate-engine") != nil
    }

    var body: some View {
        TabView {
            recording.tabItem { Label(uiLang("녹음", "Recording"), systemImage: "mic") }
            editor.tabItem { Label(uiLang("저장", "Save"), systemImage: "square.and.arrow.down") }
            if translateEngineBundled {
                translate.tabItem { Label(uiLang("번역", "Translation"), systemImage: "character.bubble") }
            }
            GlossarySettingsView(session: session).tabItem { Label(uiLang("단어장", "Glossary"), systemImage: "character.book.closed") }
            model.tabItem { Label(uiLang("모델", "Model"), systemImage: "shippingbox") }
            // BETA: the 받아쓰기 (system-wide dictation) tab is removed — the feature
            // is unwired (DictationController.featureEnabled). DictationSettingsView is
            // kept in the source, just unreferenced; restore it with the flag.
        }
        .frame(width: 460, height: 380)
        .padding()
    }

    // MARK: 번역 — on-device translation model (DNA3.0-4B, downloaded on demand)
    private var translate: some View {
        Form {
            Section("\(uiLang("번역 모델", "Translation model")) (DNA3.0-4B · ~2.6 GB)") {
                LabeledContent(uiLang("상태", "Status")) {
                    switch translateDownloader.state {
                    case .ready: Label(uiLang("설치됨", "Installed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .verifying: Label(uiLang("검증 중…", "Verifying…"), systemImage: "checkmark.shield")
                    case .downloading(let p): Text(uiLang("다운로드 \(Int(p * 100))%", "Downloading \(Int(p * 100))%"))
                    case .failed(let m): Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    case .idle: Text(uiLang("미설치", "Not installed"))
                    }
                }
                if case .downloading(let p) = translateDownloader.state {
                    ProgressView(value: p)
                    Button(uiLang("취소", "Cancel")) { translateDownloader.cancel() }
                } else if case .ready = translateDownloader.state {
                    Button(uiLang("Finder에서 보기", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([AssetManifest.translateModelURL])
                    }
                } else {
                    Button(uiLang("번역 모델 다운로드", "Download translation model")) { translateDownloader.startDownload() }
                        .buttonStyle(.borderedProminent)
                }
                let gb = Int(AssetManifest.translateModel.approxRuntimeMemoryGB ?? 3)
                Text(uiLang("로컬 온디바이스 번역(KO·ZH·JA·EN)용. 앱에 동봉되지 않고 켤 때 받습니다 — 메모리 약 \(gb) GB 추가.",
                            "For on-device translation (KO·ZH·JA·EN). Not bundled; downloaded on demand — about \(gb) GB more memory in use."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(uiLang("실시간 번역 (다중 대상)", "Live translation (multi-target)")) {
                ForEach([("Korean","한국어"), ("English","English"), ("Japanese","日本語"), ("Chinese","中文")], id: \.0) { code, label in
                    Toggle(label, isOn: Binding(
                        get: { session.translateTargets.contains(code) },
                        set: { on in if on { session.translateTargets.insert(code) } else { session.translateTargets.remove(code) } })
                    )
                    .disabled(!AssetManifest.translateAvailable)
                }
                if !AssetManifest.translateAvailable {
                    Text(uiLang("번역 모델을 먼저 다운로드하세요.", "Download the translation model first.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(uiLang("선택한 모든 언어로 각 줄을 동시 번역해 원문 아래 표시합니다(원문 언어는 자동 제외).",
                                "Each line is translated into every selected language at once, shown under the original (the source language is excluded)."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(uiLang("번역 반응 (실시간)", "Live translation response")) {
                slider(uiLang("마지막 줄 대기 (초)", "Wait for last line (s)"), $session.translateTailSeconds, 0.5...5.0)
                Text(uiLang("말이 끝난 마지막 줄을 이 시간만큼 기다렸다 번역합니다. 짧을수록 자막이 빨리 뜨지만 미완성 문장을 번역할 수 있어요. 확정된(다음 줄이 시작된) 줄은 이 값과 무관하게 즉시 번역됩니다.",
                            "Waits this long after the last spoken line stops changing before translating it. Shorter shows captions sooner but may translate an unfinished sentence. Committed (next-line-started) lines translate immediately regardless."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(uiLang("AI 교정 (세션 종료 후)", "AI correction (after session)")) {
                Toggle(uiLang("화자·언어 자동 교정", "Auto-correct speakers & language"), isOn: $session.aiReconcileEnabled)
                    .disabled(!AssetManifest.translateAvailable)
                Text(AssetManifest.translateAvailable
                     ? uiLang("녹음이 끝나면 온디바이스 LLM이 대화를 읽고 명백한 화자 오분리·잘못된 언어 줄을 보수적으로 바로잡습니다. 화자 교정은 한 번에 되돌릴 수 있습니다.",
                              "When recording ends, the on-device LLM reads the conversation and conservatively fixes obvious speaker mis-splits and wrong-language lines. Speaker corrections can be undone in one click.")
                     : uiLang("번역·요약 모델(DNA3.0-4B)이 있어야 사용할 수 있습니다.",
                              "Requires the translation/summary model (DNA3.0-4B)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { translateDownloader.refresh() }
    }

    // MARK: 녹음 — capture + live behavior + appearance
    private var recording: some View {
        Form {
            Section(uiLang("입력", "Input")) {
                Picker(uiLang("음원", "Audio source"), selection: $session.audioSource) {
                    ForEach(AudioSource.allCases) { s in Text(s.label(uiLang)).tag(s) }
                }
                .help(uiLang("시스템 오디오 = Teams·Slack·Zoom·YouTube 등 Mac에서 재생되는 소리. 마이크+시스템 = 온라인 회의(내 목소리 + 상대). 첫 사용 시 화면 기록 권한 필요.",
                            "System audio = whatever plays on the Mac (Teams·Slack·Zoom·YouTube …). Mic + system = online meetings (your voice + the other side). First use asks for Screen Recording permission."))
                if session.audioSource != .system {
                    Picker(uiLang("마이크", "Microphone"), selection: $session.inputDeviceID) {
                        Text(uiLang("시스템 기본", "System default")).tag(AudioDeviceID?.none)
                        ForEach(session.availableInputs) { dev in
                            Text(dev.name).tag(AudioDeviceID?.some(dev.id))
                        }
                    }
                }
                if session.audioSource != .mic {
                    Text(uiLang("시스템 오디오는 첫 녹음 시 ‘화면 기록’ 권한을 요청합니다 (오디오 전용, 화면은 저장 안 함).",
                                "System audio asks for ‘Screen Recording’ permission on first record (audio only; the screen is never saved)."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker(uiLang("언어", "Language"), selection: $session.languageTokenID) {
                    Text(uiLang("자동 감지", "Auto-detect")).tag(Int?.none)
                    Text(uiLang("한국어", "Korean")).tag(Int?.some(WhisperLang.ko))
                    Text("English").tag(Int?.some(WhisperLang.en))
                }
            }
            Section(uiLang("화자", "Speakers")) {
                Toggle(uiLang("화자 분리", "Speaker separation"), isOn: $session.diarize)
                Toggle(uiLang("중첩 발화 감지", "Overlapping speech detection"), isOn: $session.osd)
            }
            Section(uiLang("실시간", "Live")) {
                Picker(uiLang("반응 속도", "Response speed"), selection: Binding(
                    // 강제 중에는 "정확"으로 표시(저장된 선호값은 안 건드림); 평소엔 실제 값.
                    get: { session.effectiveWindowSeconds },
                    set: { session.liveWindowSeconds = $0 })
                ) {
                    Text(uiLang("빠름 (5초)", "Fast (5s)")).tag(5.0)
                    Text(uiLang("보통 (7초)", "Normal (7s)")).tag(7.0)
                    Text(uiLang("정확 (10초)", "Accurate (10s)")).tag(10.0)
                }
                .help(uiLang("빠름=텍스트가 더 자주 뜸(체감↑), 정확=문맥 길어 품질↑", "Fast = text appears more often; Accurate = more context, better quality."))
                if session.multiTranslateForcesAccurate {
                    Text(uiLang("번역 대상 2개 이상 → 최소 ‘보통(7초)’. ‘빠름(5초)’은 원문 경계 오류가 모든 번역으로 전파돼 자동으로 7초가 됩니다.",
                                "With 2+ output languages → a floor of ‘Normal (7s)’. ‘Fast (5s)’ becomes 7s automatically, since boundary errors would propagate into every translation."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(uiLang("실시간 프리뷰", "Live preview"), isOn: $session.livePreviewEnabled)
                    .help(uiLang("윈도가 닫히기 전 회색 중간 텍스트 표시(정확도 무손해, 메모리 +~830MB)", "Shows gray interim text before a window closes (no accuracy cost, ~830 MB more memory)."))
            }
            Section(uiLang("표시", "Display")) {
                Picker("언어 / Language", selection: $uiLang) {
                    ForEach(UILanguage.allCases) { l in Text(l.nativeName).tag(l) }
                }
                .pickerStyle(.segmented)
                Picker(uiLang("외관", "Appearance"), selection: $appearance) {
                    ForEach(Appearance.allCases) { a in Text(a.label(uiLang)).tag(a) }
                }
                .pickerStyle(.segmented)
            }
            captionSection
        }
        .formStyle(.grouped)
        .disabled(session.phase == .recording || session.phase == .paused)
    }

    /// Clinic caption panel sizing + patient (second) display. Edits go through
    /// a local copy so the didSet-driven overlay refresh fires once on commit.
    private var captionSection: some View {
        Section(uiLang("자막 오버레이 (진료실)", "Caption overlay (clinic)")) {
            let s = session.captionSettings
            LabeledContent(uiLang("직원 자막 크기", "Staff caption size")) {
                Slider(value: bind(\.staffFontSize), in: 14...48, step: 2)
                Text("\(Int(s.staffFontSize))pt").monospacedDigit().foregroundStyle(.secondary)
            }
            Toggle(uiLang("환자용 대형 자막 (별도 화면)", "Large patient captions (separate display)"), isOn: bind(\.patientPanelEnabled))
                .help(uiLang("두 번째 패널을 환자 언어로, 원거리 판독용 큰 글씨로 띄웁니다", "Shows a second panel in the patient’s language, at a size readable from across the room."))
            if s.patientPanelEnabled {
                LabeledContent(uiLang("환자 자막 크기", "Patient caption size")) {
                    Slider(value: bind(\.patientFontSize), in: 24...96, step: 2)
                    Text("\(Int(s.patientFontSize))pt").monospacedDigit().foregroundStyle(.secondary)
                }
                if NSScreen.screens.count > 1 {
                    Picker(uiLang("환자 화면", "Patient display"), selection: bindOpt(\.patientScreenIndex)) {
                        Text(uiLang("주 화면", "Main display")).tag(Int?.none)
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { i, sc in
                            Text(uiLang("화면 \(i + 1)", "Display \(i + 1)") + " (\(Int(sc.frame.width))×\(Int(sc.frame.height)))").tag(Int?.some(i))
                        }
                    }
                }
                Picker(uiLang("환자 언어", "Patient language"), selection: bindOpt(\.patientLangOverride)) {
                    Text(uiLang("자동 (상대 언어)", "Auto (other party’s)")).tag(String?.none)
                    ForEach(["Japanese", "Chinese", "English", "Korean"], id: \.self) {
                        Text($0).tag(String?.some($0))
                    }
                }
            }
        }
    }
    private func bind<V>(_ kp: WritableKeyPath<CaptionSettings, V>) -> Binding<V> {
        Binding(get: { session.captionSettings[keyPath: kp] },
                set: { var c = session.captionSettings; c[keyPath: kp] = $0; session.captionSettings = c.clamped })
    }
    private func bindOpt<V: Equatable>(_ kp: WritableKeyPath<CaptionSettings, V>) -> Binding<V> {
        Binding(get: { session.captionSettings[keyPath: kp] },
                set: { var c = session.captionSettings; c[keyPath: kp] = $0; session.captionSettings = c })
    }

    // MARK: 저장 — auto-save + recognition thresholds.
    // BETA: the editor-analysis sections (편집 기능 / 필러·무음 타이튼 / 챕터 /
    // 리테이크·하이라이트) are removed — the feature is unwired for the public beta
    // (SessionController.editorFeaturesEnabled). Restore them together with the flag.
    private var editor: some View {
        Form {
            Section(uiLang("자동 저장", "Auto-save")) {
                Toggle(uiLang("완료 시 .md 자동저장", "Auto-save .md on finish"), isOn: $session.autoSaveEnabled)
                if session.autoSaveEnabled {
                    HStack {
                        Text(uiLang("폴더", "Folder")).foregroundStyle(.secondary)
                        Text(session.autoSaveFolder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(uiLang("변경…", "Change…")) { chooseAutoSaveFolder() }
                    }
                }
            }
            Section(uiLang("음성 인식", "Speech recognition")) {
                slider(uiLang("저신뢰 표시 기준 (VAD)", "Low-confidence threshold (VAD)"), $vadThreshold, 0.35...0.9, "%.2f")
                Text(uiLang("이 신뢰도 미만 단어를 ‘검토 필요’로 표시합니다. 기본 0.55.", "Words below this confidence are flagged ‘needs review’. Default 0.55."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ label: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ fmt: String = "%.1f") -> some View {
        HStack {
            Text(label)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func chooseAutoSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.autoSaveFolder
        panel.prompt = uiLang("선택", "Select")
        panel.message = uiLang("전사 완료 시 .md 를 저장할 폴더", "Folder to save the .md when transcription finishes")
        if panel.runModal() == .OK, let url = panel.url { session.autoSaveFolder = url }
    }

    // MARK: 모델
    private var model: some View {
        Form {
            LabeledContent(uiLang("상태", "Status")) {
                Text(AssetManifest.modelIsValid() ? uiLang("설치됨", "Installed") : uiLang("미설치", "Not installed"))
            }
            LabeledContent(uiLang("위치", "Location")) {
                Text(AssetManifest.modelURL.path).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            Button(uiLang("모델 재다운로드", "Re-download model")) { downloader.startDownload() }
            Button(uiLang("Finder에서 보기", "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([AssetManifest.modelURL])
            }
        }
        .formStyle(.grouped)
    }
}

/// Whisper language token IDs (must match the engine's token table —
/// transcribe.zig order: en=50259, zh=50260, ko=50264, ja=50266).
enum WhisperLang {
    static let en = 50259
    static let zh = 50260
    static let ko = 50264
    static let ja = 50266
}
