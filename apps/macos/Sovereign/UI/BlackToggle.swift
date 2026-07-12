// BlackToggle.swift — the pill toggle used across the redesign (Figma 209:1493):
// black capsule + white knob when ON, gray when OFF. Replaces the system .switch
// (which tints blue and insets its track) so the start panel and the right panel
// share one look.

import SwiftUI

struct BlackToggle: View {
    @Binding var isOn: Bool

    // ON = near-black #141616 (de-accent pass — was accent indigo). The white
    // knob always reads against it; on a dark window the track blends into the
    // background but the knob still marks the ON state. OFF = adaptive mid-gray.
    private static let onFill = Color(red: 20/255, green: 22/255, blue: 22/255)
    private static let offFill = Theme.Colors.switchOffTrack

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? Self.onFill : Self.offFill)
                .frame(width: 28, height: 16)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 12, height: 12).padding(2)
                }
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: isOn)
    }
}
