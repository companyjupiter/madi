// DictationSettingsView.swift — the "받아쓰기" tab in ⌘, Settings.
//
// Surfaces the three things the user must control for system-wide dictation:
// the master toggle, the Accessibility-trust gate (with a deep-link to System
// Settings), and a read-only hint of the hotkey. Pure presentation — all logic
// lives in DictationController; this view only binds to its observable state.

import SwiftUI

struct DictationSettingsView: View {
    @Bindable var dictation: DictationController

    var body: some View {
        Form {
            Section("시스템 받아쓰기") {
                Toggle("어디서나 받아쓰기 사용", isOn: $dictation.enabled)
                Text("오른쪽 ⌥(Option) 키를 누른 채 말하고 떼면, 어떤 앱이든 맨 앞 입력란에 받아쓴 텍스트가 들어갑니다. 모든 처리는 기기 안에서 이뤄집니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("단축키") {
                LabeledContent("누르고 있는 동안 녹음") {
                    Text("오른쪽 ⌥ Option")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(Theme.Colors.accent)
                }
                Text("⌘K(명령 팔레트)와 겹치지 않도록 오른쪽 Option 키를 기본값으로 씁니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("손쉬운 사용 권한") {
                LabeledContent("상태") {
                    if dictation.accessibilityTrusted {
                        Label("허용됨", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("권한 필요", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if !dictation.accessibilityTrusted {
                    Button("시스템 설정에서 허용") {
                        dictation.refreshTrust(prompt: true)
                        dictation.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    Text("다른 앱에 텍스트를 붙여넣으려면 ‘손쉬운 사용’ 권한이 필요합니다. 허용 후 이 창으로 돌아오면 자동으로 인식됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("상태") {
                LabeledContent("현재") { Text(statusLabel).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear { dictation.refreshTrust(prompt: false) }
    }

    private var statusLabel: String {
        switch dictation.state {
        case .idle: return dictation.enabled ? "대기 중" : "꺼짐"
        case .listening: return "듣는 중…"
        case .transcribing: return "변환 중…"
        case .inserting: return "입력 중…"
        case .blocked(let m): return m
        }
    }
}
