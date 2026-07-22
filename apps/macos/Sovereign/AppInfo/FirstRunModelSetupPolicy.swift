// FirstRunModelSetupPolicy.swift — pure policy behind the first-launch model
// guide. The view owns presentation; this file owns the product invariants so
// existing installs, transcription-only setup, and the recommended DNA setup
// can be regression-tested without SwiftUI.

import Foundation

enum FirstRunModelSetupChoice: Equatable {
    case transcriptionOnly
    case recommended
}

enum FirstRunModelSetupPolicy {
    /// A valid Whisper model is the only unconditional launch requirement.
    /// Existing installs have no first-run choice and must enter immediately.
    /// A user who explicitly chose the recommended setup waits for DNA too, but
    /// can change the choice to transcriptionOnly while DNA keeps downloading.
    static func canEnterApp(requiredModelReady: Bool,
                            translationModelReady: Bool,
                            translationEngineAvailable: Bool,
                            choice: FirstRunModelSetupChoice?) -> Bool {
        guard requiredModelReady else { return false }
        guard choice == .recommended, translationEngineAvailable else { return true }
        return translationModelReady
    }

    static func downloadBytes(choice: FirstRunModelSetupChoice,
                              requiredModelReady: Bool,
                              translationModelReady: Bool,
                              translationAssetBytes: Int64) -> Int64 {
        let required = requiredModelReady ? 0 : AssetManifest.model.sizeBytes
        let optional = choice == .recommended && !translationModelReady
            ? translationAssetBytes : 0
        return required + optional
    }
}
