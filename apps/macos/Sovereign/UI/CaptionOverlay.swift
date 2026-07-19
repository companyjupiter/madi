// CaptionOverlay.swift — borderless, always-on-top, non-activating caption
// panels. Two audiences (clinic display batch, 2026-07-05):
//   .staff   — compact caption on the main screen (staff reads Korean-side / the
//              first translate target), draggable, over the call app.
//   .patient — large caption for a 1.5–2.5 m viewing distance, optionally on an
//              external monitor, in the PATIENT's language.
// The data is already there (per-line translations + live interim); this file
// owns the AppKit window infrastructure + the audience-specific look.

import AppKit
import SwiftUI

enum CaptionAudience { case staff, patient }

@MainActor
final class CaptionOverlayController {
    private var staffPanel: NSPanel?
    private var patientPanel: NSPanel?

    /// Show/refresh the staff caption and (optionally) a patient caption. Called
    /// on every settings change so sizing/target updates live.
    func show(staff: some View, patient: (some View)?, settings: CaptionSettings) {
        let sp = staffPanel ?? makePanel(width: settings.panelWidth, height: 150)
        sp.setContentSize(NSSize(width: settings.panelWidth, height: sp.frame.height))
        sp.contentView = NSHostingView(rootView: staff)
        staffPanel = sp
        positionBottomCenter(sp, on: .main)
        sp.orderFrontRegardless()

        if let patient {
            // patient panel: sized for distance, on the chosen screen.
            let screen = screenAt(settings.patientScreenIndex)
            let w = max(settings.panelWidth, 900.0)
            let pp = patientPanel ?? makePanel(width: w, height: 220)
            pp.setContentSize(NSSize(width: w, height: pp.frame.height))
            pp.contentView = NSHostingView(rootView: patient)
            patientPanel = pp
            positionBottomCenter(pp, on: screen)
            pp.orderFrontRegardless()
        } else {
            patientPanel?.orderOut(nil); patientPanel = nil
        }
    }

    func hide() {
        staffPanel?.orderOut(nil)
        patientPanel?.orderOut(nil)
    }

    private func makePanel(width: CGFloat, height: CGFloat) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        return p
    }

    private func screenAt(_ index: Int?) -> NSScreen? {
        guard let index, index >= 0, index < NSScreen.screens.count else { return NSScreen.main }
        return NSScreen.screens[index]
    }
    private func positionBottomCenter(_ p: NSPanel, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame, sz = p.frame.size
        p.setFrameOrigin(NSPoint(x: vf.midX - sz.width / 2, y: vf.minY + 90))
    }
}

/// The caption content. Audience decides the language + sizing:
///   .staff   → first translate target (or none), compact.
///   .patient → session.patientCaptionLang, large.
struct CaptionView: View {
    @Bindable var session: SessionController
    var audience: CaptionAudience = .staff
    var onClose: (() -> Void)? = nil
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko

    private var settings: CaptionSettings { session.captionSettings }
    private var lang: String? {
        audience == .patient ? session.patientCaptionLang : session.translateTargets.sorted().first
    }
    private var transFont: CGFloat {
        audience == .patient ? settings.patientFontSize : settings.staffFontSize
    }

    private func pick(_ d: [String: String]) -> String? {
        let t = (lang.flatMap { d[$0] }) ?? d.values.first
        return (t?.isEmpty == false) ? t : nil
    }

    /// Newest first: PROVISIONAL interim translation (tracks speech in ~1 s),
    /// else the latest committed line's authoritative translation. `speaker` is
    /// the committed source line's speaker (nil for interim).
    private var caption: (trans: String, orig: String, live: Bool, speaker: Int?)? {
        if !session.livePartial.isEmpty, let t = pick(session.livePartialTranslations) {
            return (t, session.livePartial, true, nil)
        }
        if let l = session.transcript.lines.last(where: { !$0.translations.isEmpty }),
           let t = pick(l.translations) {
            return (t, l.text, false, l.speaker)
        }
        return nil
    }

    private var statusKind: CaptionStatus {
        if caption?.live == true { return .live }
        if !session.livePartial.isEmpty { return .translating }
        return .waiting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: audience == .patient ? 10 : 6) {
            header
            if let c = caption {
                if let sp = c.speaker, session.speakerNames.count + 1 > 1 {
                    speakerTag(sp)   // C17: who said it
                }
                Text(c.trans)
                    .font(.system(size: transFont, weight: .semibold))
                    .foregroundStyle(.white.opacity(c.live ? 0.85 : 1))
                    .lineLimit(audience == .patient ? 3 : 2)
                    .minimumScaleFactor(settings.minScaleFactor)   // B12: 0.9, not 0.6
                Text(c.orig)
                    .font(.system(size: transFont * 0.5))
                    .foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.tail)
            } else if !session.livePartial.isEmpty {
                Text(session.livePartial)
                    .font(.system(size: transFont * 0.85))
                    .foregroundStyle(.white.opacity(0.8)).italic().lineLimit(2)
            } else {
                // A5/D21: localized "waiting" + a live mic-level bar so the
                // speaker knows the system is listening.
                VStack(alignment: .leading, spacing: 8) {
                    Text(CaptionStatus.waiting.text(for: lang))
                        .font(.system(size: transFont * 0.7))
                        .foregroundStyle(.white.opacity(0.5))
                    micMeter
                }
            }
        }
        .padding(audience == .patient ? 24 : 18)
        .frame(width: (audience == .patient ? max(settings.panelWidth, 900) : settings.panelWidth) - 36,
               alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.78)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .padding(8)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "captions.bubble.fill").font(.system(size: 12))
            Text(uiLang("실시간 자막", "Live captions") + (lang.map { " · \($0)" } ?? ""))
                .font(.system(size: 12, weight: .medium))
            // A5: localized in-progress / translating status, in the caption lang
            if statusKind != .waiting {
                Text(statusKind.text(for: lang))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11)) }
                    .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white.opacity(0.65))
    }

    /// C17: speaker color dot + name (caption is otherwise speaker-blind).
    private func speakerTag(_ id: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.Colors.speaker(id)).frame(width: 8, height: 8)
            Text(SpeakerID.display(id, names: session.speakerNames, fallback: uiLang("화자 \(id)", "Speaker \(id)")))
                .font(.system(size: transFont * 0.42, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// D21: five-segment input level, lit by session.level (0…1).
    private var micMeter: some View {
        HStack(spacing: 3) {
            Image(systemName: "mic.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(Double(session.level) * 5 > Double(i) ? 0.7 : 0.15))
                    .frame(width: 5, height: CGFloat(6 + i * 3))
            }
        }
    }
}
