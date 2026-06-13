// Theme.swift — GENERATED from design/tokens.json by design/gen_theme.py.
// DO NOT EDIT BY HAND: edit tokens.json (or import the designer's Figma
// token export) and run design/sync_tokens.sh.

import SwiftUI

enum Theme {
    enum Colors {
        static let accent = Color(red: 0.0000, green: 0.4784, blue: 1.0000, opacity: 1.0)
        static let recording = Color(red: 1.0000, green: 0.2314, blue: 0.1882, opacity: 1.0)
        static let meterFill = Color(red: 0.1569, green: 0.8039, blue: 0.2549, opacity: 1.0)
        static let meterTrack = Color(red: 0.0000, green: 0.0000, blue: 0.0000, opacity: 0.1)
        static let textPrimary = Color(red: 0.0000, green: 0.0000, blue: 0.0000, opacity: 0.85)
        static let textSecondary = Color(red: 0.2353, green: 0.2353, blue: 0.2627, opacity: 0.6)
        static let textTertiary = Color(red: 0.2353, green: 0.2353, blue: 0.2627, opacity: 0.3)
        static let overlapMarker = Color(red: 1.0000, green: 0.5843, blue: 0.0000, opacity: 1.0)
        static let lowConf = Color(red: 1.0000, green: 0.6235, blue: 0.0392, opacity: 1.0)
        static let speakerPalette: [Color] = [
            Color(red: 0.0000, green: 0.4784, blue: 1.0000, opacity: 1.0),  // blue
            Color(red: 1.0000, green: 0.5843, blue: 0.0000, opacity: 1.0),  // orange
            Color(red: 0.1569, green: 0.8039, blue: 0.2549, opacity: 1.0),  // green
            Color(red: 0.6863, green: 0.3216, blue: 0.8706, opacity: 1.0),  // purple
            Color(red: 1.0000, green: 0.1765, blue: 0.3333, opacity: 1.0),  // pink
            Color(red: 0.1882, green: 0.6902, blue: 0.7804, opacity: 1.0),  // teal
            Color(red: 1.0000, green: 0.2314, blue: 0.1882, opacity: 1.0),  // red
            Color(red: 0.3451, green: 0.3373, blue: 0.8392, opacity: 1.0),  // indigo
        ]
        static func speaker(_ id: Int) -> Color {
            speakerPalette[((id % speakerPalette.count) + speakerPalette.count) % speakerPalette.count]
        }
    }
    enum Fonts {
        static let appTitle = Font.system(size: 17, weight: .bold)
        static let speaker = Font.system(size: 10, weight: .bold)
        static let timestamp = Font.system(size: 10, weight: .regular)
        static let body = Font.system(size: 13, weight: .regular)
        static let status = Font.system(size: 10, weight: .regular)
        static let overlap = Font.system(size: 10, weight: .regular).italic()
    }
    enum Space {
        static let window: CGFloat = 16
        static let controlBar: CGFloat = 12
        static let lineGap: CGFloat = 10
        static let chipGap: CGFloat = 6
        static let lineInner: CGFloat = 2
    }
    enum Size {
        static let windowMinW: CGFloat = 720
        static let windowMinH: CGFloat = 480
        static let speakerDot: CGFloat = 8
        static let meterW: CGFloat = 120
        static let meterH: CGFloat = 10
        static let gateIcon: CGFloat = 48
        static let gateProgressW: CGFloat = 320
    }
    enum Radius {
        static let meter: CGFloat = 5
    }
}
