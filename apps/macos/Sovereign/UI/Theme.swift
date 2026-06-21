// Theme.swift — GENERATED from design/tokens.json by design/gen_theme.py.
// DO NOT EDIT BY HAND: edit tokens.json (or import the designer's Figma
// token export) and run design/sync_tokens.sh.

import SwiftUI

enum Theme {
    enum Colors {
        // Adaptive accent: indigo in light mode, bright skyblue in dark mode (brighter on dark surfaces).
        static let accent = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0.3490, green: 0.7176, blue: 0.9686, alpha: 1.0)   // skyblue (dark)
                : NSColor(red: 0.3529, green: 0.4039, blue: 0.8471, alpha: 1.0)   // indigo (light)
        })
        static let brandMark = Color(red: 0.2784, green: 0.6824, blue: 0.9569, opacity: 1.0)  // bright skyblue — Madiscribe wordmark
        static let recording = Color(red: 0.8980, green: 0.2824, blue: 0.3020, opacity: 1.0)
        static let meterFill = Color(red: 0.2039, green: 0.7804, blue: 0.4824, opacity: 1.0)
        static let meterTrack = Color(nsColor: .quaternaryLabelColor)
        static let surface = Color(nsColor: .controlBackgroundColor)
        static let surfaceSunken = Color(nsColor: .windowBackgroundColor)
        static let separator = Color(nsColor: .separatorColor)
        static let textPrimary = Color(nsColor: .labelColor)
        static let textSecondary = Color(nsColor: .secondaryLabelColor)
        static let textTertiary = Color(nsColor: .tertiaryLabelColor)
        static let overlapMarker = Color(red: 0.9490, green: 0.6000, blue: 0.2902, opacity: 1.0)
        static let lowConf = Color(red: 0.8510, green: 0.5137, blue: 0.1412, opacity: 1.0)
        static let speakerPalette: [Color] = [
            Color(red: 0.3529, green: 0.4039, blue: 0.8471, opacity: 1.0),  // indigo
            Color(red: 0.1843, green: 0.6314, blue: 0.6588, opacity: 1.0),  // teal
            Color(red: 0.8784, green: 0.6000, blue: 0.1647, opacity: 1.0),  // amber
            Color(red: 0.8784, green: 0.3765, blue: 0.5412, opacity: 1.0),  // rose
            Color(red: 0.2627, green: 0.6471, blue: 0.4196, opacity: 1.0),  // green
            Color(red: 0.6078, green: 0.4235, blue: 0.8471, opacity: 1.0),  // violet
            Color(red: 0.8784, green: 0.4627, blue: 0.2980, opacity: 1.0),  // coral
            Color(red: 0.2431, green: 0.5608, blue: 0.8157, opacity: 1.0),  // sky
        ]
        static func speaker(_ id: Int) -> Color {
            speakerPalette[((id % speakerPalette.count) + speakerPalette.count) % speakerPalette.count]
        }
    }
    enum Fonts {
        static let appTitle = Font.system(size: 19, weight: .bold, design: .rounded)
        static let section = Font.system(size: 11, weight: .semibold, design: .rounded)
        static let display = Font.system(size: 15, weight: .regular, design: .rounded)
        static let speaker = Font.system(size: 12, weight: .semibold, design: .rounded)
        static let timestamp = Font.system(size: 11, weight: .regular, design: .monospaced)
        static let body = Font.system(size: 14, weight: .regular)
        static let status = Font.system(size: 11, weight: .regular)
        static let overlap = Font.system(size: 11, weight: .regular).italic()
    }
    enum Space {
        static let window: CGFloat = 20
        static let controlBar: CGFloat = 12
        static let lineGap: CGFloat = 14
        static let chipGap: CGFloat = 8
        static let lineInner: CGFloat = 4
        static let panelGap: CGFloat = 16
        static let cardPad: CGFloat = 16
    }
    enum Size {
        static let windowMinW: CGFloat = 760
        static let windowMinH: CGFloat = 520
        static let sidePanelW: CGFloat = 300
        static let speakerDot: CGFloat = 9
        static let meterW: CGFloat = 120
        static let meterH: CGFloat = 8
        static let gateIcon: CGFloat = 52
        static let gateProgressW: CGFloat = 320
    }
    enum Radius {
        static let meter: CGFloat = 4
        static let button: CGFloat = 10
        static let card: CGFloat = 14
        static let panel: CGFloat = 18
        static let dropZone: CGFloat = 12
    }
}
