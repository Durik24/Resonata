import Combine
import SwiftUI

/// A moment in the closed notch that isn't the song: it slides out like the
/// song peek, with its own picture in the cover's place, two lines of text
/// and a symbol where the bars are. See `ActivityPeek`.
enum NotchActivity: Equatable {
    /// The charger was just plugged in.
    case charging(percent: Int)
    /// The battery has just dropped to a warning level.
    case lowBattery(percent: Int)
    /// Sound has just moved to these headphones.
    case headphones(name: String)
    /// An event in the calendar starts soon.
    case meeting(title: String, start: Date)
    /// The timer has run out; the minutes it ran for.
    case timerDone(minutes: Int)
    /// A Pomodoro phase has begun: a break, or back to work.
    case pomodoro(rest: Bool, minutes: Int)
    /// A newer Resonata is out; installed from the right-click menu.
    case update(version: String)

    /// How long it stays out. Long enough to read; a meeting or a finished
    /// timer is worth a little longer.
    var duration: TimeInterval {
        switch self {
        case .charging, .lowBattery, .headphones: 3
        case .meeting, .timerDone, .pomodoro, .update: 6
        }
    }

    /// Worth showing late. With the panel open the notch can't slide out;
    /// a reminder, a warning or the end of the timer then waits for it to
    /// close, while "charging" or "headphones connected" is old news by then.
    var waitsForClose: Bool {
        switch self {
        case .lowBattery, .meeting, .timerDone, .pomodoro, .update: true
        case .charging, .headphones: false
        }
    }

    var look: ActivityLook {
        switch self {
        case .charging(let percent):
            ActivityLook(symbol: "bolt.fill", tint: ActivityLook.green, title: L.t("Charging", "Nabíjení"),
                         detail: "\(percent) %",
                         trailing: Battery(percent: percent, charging: false).symbol)
        case .lowBattery(let percent):
            ActivityLook(symbol: "exclamationmark.triangle.fill", tint: ActivityLook.red,
                         title: L.t("Low battery", "Slabá baterie"), detail: "\(percent) %",
                         trailing: Battery(percent: percent, charging: false).symbol)
        case .headphones(let name):
            ActivityLook(symbol: "headphones", tint: ActivityLook.blue, title: name,
                         detail: L.t("Connected", "Připojeno"), trailing: "speaker.wave.2.fill")
        case .meeting(let title, let start):
            ActivityLook(symbol: "calendar", tint: ActivityLook.orange, title: title,
                         detail: Self.meetingDetail(start: start, now: Date()), trailing: "clock.fill")
        case .timerDone(let minutes):
            ActivityLook(symbol: "timer", tint: ActivityLook.orange, title: L.t("Time's up", "Čas vypršel"),
                         detail: "\(minutes) min", trailing: "bell.fill")
        case .pomodoro(let rest, let minutes):
            rest
                ? ActivityLook(symbol: "cup.and.saucer.fill", tint: ActivityLook.green, title: L.t("Break", "Pauza"),
                               detail: "\(minutes) min", trailing: "bell.fill")
                : ActivityLook(symbol: "timer", tint: ActivityLook.orange, title: L.t("Back to work", "Zpátky do práce"),
                               detail: "\(minutes) min", trailing: "bell.fill")
        case .update(let version):
            ActivityLook(symbol: "arrow.down.circle.fill", tint: ActivityLook.blue, title: L.t("New version \(version)", "Nová verze \(version)"),
                         detail: L.t("Right-click", "Klikni pravým"), trailing: "sparkles")
        }
    }

    /// "in 5 min · 14:00" ("za 5 min · 14:00"), or "now · 14:00" once it has started.
    nonisolated static func meetingDetail(start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded())
        let time = start.formatted(.dateTime.hour().minute().locale(L.locale))
        return minutes > 0 ? L.t("in \(minutes) min · \(time)", "za \(minutes) min · \(time)")
                           : L.t("now · \(time)", "teď · \(time)")
    }
}

/// What an activity looks like in the closed notch.
struct ActivityLook {
    /// In the cover's place.
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    /// In the bars' place.
    var trailing: String

    static let green = Color(red: 0.2, green: 0.84, blue: 0.4)
    static let red = Color(red: 1, green: 0.32, blue: 0.3)
    static let blue = Color(red: 0.36, green: 0.62, blue: 1)
    static let orange = Color(red: 1, green: 0.62, blue: 0.25)
}

/// Shows an activity in the closed notch for its `duration`, then slides it
/// back in — still showing the activity until it's in, so the song's title
/// never flashes up in its place mid-slide.
@MainActor
final class ActivityPeek {

    private let model: NotchModel
    private var hide: DispatchWorkItem?
    /// Came while the panel was open — see `NotchActivity.waitsForClose`.
    private var waiting: NotchActivity?
    private var closed: AnyCancellable?

    /// How long the pill takes to slide in or settle after a close, at the
    /// animation speed chosen — a fixed 0.6 s was short of the slow one.
    private nonisolated static var slide: TimeInterval { Preferences.animationSpeed.settleTime + 0.05 }

    init(model: NotchModel) {
        self.model = model
        // Each time the panel closes, show what came while it was open —
        // once the close has played, so it slides out of a settled pill.
        closed = model.$isExpanded
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.slide) {
                    MainActor.assumeIsolated { self?.showWaiting() }
                }
            }
    }

    func show(_ activity: NotchActivity) {
        guard !model.isExpanded else {
            if activity.waitsForClose { waiting = activity }
            return
        }
        model.activity = activity
        model.activityShown = true
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.slideBack() }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + activity.duration, execute: work)
    }

    private func showWaiting() {
        guard let activity = waiting, !model.isExpanded else { return }
        waiting = nil
        show(activity)
    }

    /// If the song is peeking already, it takes over at once instead.
    private func slideBack() {
        model.activityShown = false
        guard !model.songPeeking else { model.activity = nil; return }
        let clear = DispatchWorkItem { [weak self] in
            guard let self, !self.model.activityShown else { return }
            self.model.activity = nil
        }
        hide = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slide, execute: clear)
    }
}
