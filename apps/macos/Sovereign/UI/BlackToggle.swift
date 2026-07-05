// BlackToggle.swift — the pill toggle used across the redesign (Figma 209:1493):
// black capsule + white knob when ON, gray when OFF. Replaces the system .switch
// (which tints blue and insets its track) so the start panel and the right panel
// share one look.

import SwiftUI

struct BlackToggle: View {
    @Binding var isOn: Bool

    private static let onFill = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x16 / 255)   // #141616
    private static let offFill = Color(red: 0xcd / 255, green: 0xd2 / 255, blue: 0xd2 / 255)   // #cdd2d2

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
