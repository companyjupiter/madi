// RecordingStartAdmission.swift — pure state-machine gate for entering the live
// engine path. Kept outside SessionController so the countdown-to-start boundary
// is regression-tested without AVFoundation, ScreenCaptureKit, or SwiftUI.

enum RecordingStartAdmission {
    enum State: Equatable {
        case idle
        case done
        case error
        case countdown(Int)
        case busy
    }

    static func allows(_ state: State) -> Bool {
        switch state {
        case .idle, .done, .error, .countdown(1): return true
        case .countdown, .busy: return false
        }
    }
}
