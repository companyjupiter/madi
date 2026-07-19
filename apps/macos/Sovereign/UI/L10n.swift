// L10n.swift — lightweight, runtime-switchable UI language (한국어 / English).
//
// The app is built with swiftc (no Xcode project / .strings / String Catalog) and
// needs a LIVE toggle — switching from Settings, not just following the system
// locale — so this is a per-app string helper rather than NSLocalizedString.
//
// Usage in a view:
//     @AppStorage("uiLanguage") private var uiLang = UILanguage.ko
//     Text(uiLang("녹음 시작", "Start recording"))
//
// Reading @AppStorage makes the view re-render the instant the language flips.
// Keeping both strings inline (ko, en) makes each label easy to see and tune, and
// avoids a parallel key table drifting out of sync. Default 한국어 — no behavior
// change until toggled in 설정 → 표시 → 언어.

import Foundation

enum UILanguage: String, CaseIterable, Identifiable {
    case ko, en
    var id: String { rawValue }

    /// Endonym shown in the language picker (each name in its own language).
    var nativeName: String { self == .ko ? "한국어" : "English" }

    /// Pick the string for the current language: `uiLang("입력 언어", "Input language")`.
    func callAsFunction(_ ko: String, _ en: String) -> String { self == .en ? en : ko }
}
