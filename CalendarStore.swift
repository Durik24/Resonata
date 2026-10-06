import AppKit
import EventKit

/// The days around today and their events, for the open panel's calendar.
///
/// Read-only, and nothing is asked of macOS until you click "Připojit
/// kalendář" — the calendar prompt is yours to answer, and the panel works
/// the same without it, just with no events under the days.
@MainActor
final class CalendarStore: ObservableObject {

    static let shared = CalendarStore()

    enum Access { case notAsked, granted, denied }

    struct Event: Identifiable, Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
    }

    @Published private(set) var access: Access
    /// Every event in the days the panel shows, earliest first.
    @Published private(set) var events: [Event] = []

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    init() {
        access = Self.currentAccess()
        // Fires for edits made anywhere — Calendar.app, a sync — so the panel
        // never shows a meeting that was moved an hour ago.
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    nonisolated static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func requestAccess() {
        // An accessory app has to step forward for the prompt to take clicks.
        NSApp.activate(ignoringOtherApps: true)
        store.requestFullAccessToEvents { granted, _ in
            Task { @MainActor [weak self] in
                self?.access = granted ? .granted : .denied
                self?.reload()
            }
        }
    }

    /// Calendar access is switched on in System Settings, never from here.
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Re-reads the shown days. Cheap: five days of one person's calendars.
    func reload(now: Date = Date()) {
        access = Self.currentAccess()
        guard access == .granted else { events = []; return }
        let days = Self.days(around: now)
        guard let first = days.first, let last = days.last,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return }
        let predicate = store.predicateForEvents(withStart: first, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .map { Event(id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)",
                         title: $0.title ?? "",
                         start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    func events(on day: Date) -> [Event] {
        Self.events(events, on: day)
    }

    /// Events that touch `day` at all — one running past midnight shows on
    /// both days, the way Calendar.app lists it.
    nonisolated static func events(_ events: [Event], on day: Date,
                                   calendar: Calendar = .current) -> [Event] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter { $0.start < end && $0.end > start }
    }

    /// Two days either side of today, each at its midnight.
    nonisolated static func days(around date: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: date)
        return (-2...2).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }
}
