// Resolve the shipping SwiftUI tokens using AppKit, without an inference engine.
// This records an OS-specific reference; it does not certify another WebView.
import AppKit
import SwiftUI

@main
struct ThemeOracle {
    static func main() throws {
        let colors: [(String, Color)] = [
            ("accent", Theme.Colors.accent), ("brand-mark", Theme.Colors.brandMark),
            ("recording", Theme.Colors.recording), ("meter-fill", Theme.Colors.meterFill),
            ("meter-track", Theme.Colors.meterTrack), ("surface", Theme.Colors.surface),
            ("surface-sunken", Theme.Colors.surfaceSunken),
            ("surface-raised", Theme.Colors.surfaceRaised),
            ("surface-elevated", Theme.Colors.surfaceElevated),
            ("segment-selected", Theme.Colors.segmentSelected),
            ("hairline", Theme.Colors.hairline), ("separator", Theme.Colors.separator),
            ("text-primary", Theme.Colors.textPrimary),
            ("text-secondary", Theme.Colors.textSecondary),
            ("text-tertiary", Theme.Colors.textTertiary),
            ("overlap-marker", Theme.Colors.overlapMarker), ("low-conf", Theme.Colors.lowConf),
            ("ink-strong", Theme.Colors.inkStrong), ("ink-strong-on", Theme.Colors.inkStrongOn),
            ("switch-off-track", Theme.Colors.switchOffTrack),
        ] + Theme.Colors.speakerMids.enumerated().map { ("speaker-\($0.offset)", $0.element) }
        var appearances: [String: [String: [Double]]] = [:]
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: appearanceName) else { fatalError("Missing appearance") }
            var resolved: [String: [Double]] = [:]
            appearance.performAsCurrentDrawingAppearance {
                for (key, color) in colors {
                    guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { fatalError("Unresolved \(key)") }
                    resolved[key] = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
                }
            }
            appearances[name] = resolved
        }
        let result: [String: Any] = [
            "schemaVersion": 1,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "colorSpace": "sRGB",
            "appearances": appearances,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
