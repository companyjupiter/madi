// L10n.swift — lightweight, runtime-switchable UI language (한국어 / English / 日本語).
//
// The app is built with swiftc (no Xcode project / .strings / String Catalog) and
// needs a LIVE toggle — switching from Settings, not just following the system
// locale — so this is a per-app string helper rather than NSLocalizedString.
//
// Usage in a view:
//     @AppStorage("uiLanguage") private var uiLang = UILanguage.ko
//     Text(uiLang("녹음 시작", "Start recording"))            // ja falls back to English
//     Text(uiLang("녹음 시작", "Start recording", "録音開始")) // ja provided
//
// Reading @AppStorage makes the view re-render the instant the language flips.
// Keeping the strings inline makes each label easy to see and tune, and avoids a
// parallel key table drifting out of sync. The Japanese argument is OPTIONAL: a
// call site that hasn't been translated yet omits it and Japanese users see the
// English string (the international fallback) rather than Korean — so 日本語 can be
// filled in incrementally without touching every call at once. Default 한국어 — no
// behavior change until toggled in 설정 → 표시 → 언어.

import Foundation

enum UILanguage: String, CaseIterable, Identifiable {
    case ko, en, ja
    var id: String { rawValue }

    /// Endonym shown in the language picker (each name in its own language).
    var nativeName: String {
        switch self {
        case .ko: return "한국어"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }

    /// Pick the string for the current language: `uiLang("입력 언어", "Input language")`.
    /// Japanese resolves in order: an inline `ja` argument (for interpolated /
    /// context-specific strings), then the central `L10nJa.table` keyed on the
    /// English string, then the English string itself (graceful fallback — never
    /// Korean).
    func callAsFunction(_ ko: String, _ en: String, _ ja: String? = nil) -> String {
        switch self {
        case .ko: return ko
        case .en: return en
        case .ja: return ja ?? L10nJa.table[en] ?? en
        }
    }
}
