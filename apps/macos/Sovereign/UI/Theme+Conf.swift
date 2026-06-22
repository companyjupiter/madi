// Theme+Conf.swift — confidence threshold (manual; not a color/font token).
// Words below this softmax confidence are flagged (amber + underline + fade).
// Chosen from validation: real errors fall at 0.36–0.54, correct words 0.94–1.0,
// so the 0.55 default separates them with low false-positives (user-tunable).
import Foundation
extension Theme {
    /// UserDefaults key shared with the Settings VAD slider (@AppStorage).
    static let confKey = "vadConfThreshold"
    /// Words below this softmax confidence are flagged. User-adjustable via the
    /// Settings VAD slider; default 0.55 when unset. Read live so a change applies
    /// to subsequently-rendered transcript content.
    static var confThreshold: Double { UserDefaults.standard.object(forKey: confKey) as? Double ?? 0.55 }
}
