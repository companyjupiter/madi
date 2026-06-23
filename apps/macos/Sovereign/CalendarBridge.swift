// CalendarBridge.swift — read-only local Calendar (EventKit) glue: prefill the
// meeting's title + attendees from the event happening now, and after the
// session, match diarized speakers to attendees (and flag who never spoke).
//
// Fully local — EventKit reads the user's own calendars on this Mac; nothing is
// sent anywhere. Access is requested lazily on first use; a denial is a silent
// no-op (the feature simply stays dormant, never blocks recording). Owned by
// SessionController so the existing ContentView(session:) wiring reaches it.

import Foundation
import EventKit

@Observable
@MainActor
final class CalendarBridge {
    struct MeetingEvent: Sendable { let title: String; let attendees: [String]; let start: Date; let end: Date }

    private(set) var event: MeetingEvent?
    private(set) var matched: Set<String> = []   // attendees correlated to a speaker
    private(set) var absent: [String] = []        // expected attendees who never spoke
    private let store = EKEventStore()

    /// Load the calendar event covering "now" (nearest within −30…+90 min) to
    /// prefill context. Requests Calendar access on first use (macOS 14 full-access
    /// API, with a 13 fallback). Denial / no event → silent no-op.
    func loadCurrentEvent() async {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        guard granted else { return }
        // Run the SYNCHRONOUS EventKit query off the main actor — on large
        // calendars events(matching:) can block 100ms+, and this runs at record
        // start. Hop to a background queue, then assign back on @MainActor.
        let evStore = self.store
        let now = Date()
        let loaded: MeetingEvent? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Self.nearestEvent(store: evStore, now: now))
            }
        }
        event = loaded
    }

    /// Off-actor calendar query (EKEventStore is thread-safe for reads). Picks the
    /// nearest non-all-day event in −30…+90 min; nil if none or the event lacks
    /// start/end dates (corrupt entry) — caller treats nil as "no event".
    private nonisolated static func nearestEvent(store: EKEventStore, now: Date) -> MeetingEvent? {
        let cal = Calendar.current
        let lo = cal.date(byAdding: .minute, value: -30, to: now) ?? now
        let hi = cal.date(byAdding: .minute, value: 90, to: now) ?? now
        let pred = store.predicateForEvents(withStart: lo, end: hi, calendars: nil)
        let nearest = store.events(matching: pred)
            .filter { !$0.isAllDay }
            .min { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
        guard let e = nearest, let start = e.startDate, let end = e.endDate else { return nil }
        return MeetingEvent(title: e.title ?? "회의",
                            attendees: (e.attendees ?? []).compactMap { $0.name },
                            start: start, end: end)
    }

    /// Correlate attendee names to the diarized speaker names; flag who never
    /// spoke. Substring match both ways so "김부장" ↔ "김부장(PM)" still lines up.
    func matchToSpeakers(_ speakerNames: [Int: String]) {
        guard let ev = event else { return }
        let spoken = Set(speakerNames.values)
        var m: Set<String> = []; var ab: [String] = []
        for a in ev.attendees {
            if spoken.contains(where: { $0.contains(a) || a.contains($0) }) { m.insert(a) }
            else { ab.append(a) }
        }
        matched = m; absent = ab
    }

    func clear() { event = nil; matched = []; absent = [] }
}
