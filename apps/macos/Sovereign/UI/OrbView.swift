// OrbView.swift — the glowing blue orb from Figma (node 26:27, "Orb"), replacing
// the system-icon halo in the idle empty state. Built from the raw SVG markup
// (mask + blurred gradient circle + two blurred highlight blobs + drop shadow)
// rather than an exported image, so it scales cleanly and can carry the
// floating + pulsing motion Figma defines for this node (4s loop: translateY
// up to ~3.9px and scale 1→1.075→1, both ease in/out).

import SwiftUI

struct OrbView: View {
    var size: CGFloat = 70

    @State private var animate = false
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.749, green: 0.875, blue: 1.0),     // #BFDFFF
                             Color(red: 0.239, green: 0.325, blue: 1.0)],    // #3D53FF
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                // subtle "breathing" inner glow — a soft radial bloom from the
                // center whose opacity rises and falls on its own slower cycle,
                // independent of the float/scale loop, so it doesn't read as a
                // hard pulse but as gentle light welling up and fading.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.55), Color.white.opacity(0)],
                            center: .center, startRadius: 0, endRadius: size * 0.45)
                    )
                    .opacity(breathe ? 1 : 0.1)
            )
            .overlay(
                ZStack {
                    Ellipse()
                        .fill(Color(red: 0.749, green: 0.914, blue: 1.0).opacity(0.77))  // #BFE9FF
                        .frame(width: size * 0.514, height: size * 0.529)
                        .position(x: size * 0.657, y: size * 0.343)
                        .blur(radius: size * 0.11)
                    Circle()
                        .fill(Color(red: 0.647, green: 0.431, blue: 1.0).opacity(0.41))  // #A56EFF
                        .frame(width: size * 0.429, height: size * 0.429)
                        .position(x: size * 0.557, y: size * 0.714)
                        .blur(radius: size * 0.11)
                }
                .clipShape(Circle())
            )
            .overlay(
                // inner shadow trick: a blurred light ring scaled slightly past the
                // rim so its blur falloff fuses with the true edge (clipped back to
                // the circle) instead of reading as a separate floating band inside.
                Circle()
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: size * 0.16)
                    .scaleEffect(1.08)
                    .blur(radius: size * 0.13)
                    .clipShape(Circle())
            )
            .frame(width: size, height: size)
            .shadow(color: Color(red: 21/255, green: 68/255, blue: 219/255).opacity(0.075),
                    radius: size * 0.314, x: 0, y: size * 0.486)
            .scaleEffect(animate ? 1.0375 : 1)
            .offset(y: animate ? -size * 0.0553 : 0)
            .animation(
                .timingCurve(0.5, 0, 0.5, 1, duration: 2)
                    .repeatForever(autoreverses: true),
                value: animate)
            .animation(
                .easeInOut(duration: 3).repeatForever(autoreverses: true),
                value: breathe)
            .onAppear { animate = true; breathe = true }
    }
}
