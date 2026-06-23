// CaptionOverlay.swift — a borderless, always-on-top, non-activating panel that
// shows live TRANSLATED captions during a meeting, floating over the call app
// (Zoom/Teams/etc.) and even fullscreen, without stealing focus. The data is
// already there (per-line translations + the live interim); the only new piece
// is the AppKit window infrastructure this file provides.
//
// Owned by SessionController so the SwiftUI caption view binds to the SAME live
// @Observable state the main window does. A non-activating NSPanel is the right
// primitive: it never becomes key, so typing/clicks keep going to the meeting.

import AppKit
import SwiftUI

@MainActor
final class CaptionOverlayController {
    private var panel: NSPanel?

    /// Show the panel hosting `content`, created once per show so a single
    /// NSHostingView stays subscribed to @Observable updates while visible.
    func show<Content: View>(_ content: Content) {
        let p = panel ?? makePanel()
        p.contentView = NSHostingView(rootView: content)
        panel = p
        positionBottomCenter(p)
        p.orderFrontRegardless()      // show without activating Madi
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar                                   // above ordinary windows
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true                   // drag the caption anywhere
        p.hidesOnDeactivate = false                            // stay up when Madi loses focus
        return p
    }

    private func positionBottomCenter(_ p: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame, sz = p.frame.size
        p.setFrameOrigin(NSPoint(x: vf.midX - sz.width / 2, y: vf.minY + 90))
    }
}

/// The caption content — latest translated line (big) + its original (small),
/// falling back to the live interim while a translation is still in flight.
/// Explicit dark/white colors (not Theme): it floats over arbitrary apps, so it
/// owns a fixed legible look regardless of the host's appearance.
struct CaptionView: View {
    @Bindable var session: SessionController
    var onClose: () -> Void = {}

    /// Preferred caption language = first chosen translate target (alpha order).
    private var lang: String? { session.translateTargets.sorted().first }

    /// Latest line that has ANY translation; prefer the chosen language but fall
    /// back to whatever translation exists so a key mismatch never blanks it.
    private var latest: (orig: String, trans: String)? {
        guard let l = session.transcript.lines.last(where: { !$0.translations.isEmpty }) else { return nil }
        let t = (lang.flatMap { l.translations[$0] }) ?? l.translations.values.first ?? ""
        return t.isEmpty ? nil : (l.text, t)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble.fill").font(.system(size: 12))
                Text("실시간 자막" + (lang.map { " · \($0)" } ?? ""))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11)) }
                    .buttonStyle(.plain)
            }
            .foregroundStyle(.white.opacity(0.65))

            if let c = latest {
                Text(c.trans).font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                Text(c.orig).font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.tail)
            } else if !session.livePartial.isEmpty {
                Text(session.livePartial).font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.8)).italic().lineLimit(2)
            } else {
                Text("음성을 기다리는 중…").font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(18)
        .frame(width: 724, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.78)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .padding(8)
    }
}
