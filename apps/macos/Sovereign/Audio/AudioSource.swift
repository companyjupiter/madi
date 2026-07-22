// AudioSource.swift — capture-source identity and its permission contract.
// Kept pure so the pre-countdown policy is testable without AVFoundation or UI.

import Foundation

/// Where the audio comes from. `system` = ScreenCaptureKit (Teams/Slack/YouTube);
/// `both` = mic + system mixed (online meeting: you + remote participants).
enum AudioSource: String, CaseIterable, Identifiable {
    case mic, system, both

    var id: String { rawValue }
    var label: String { label(.ko) }

    func label(_ lang: UILanguage) -> String {
        switch self {
        case .mic:    return lang("마이크", "Microphone")
        case .system: return lang("시스템 오디오", "System audio")
        case .both:   return lang("마이크+시스템", "Mic + system")
        }
    }
}

enum AudioPermissionKind: Equatable {
    case microphone
    case systemAudio
}

enum AudioPermissionIssue: Equatable {
    case microphoneDenied
    case systemAudioDenied
    case systemAudioRestartRequired
}

enum AudioPermissionPolicy {
    static func required(for source: AudioSource) -> [AudioPermissionKind] {
        switch source {
        case .mic:    return [.microphone]
        case .system: return [.systemAudio]
        case .both:   return [.microphone, .systemAudio]
        }
    }

    static func requires(_ permission: AudioPermissionKind, for source: AudioSource) -> Bool {
        required(for: source).contains(permission)
    }
}
