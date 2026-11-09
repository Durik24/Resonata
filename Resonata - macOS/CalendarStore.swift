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
    /// Showing `Demo`'s invented events: the real calendar isn't read.
    private var demo = false

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
        guard !demo else { return }
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

    /// `Demo` only: show these instead of the calendar's events.
    func showDemo(_ list: [Event]) {
        demo = true
        access = .granted
        events = list
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

/// Five minutes before an event, the closed notch slides out with its name
/// and time — see `NotchActivity.meeting`. Only with calendar access, and
/// only for events with a time (not all-day ones), once each.
@MainActor
final class MeetingReminder {

    /// How long before the start the reminder comes.
    static let lead: TimeInterval = 5 * 60

    var onReminder: ((CalendarStore.Event) -> Void)?

    private let store: CalendarStore
    private var timer: Timer?
    private var reminded = Set<String>()

    init(store: CalendarStore? = nil) {
        self.store = store ?? .shared
    }

    /// Checks once a minute: five days of one person's calendars is a cheap
    /// read, and a minute is as fine as a reminder needs to be.
    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check(now: Date = Date()) {
        guard Preferences.meetingReminder, CalendarStore.currentAccess() == .granted else { return }
        store.reload(now: now)
        guard let next = Self.due(store.events, now: now, lead: Self.lead)
            .first(where: { !reminded.contains($0.id) }) else { return }
        reminded.insert(next.id)
        onReminder?(next)
    }

    /// Timed events starting within `lead` from now, soonest first.
    nonisolated static func due(_ events: [CalendarStore.Event], now: Date,
                                lead: TimeInterval) -> [CalendarStore.Event] {
        events.filter { !$0.isAllDay && $0.start > now && $0.start.timeIntervalSince(now) <= lead }
            .sorted { $0.start < $1.start }
    }
}
