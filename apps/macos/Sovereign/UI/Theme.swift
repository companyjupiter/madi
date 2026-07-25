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
                // windowBackgroundColor equalled the card fill in dark, so every
                // sunken fill/outline vanished — one visible step above the base.
                ? NSColor(red: 0.2039, green: 0.2039, blue: 0.2275, alpha: 1.0)   // #34343A (dark)
                : NSColor(red: 0.9490, green: 0.9490, blue: 0.9686, alpha: 1.0)   // #F2F2F7 (light)
        })
        // Elevated card/panel fill. Light keeps the white card (elevation via
        // shadow); dark lifts the fill one step instead — black drop shadows
        // are invisible on a dark window, so fill contrast carries elevation.
        static let surfaceRaised = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0.1490, green: 0.1490, blue: 0.1686, alpha: 1.0)   // #26262B (dark)
                : NSColor.controlBackgroundColor                                   // white (light)
        })
        // Cards nested inside a raised panel (transport buttons, file/busy
        // cards). Light = white with its shadow; dark = a MODEST lift above the
        // panel (#26262B) — raised-on-raised was invisible, but a full-bright
        // fill overshot ("너무 밝아"), so the card whispers, not shouts.
        static let surfaceElevated = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0.1843, green: 0.1843, blue: 0.2078, alpha: 1.0)   // #2F2F35 (dark)
                : NSColor.controlBackgroundColor                                   // white (light)
        })
        // Selected segment/tab pill — must sit ABOVE the sunken track (#34343A)
        // or the active tab reads pressed-in. Kept separate from the card lift,
        // which is intentionally dimmer.
        static let segmentSelected = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0.2549, green: 0.2549, blue: 0.2863, alpha: 1.0)   // #414149 (dark)
                : NSColor.controlBackgroundColor                                   // white (light)
        })
        // Floating-panel hairline: near-invisible black in light, low-alpha
        // white in dark (a black hairline disappears on a dark surface).
        static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(white: 1.0, alpha: 0.12)
                : NSColor(white: 0.0, alpha: 0.04)
        })
        static let separator = Color(nsColor: .separatorColor)
        static let textPrimary = Color(nsColor: .labelColor)
        // Figma's textsecondary token is #3C3C43 at 60% — the system
        // secondaryLabelColor renders darker (0,0,0,0.5) in light mode, so
        // override light with the literal token; dark keeps the system value.
        static let textSecondary = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                // The system secondaryLabel (white 55%) reads far STRONGER on a
                // dark surface than light's #3C3C43@60% does on white — meta text
                // (timecodes, row icons) crowded the primary text. 45% restores
                // the same perceived primary→secondary step as light mode.
                ? NSColor(white: 1.0, alpha: 0.45)
                : NSColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.6)
        })
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
        private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
            Color(red: r / 255, green: g / 255, blue: b / 255)
        }

        // Speaker palette (Figma 306:540): each speaker is a two-stop GRADIENT,
        // ordered so consecutive speakers sit far apart on the wheel (amber →
        // pink → purple → mint → lime → cyan → blue → red) — fixing the old
        // set's blue-on-blue collisions. Large fills (the share bar) use the
        // gradient; small marks (speaker dots, energy dither) use the gradient's
        // MIDPOINT as a flat solid, since a gradient in a 3–6px area just reads
        // as a muddy single tone.
        static let speakerGradientStops: [(Color, Color)] = [
            (rgb(255, 209, 136), rgb(255, 169, 122)),  // 1 amber → orange
            (rgb(255, 143, 145), rgb(243, 154, 195)),  // 2 coral → pink
            (rgb(198, 157, 215), rgb(157, 171, 255)),  // 3 purple → periwinkle
            (rgb(126, 215, 197), rgb(158, 231, 177)),  // 4 teal → green
            (rgb(207, 230, 154), rgb(242, 215, 115)),  // 5 lime → yellow
            (rgb(113, 214, 217), rgb(128, 189, 229)),  // 6 cyan → blue
            (rgb(51, 169, 247),  rgb(143, 161, 239)),  // 7 blue → periwinkle
            (rgb(243, 145, 146), rgb(255, 107, 107)),  // 8 coral → red
        ]
        // Midpoint solids — precomputed average of each gradient's two stops.
        static let speakerMids: [Color] = [
            rgb(255, 189, 129), rgb(249, 149, 170), rgb(178, 164, 235), rgb(142, 223, 187),
            rgb(225, 223, 135), rgb(121, 202, 223), rgb(97, 165, 243), rgb(249, 126, 127),
        ]
        // Gradient direction ≈ Figma's 80° (shallow left→right, slight upward).
        static let speakerGradientStart = UnitPoint(x: 0, y: 0.6)
        static let speakerGradientEnd = UnitPoint(x: 1, y: 0.4)

        private static func speakerIndex(_ id: Int) -> Int {
            let n = speakerMids.count
            return ((id % n) + n) % n
        }
        /// Flat solid for small marks — the gradient's midpoint.
        static func speaker(_ id: Int) -> Color { speakerMids[speakerIndex(id)] }
        /// Full two-stop gradient for large fills (the share distribution bar).
        static func speakerGradient(_ id: Int) -> LinearGradient {
            let (a, b) = speakerGradientStops[speakerIndex(id)]
            return LinearGradient(colors: [a, b],
                                  startPoint: speakerGradientStart, endPoint: speakerGradientEnd)
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
