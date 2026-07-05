// Theme.swift — design tokens. HAND-MAINTAINED (was originally generated from
// design/tokens.json by design/gen_theme.py, but the generator now (a) writes to
// a stale path `app/…` — the app lives in `apps/macos/…` — and (b) cannot emit
// the light/dark adaptive NSColor closures the redesign needs). Re-running it
// would REGRESS these adaptive colors, so it is NOT part of the build. Edit this
// file directly; keep tokens.json roughly in sync as the designer's reference.
//
// Dark-mode rule: any color used as a SURFACE (card/panel/track) or TEXT/ink must
// resolve per-appearance — use the adaptive tokens below (surface, surfaceSunken,
// textPrimary/Secondary/Tertiary, separator, inkStrong/inkStrongOn) rather than
// Color.white / .black / RGB literals, which stay fixed and break in dark mode.

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
        // Madi wordmark: indigo in light mode, bright skyblue in dark mode.
        static let brandMark = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0.2784, green: 0.6824, blue: 0.9569, alpha: 1.0)   // bright skyblue (dark)
                : NSColor(red: 0.3529, green: 0.4039, blue: 0.8471, alpha: 1.0)   // indigo (light)
        })
        static let recording = Color(red: 0.8980, green: 0.2824, blue: 0.3020, opacity: 1.0)
        static let meterFill = Color(red: 0.2039, green: 0.7804, blue: 0.4824, opacity: 1.0)
        static let meterTrack = Color(nsColor: .quaternaryLabelColor)
        static let surface = Color(nsColor: .controlBackgroundColor)
        // NSColor.windowBackgroundColor renders pure white (1,1,1) in light mode on
        // recent macOS, making "sunken" surfaces invisible against white cards —
        // override light mode with tokens.json's literal #F2F2F7; dark mode's
        // system value is fine as-is.
        static let surfaceSunken = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor.windowBackgroundColor
                : NSColor(red: 0.9490, green: 0.9490, blue: 0.9686, alpha: 1.0)   // #F2F2F7 (light)
        })
        static let separator = Color(nsColor: .separatorColor)
        static let textPrimary = Color(nsColor: .labelColor)
        static let textSecondary = Color(nsColor: .secondaryLabelColor)
        static let textTertiary = Color(nsColor: .tertiaryLabelColor)
        static let overlapMarker = Color(red: 0.9490, green: 0.6000, blue: 0.2902, opacity: 1.0)
        static let lowConf = Color(red: 0.8510, green: 0.5137, blue: 0.1412, opacity: 1.0)
        // Redesign's monochrome "selected chip / primary CTA" ink. Hand-authored
        // (gen_theme.py can't emit light/dark closures). INVERTS for dark so a
        // near-black chip on a light window becomes a near-white chip on a dark
        // window instead of vanishing. Paired glyph/text color = inkStrongOn.
        static let inkStrong = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0.9294, green: 0.9294, blue: 0.9451, alpha: 1.0)   // near-white (dark)
                : NSColor(red: 0.0784, green: 0.0863, blue: 0.0863, alpha: 1.0)   // #141616 (light)
        })
        static let inkStrongOn = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0.0784, green: 0.0863, blue: 0.0863, alpha: 1.0)   // near-black (dark)
                : NSColor.white                                                    // white (light)
        })
        // BlackToggle OFF track — a solid mid-gray capsule the white knob reads
        // against in both modes (#cdd2d2 light / mid-dark gray dark). ON uses accent.
        static let switchOffTrack = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0.2824, green: 0.2863, blue: 0.3020, alpha: 1.0)   // #48494D (dark)
                : NSColor(red: 0.8039, green: 0.8235, blue: 0.8235, alpha: 1.0)   // #cdd2d2 (light)
        })
        // First three overridden to the redesign's speaker palette
        // (Figma 188:662: #6773EB / #97D0FF / #BF97FF).
        static let speakerPalette: [Color] = [
            Color(red: 103/255, green: 115/255, blue: 235/255, opacity: 1.0),  // indigo
            Color(red: 151/255, green: 208/255, blue: 255/255, opacity: 1.0),  // light blue
            Color(red: 191/255, green: 151/255, blue: 255/255, opacity: 1.0),  // light purple
            Color(red: 107/255, green: 164/255, blue: 255/255, opacity: 1.0),  // blue (#6BA4FF)
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
        // Start-screen typography — rounded to match the "human companion" house
        // voice (raw .system literals on the first screen bypassed design:.rounded).
        static let startHeader = Font.system(size: 17, weight: .bold, design: .rounded)
        static let startTagline = Font.system(size: 13, weight: .medium, design: .rounded)
        static let label = Font.system(size: 12, weight: .semibold, design: .rounded)
        static let cta = Font.system(size: 12, weight: .semibold, design: .rounded)
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
