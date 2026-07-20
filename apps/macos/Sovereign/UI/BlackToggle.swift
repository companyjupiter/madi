// BlackToggle.swift — the pill toggle used across the redesign (Figma 209:1493):
// black capsule + white knob when ON, gray when OFF. Replaces the system .switch
// (which tints blue and insets its track) so the start panel and the right panel
// share one look.

import SwiftUI

struct BlackToggle: View {
    @Binding var isOn: Bool

    // ON = inkStrong (near-black on light, INVERTS to near-white on dark — the
    // old fixed #141616 track vanished into a dark window, leaving a floating
    // knob). Knob pairs with inkStrongOn when ON. OFF = adaptive mid-gray.
    private static let onFill = Theme.Colors.inkStrong
    private static let offFill = Theme.Colors.switchOffTrack

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? Self.onFill : Self.offFill)
                .frame(width: 28, height: 16)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(isOn ? Theme.Colors.inkStrongOn : .white)
                        .frame(width: 12, height: 12).padding(2)
                }
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: isOn)
    }
}
