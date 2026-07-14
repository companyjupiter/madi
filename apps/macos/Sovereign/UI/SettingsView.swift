// SettingsView.swift — all "set once" controls live here (⌘,), keeping the main
// window's side panel to the few things you touch every session.

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

    /// Translation needs the DNA3 engine binary in the bundle (make_app.sh only
    /// copies it when TRANSLATE_ENGINE is set). Without it the tab would invite a
    /// 2.6 GB model download that can never run — hide the whole tab instead.
    private var translateEngineBundled: Bool {
        Bundle.main.url(forAuxiliaryExecutable: "translate-engine") != nil
    }

    var body: some View {
        TabView {
            recording.tabItem { Label("녹음", systemImage: "mic") }
            editor.tabItem { Label("저장", systemImage: "square.and.arrow.down") }
            if translateEngineBundled {
                translate.tabItem { Label("번역", systemImage: "character.bubble") }
            }
            GlossarySettingsView(session: session).tabItem { Label("단어장", systemImage: "character.book.closed") }
            model.tabItem { Label("모델", systemImage: "shippingbox") }
            DictationSettingsView(dictation: dictation).tabItem { Label("받아쓰기", systemImage: "keyboard") }
        }
        .frame(width: 460, height: 380)
        .padding()
    }

    // MARK: 번역 — on-device translation model (DNA3.0-4B, downloaded on demand)
    private var translate: some View {
        Form {
            Section("번역 모델 (DNA3.0-4B · ~2.6 GB)") {
                LabeledContent("상태") {
                    switch translateDownloader.state {
                    case .ready: Label("설치됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .verifying: Label("검증 중…", systemImage: "checkmark.shield")
                    case .downloading(let p): Text("다운로드 \(Int(p * 100))%")
                    case .failed(let m): Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    case .idle: Text("미설치")
                    }
                }
                if case .downloading(let p) = translateDownloader.state {
                    ProgressView(value: p)
                    Button("취소") { translateDownloader.cancel() }
                } else if case .ready = translateDownloader.state {
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([AssetManifest.translateModelURL])
                    }
                } else {
                    Button("번역 모델 다운로드") { translateDownloader.startDownload() }
                        .buttonStyle(.borderedProminent)
                }
                Text("로컬 온디바이스 번역(KO·ZH·JA·EN)용. 앱에 동봉되지 않고 켤 때 받습니다 — 메모리 약 \(Int(AssetManifest.translateModel.approxRuntimeMemoryGB ?? 3)) GB 추가.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("실시간 번역 (다중 대상)") {
                ForEach([("Korean","한국어"), ("English","English"), ("Japanese","日本語"), ("Chinese","中文")], id: \.0) { code, label in
                    Toggle(label, isOn: Binding(
                        get: { session.translateTargets.contains(code) },
                        set: { on in if on { session.translateTargets.insert(code) } else { session.translateTargets.remove(code) } })
                    )
                    .disabled(!AssetManifest.translateAvailable)
                }
                if !AssetManifest.translateAvailable {
                    Text("번역 모델을 먼저 다운로드하세요.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("선택한 모든 언어로 각 줄을 동시 번역해 원문 아래 표시합니다(원문 언어는 자동 제외).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("AI 교정 (세션 종료 후)") {
                Toggle("화자·언어 자동 교정", isOn: $session.aiReconcileEnabled)
                    .disabled(!AssetManifest.translateAvailable)
                Text(AssetManifest.translateAvailable
                     ? "녹음이 끝나면 온디바이스 LLM이 대화를 읽고 명백한 화자 오분리·잘못된 언어 줄을 보수적으로 바로잡습니다. 화자 교정은 한 번에 되돌릴 수 있습니다."
                     : "번역·요약 모델(DNA3.0-4B)이 있어야 사용할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { translateDownloader.refresh() }
    }

    // MARK: 녹음 — capture + live behavior + appearance
    private var recording: some View {
        Form {
            Section("입력") {
                Picker("음원", selection: $session.audioSource) {
                    ForEach(AudioSource.allCases) { s in Text(s.label).tag(s) }
                }
                .help("시스템 오디오 = Teams·Slack·Zoom·YouTube 등 Mac에서 재생되는 소리. 마이크+시스템 = 온라인 회의(내 목소리 + 상대). 첫 사용 시 화면 기록 권한 필요.")
                if session.audioSource != .system {
                    Picker("마이크", selection: $session.inputDeviceID) {
                        Text("시스템 기본").tag(AudioDeviceID?.none)
                        ForEach(session.availableInputs) { dev in
                            Text(dev.name).tag(AudioDeviceID?.some(dev.id))
                        }
                    }
                }
                if session.audioSource != .mic {
                    Text("시스템 오디오는 첫 녹음 시 ‘화면 기록’ 권한을 요청합니다 (오디오 전용, 화면은 저장 안 함).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("언어", selection: $session.languageTokenID) {
                    Text("자동 감지").tag(Int?.none)
                    Text("한국어").tag(Int?.some(WhisperLang.ko))
                    Text("English").tag(Int?.some(WhisperLang.en))
                }
            }
            Section("화자") {
                Toggle("화자 분리", isOn: $session.diarize)
                Toggle("중첩 발화 감지", isOn: $session.osd)
            }
            Section("실시간") {
                Picker("반응 속도", selection: Binding(
                    // 강제 중에는 "정확"으로 표시(저장된 선호값은 안 건드림); 평소엔 실제 값.
                    get: { session.effectiveWindowSeconds },
                    set: { session.liveWindowSeconds = $0 })
                ) {
                    Text("빠름 (5초)").tag(5.0)
                    Text("보통 (7초)").tag(7.0)
                    Text("정확 (10초)").tag(10.0)
                }
                .help("빠름=텍스트가 더 자주 뜸(체감↑), 정확=문맥 길어 품질↑")
                if session.multiTranslateForcesAccurate {
                    Text("번역 대상 2개 이상 → 최소 ‘보통(7초)’. ‘빠름(5초)’은 원문 경계 오류가 모든 번역으로 전파돼 자동으로 7초가 됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("실시간 프리뷰", isOn: $session.livePreviewEnabled)
                    .help("윈도가 닫히기 전 회색 중간 텍스트 표시(정확도 무손해, 메모리 +~830MB)")
            }
            Section("표시") {
                Picker("외관", selection: $appearance) {
                    ForEach(Appearance.allCases) { a in Text(a.label).tag(a) }
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
        Section("자막 오버레이 (진료실)") {
            let s = session.captionSettings
            LabeledContent("직원 자막 크기") {
                Slider(value: bind(\.staffFontSize), in: 14...48, step: 2)
                Text("\(Int(s.staffFontSize))pt").monospacedDigit().foregroundStyle(.secondary)
            }
            Toggle("환자용 대형 자막 (별도 화면)", isOn: bind(\.patientPanelEnabled))
                .help("두 번째 패널을 환자 언어로, 원거리 판독용 큰 글씨로 띄웁니다")
            if s.patientPanelEnabled {
                LabeledContent("환자 자막 크기") {
                    Slider(value: bind(\.patientFontSize), in: 24...96, step: 2)
                    Text("\(Int(s.patientFontSize))pt").monospacedDigit().foregroundStyle(.secondary)
                }
                if NSScreen.screens.count > 1 {
                    Picker("환자 화면", selection: bindOpt(\.patientScreenIndex)) {
                        Text("주 화면").tag(Int?.none)
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { i, sc in
                            Text("화면 \(i + 1) (\(Int(sc.frame.width))×\(Int(sc.frame.height)))").tag(Int?.some(i))
                        }
                    }
                }
                Picker("환자 언어", selection: bindOpt(\.patientLangOverride)) {
                    Text("자동 (상대 언어)").tag(String?.none)
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
            Section("자동 저장") {
                Toggle("완료 시 .md 자동저장", isOn: $session.autoSaveEnabled)
                if session.autoSaveEnabled {
                    HStack {
                        Text("폴더").foregroundStyle(.secondary)
                        Text(session.autoSaveFolder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("변경…") { chooseAutoSaveFolder() }
                    }
                }
            }
            Section("음성 인식") {
                slider("저신뢰 표시 기준 (VAD)", $vadThreshold, 0.35...0.9, "%.2f")
                Text("이 신뢰도 미만 단어를 ‘검토 필요’로 표시합니다. 기본 0.55.")
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
        panel.prompt = "선택"
        panel.message = "전사 완료 시 .md 를 저장할 폴더"
        if panel.runModal() == .OK, let url = panel.url { session.autoSaveFolder = url }
    }

    // MARK: 모델
    private var model: some View {
        Form {
            LabeledContent("상태") {
                Text(AssetManifest.modelIsValid() ? "설치됨" : "미설치")
            }
            LabeledContent("위치") {
                Text(AssetManifest.modelURL.path).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            Button("모델 재다운로드") { downloader.startDownload() }
            Button("Finder에서 보기") {
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
