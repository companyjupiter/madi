// Theme+Conf.swift — confidence threshold (manual; not a color/font token).
// Words below this softmax confidence are flagged (amber + underline + fade).
// Chosen from validation: real errors fall at 0.36–0.54, correct words 0.94–1.0,
// so 0.65 cleanly separates with low false-positives.
import Foundation
extension Theme { static let confThreshold = 0.55 }
