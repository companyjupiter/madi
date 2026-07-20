// LowMemoryGuidePolicy.swift — pure admission policy for the one-time 8 GB
// operating guide. A content revision (rather than the app version) avoids
// reopening the browser on every release while still allowing a materially
// updated guide to be shown once again.

import Foundation

enum LowMemoryGuidePolicy {
    static let currentRevision = 1
    static let presentedRevisionKey = "MADI8GBGuideRevision"
    static let manualSectionID = "11-eight-gb-guide"

    static func isEightGBClass(physicalMemory: UInt64) -> Bool {
        AssetManifest.recommendedTranslateModelVariant(physicalMemory: physicalMemory) == .realtime2B
    }

    static func shouldPresent(physicalMemory: UInt64, presentedRevision: Int,
                              currentRevision: Int = currentRevision) -> Bool {
        isEightGBClass(physicalMemory: physicalMemory) && presentedRevision < currentRevision
    }
}
