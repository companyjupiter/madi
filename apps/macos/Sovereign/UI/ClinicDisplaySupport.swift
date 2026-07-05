// ClinicDisplaySupport.swift — pure (Foundation-only) helpers for the clinic
// display UX batch (2026-07-05): caption status strings localized to the
// VIEWER's language, persisted caption sizing, and the two-party chat layout
// side mapping. Kept out of the SwiftUI views so the logic is unit-testable.

import Foundation

/// Status text a caption shows in the reader's OWN language — a Japanese patient
/// can't act on a Korean "진행 중". Keyed by the caption's display-language name
/// ("Japanese"/"Chinese"/"English"/…); Korean is the default fallback.
enum CaptionStatus {
    case live          // interim recognized, translation provisional
    case translating   // recognized, waiting on the translation turn
    case waiting       // no speech yet

    private static let table: [String: [CaptionStatus: String]] = [
        "Korean":   [.live: "진행 중",   .translating: "번역 중…",  .waiting: "음성을 기다리는 중…"],
        "Japanese": [.live: "認識中",     .translating: "翻訳中…",   .waiting: "音声を待っています…"],
        "Chinese":  [.live: "识别中",     .translating: "翻译中…",   .waiting: "正在等待语音…"],
        "English":  [.live: "listening",  .translating: "translating…", .waiting: "waiting for speech…"],
    ]

    func text(for lang: String?) -> String {
        let l = lang ?? "Korean"
        return Self.table[l]?[self] ?? Self.table["Korean"]![self]!
    }
}

/// Persisted caption sizing (진료실 시거리 대응). Staff caption stays compact on
/// the main screen; the patient caption is large for a 1.5–2.5 m viewing
/// distance. Loaded/saved as JSON in UserDefaults.
struct CaptionSettings: Codable, Equatable {
    var staffFontSize: Double = 26      // main-screen caption (translated line)
    var patientFontSize: Double = 46    // patient panel (far viewing)
    var panelWidth: Double = 760
    /// Lower bound for SwiftUI minimumScaleFactor — 0.6 shrank long sentences to
    /// 40% (illegible at distance). 0.9 keeps size near-constant; overflow wraps.
    var minScaleFactor: Double = 0.9
    var patientPanelEnabled: Bool = false
    /// Screen (by NSScreen index) for the patient panel; nil = same screen.
    var patientScreenIndex: Int? = nil
    /// Force the patient caption language (English lang name); nil = auto (the
    /// non-Korean side of the pair).
    var patientLangOverride: String? = nil

    static let key = "captionSettings.v1"

    static func load() -> CaptionSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(CaptionSettings.self, from: data) else {
            return CaptionSettings()
        }
        return s
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Clamp the sliders to sane bounds (called by the settings UI).
    var clamped: CaptionSettings {
        var c = self
        c.staffFontSize = min(max(staffFontSize, 14), 48)
        c.patientFontSize = min(max(patientFontSize, 24), 96)
        c.panelWidth = min(max(panelWidth, 480), 1400)
        c.minScaleFactor = min(max(minScaleFactor, 0.5), 1.0)
        return c
    }
}

/// Two-party chat layout: which side a speaker sits on (직원=좌, 환자=우).
/// The FIRST speaker seen anchors the leading side (in a clinic the staff opens
/// the conversation); everyone else trails. Only meaningful for exactly two
/// speakers — the caller gates on that.
enum ChatSide: Equatable { case leading, trailing }

enum ChatLayout {
    /// `firstSpeaker` = the speaker id of the transcript's first line.
    static func side(for speaker: Int, firstSpeaker: Int?) -> ChatSide {
        (firstSpeaker == nil || speaker == firstSpeaker) ? .leading : .trailing
    }
    /// Whether a two-party chat layout applies to this speaker set.
    static func applies(speakers: Set<Int>) -> Bool { speakers.count == 2 }
}
