// SettingsView.swift — all "set once" controls live here (⌘,), keeping the main
// window's side panel to the few things you touch every session.

import SwiftUI
import CoreAudio
import AppKit

struct SettingsView: View {
    @Bindable var session: SessionController
    @Bindable var downloader: ModelDownloader
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        TabView {
            recording.tabItem { Label("녹음", systemImage: "mic") }
            editor.tabItem { Label("편집·저장", systemImage: "scissors") }
            model.tabItem { Label("모델", systemImage: "shippingbox") }
        }
        .frame(width: 460, height: 380)
        .padding()
    }

    // MARK: 녹음 — capture + live behavior + appearance
    private var recording: some View {
        Form {
            Section("입력") {
                Picker("마이크", selection: $session.inputDeviceID) {
                    Text("시스템 기본").tag(AudioDeviceID?.none)
                    ForEach(session.availableInputs) { dev in
                        Text(dev.name).tag(AudioDeviceID?.some(dev.id))
                    }
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
                Picker("반응 속도", selection: $session.liveWindowSeconds) {
                    Text("빠름 (5초)").tag(5.0)
                    Text("보통 (7초)").tag(7.0)
                    Text("정확 (10초)").tag(10.0)
                }
                .help("빠름=텍스트가 더 자주 뜸(체감↑), 정확=문맥 길어 품질↑")
                Toggle("실시간 프리뷰", isOn: $session.livePreviewEnabled)
                    .help("윈도가 닫히기 전 회색 중간 텍스트 표시(정확도 무손해, 메모리 +~830MB)")
            }
            Section("표시") {
                Picker("외관", selection: $appearance) {
                    ForEach(Appearance.allCases) { a in Text(a.label).tag(a) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .disabled(session.phase == .recording || session.phase == .paused)
    }

    // MARK: 편집·저장 — editor analysis thresholds + auto-save
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
            Section("필러 · 무음 (타이튼)") {
                Toggle("필러 컷", isOn: $session.editorSettings.fillers)
                Toggle("무음 컷", isOn: $session.editorSettings.silences)
                slider("무음 최소초", $session.editorSettings.silenceMinGap, 0.2...3.0)
            }
            Section("챕터") {
                Toggle("자동 챕터", isOn: $session.editorSettings.chapters)
                slider("휴지 경계초", $session.editorSettings.chapterGap, 1...10)
                slider("최소 간격초", $session.editorSettings.chapterMinLen, 10...120, "%.0f")
            }
            Section("리테이크 · 하이라이트") {
                Toggle("리테이크 감지", isOn: $session.editorSettings.retakes)
                slider("유사도", $session.editorSettings.retakeSim, 0.5...0.95, "%.2f")
                Toggle("하이라이트", isOn: $session.editorSettings.highlights)
                slider("최소 신뢰도", $session.editorSettings.hlMinConf, 0.5...0.99, "%.2f")
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

/// Whisper language token IDs (must match the engine's token table).
enum WhisperLang {
    static let en = 50259
    static let ko = 50264
}
