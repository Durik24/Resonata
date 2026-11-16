import Combine
import SwiftUI

/// Which way the closed pill grows for a message: sideways past the bars,
/// as the song does; sideways the other way, over the app's menus; or
/// downwards, under the cutout, where there is room for a picture.
enum PeekSide: Equatable, Sendable { case right, left, down }

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
    /// A Claude Code session has stopped to ask you something.
    case claudeWaiting(session: String, wants: String?, pid: Int32? = nil)
    /// A Claude Code session has finished what it was doing.
    case claudeDone(session: String, pid: Int32? = nil)
    /// A Mistral Vibe session has stopped to ask for an approval.
    case vibeWaiting(session: String, wants: String?, pid: Int32? = nil)
    /// A Mistral Vibe session has finished what it was doing.
    case vibeDone(session: String, pid: Int32? = nil)
    /// Two or more sessions are waiting at once: how many, and the one that
    /// has waited longest — `vibe` when that one is Vibe's.
    case sessionsWaiting(count: Int, session: String, wants: String?, pid: Int32? = nil, vibe: Bool = false)
    /// A file has landed in Downloads, or a screenshot was taken.
    case fileArrived(FileArrival)
    /// Somebody else pushed to a repository that is followed.
    case githubPush(who: String, repo: String, message: String, url: URL? = nil)
    /// The checks of a followed repository failed.
    case githubChecksFailed(repo: String, detail: String, url: URL? = nil)
    /// A followed repository has a new release.
    case githubRelease(repo: String, tag: String, url: URL? = nil)
    /// A Focus went on, or off.
    case focus(on: Bool)

    /// The process of the Claude Code or Vibe session this is about, for a
    /// click to go to.
    var sessionPid: Int32? {
        switch self {
        case .claudeWaiting(_, _, let pid), .claudeDone(_, let pid),
             .vibeWaiting(_, _, let pid), .vibeDone(_, let pid),
             .sessionsWaiting(_, _, _, let pid, _): pid
        default: nil
        }
    }

    /// The page a click on the message opens — GitHub's.
    var link: URL? {
        switch self {
        case .githubPush(_, _, _, let url), .githubChecksFailed(_, _, let url),
             .githubRelease(_, _, let url): url
        default: nil
        }
    }

    /// The file the message is about: a click shows it in Finder, and it can
    /// be dragged out of the notch.
    var file: FileArrival? {
        if case .fileArrived(let file) = self { file } else { nil }
    }

    /// Which way the pill grows for it. Each kind has its own: what comes
    /// from the Mac slides right, as it always has; what comes from other
    /// people slides left; a file drops down, where its picture fits.
    var side: PeekSide {
        switch self {
        case .fileArrived: .down
        case .githubPush, .githubChecksFailed, .githubRelease: .left
        default: .right
        }
    }

    /// A ring in the cover's place, amber and pulsing, instead of a symbol —
    /// and whose: Vibe's when true.
    var waitingRing: Bool? {
        switch self {
        case .claudeWaiting: false
        case .vibeWaiting: true
        case .sessionsWaiting(_, _, _, _, let vibe): vibe
        default: nil
        }
    }

    /// One of Claude Code's: its ring goes in the cover's place.
    var isClaude: Bool {
        switch self {
        case .claudeWaiting, .claudeDone: true
        default: false
        }
    }

    /// How long it stays out. Long enough to read; a meeting or a finished
    /// timer is worth a little longer.
    var duration: TimeInterval {
        switch self {
        case .charging, .lowBattery, .headphones, .focus: 3
        case .meeting, .timerDone, .pomodoro, .update, .claudeWaiting, .claudeDone,
             .vibeWaiting, .vibeDone, .sessionsWaiting, .fileArrived,
             .githubPush, .githubChecksFailed, .githubRelease: 6
        }
    }

    /// Worth showing late. With the panel open the notch can't slide out;
    /// a reminder, a warning or the end of the timer then waits for it to
    /// close, while "charging" or "headphones connected" is old news by then.
    var waitsForClose: Bool {
        switch self {
        case .lowBattery, .meeting, .timerDone, .pomodoro, .update, .claudeWaiting, .vibeWaiting,
             .sessionsWaiting, .fileArrived, .githubPush, .githubChecksFailed, .githubRelease: true
        // Finished while the panel was open: you were here, and saw it.
        case .charging, .headphones, .claudeDone, .vibeDone, .focus: false
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
        case .claudeWaiting(let session, let wants, _):
            // Which session, and what it wants when it says. Nothing in the
            // bars' place: the text has the room.
            ActivityLook(symbol: "hand.raised.fill", tint: ActivityLook.amber,
                         title: L.t("Claude Code is waiting", "Claude Code čeká"),
                         detail: session + (wants.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""),
                         trailing: "")
        case .claudeDone(let session, _):
            ActivityLook(symbol: "checkmark.circle.fill", tint: ActivityLook.green,
                         title: L.t("Claude Code has finished", "Claude Code dokončil"), detail: session,
                         trailing: "")
        case .vibeWaiting(let session, let wants, _):
            // The same two messages for Vibe: which session, and the
            // command it asks to run.
            ActivityLook(symbol: "hand.raised.fill", tint: ActivityLook.amber,
                         title: L.t("Vibe is waiting", "Vibe čeká"),
                         detail: session + (wants.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""),
                         trailing: "")
        case .vibeDone(let session, _):
            ActivityLook(symbol: "checkmark.circle.fill", tint: ActivityLook.green,
                         title: L.t("Vibe has finished", "Vibe dokončil"), detail: session,
                         trailing: "")
        case .sessionsWaiting(let count, let session, let wants, _, _):
            ActivityLook(symbol: "hand.raised.fill", tint: ActivityLook.amber,
                         title: Self.waitingTitle(count),
                         detail: session + (wants.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""),
                         trailing: "")
        case .fileArrived(let file):
            ActivityLook(symbol: file.kind == .screenshot ? "camera.viewfinder" : "arrow.down.circle.fill",
                         tint: ActivityLook.green, title: file.title, detail: file.detail, trailing: "")
        case .githubPush(let who, let repo, let message, _):
            // "Push from", not "X pushed": Czech would need to know whether
            // X is a he or a she.
            ActivityLook(symbol: "arrow.triangle.branch", tint: ActivityLook.sky,
                         title: L.t("Push from \(who)", "Push od \(who)"),
                         detail: message.isEmpty ? repo : "\(repo) · \(message)",
                         trailing: "", plate: .solid)
        case .githubChecksFailed(let repo, let detail, _):
            // A cross in a ring, where a push is a filled disc: told apart
            // by shape, not by red against blue alone.
            ActivityLook(symbol: "xmark.circle", tint: ActivityLook.coral,
                         title: L.t("Checks failed", "Testy selhaly"),
                         detail: detail.isEmpty ? repo : "\(repo) · \(detail)", trailing: "")
        case .githubRelease(let repo, let tag, _):
            ActivityLook(symbol: "tag.fill", tint: ActivityLook.sky,
                         title: L.t("New release", "Nový release"), detail: "\(repo) · \(tag)",
                         trailing: "", plate: .solid)
        case .focus(let on):
            ActivityLook(symbol: on ? "moon.fill" : "moon", tint: ActivityLook.violet,
                         title: on ? L.t("Focus is on", "Soustředění zapnuto")
                                   : L.t("Focus is off", "Soustředění vypnuto"),
                         detail: on ? L.t("Notifications are silenced", "Oznámení jsou ztišená")
                                    : L.t("Notifications are back", "Oznámení zase chodí"),
                         trailing: "", plate: .soft)
        }
    }

    /// A "waiting" message as it should be said given every session there
    /// is: itself while it is the only one waiting, and otherwise one for
    /// all of them — how many, and the one that has waited longest.
    /// Anything that isn't a "waiting" message comes back as it is.
    nonisolated func forAllWaiting(claude: ClaudeStatus?, vibe: VibeStatus?) -> NotchActivity {
        guard waitingRing != nil else { return self }
        let waiting = ((claude?.sessions ?? []) + (vibe?.sessions ?? [])).filter { $0.state == .waiting }.count
        guard waiting >= 2, let first = ClaudeUsagePage.longestWaiting(claude: claude, vibe: vibe) else {
            return self
        }
        return .sessionsWaiting(count: waiting, session: first.session.name, wants: first.session.wants,
                                pid: first.session.pid, vibe: first.isVibe)
    }

    /// "2 sessions are waiting" — Czech counts 2 to 4 one way and 5 up another.
    nonisolated static func waitingTitle(_ count: Int) -> String {
        L.t("\(count) sessions are waiting",
            (2...4).contains(count) ? "\(count) relace čekají" : "\(count) relací čeká")
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
    /// What the symbol stands on — see `Plate`.
    var plate: Plate = .none

    /// A disc under the symbol: none, as most have; the tint itself with the
    /// symbol dark on it; or a quarter of the tint with the symbol in it.
    enum Plate: Equatable { case none, solid, soft }

    /// GitHub's blue, lighter than `blue`: it carries a dark symbol.
    static let sky = Color(red: 0.5, green: 0.7, blue: 1)
    static let coral = Color(red: 1, green: 0.54, blue: 0.5)
    static let violet = Color(red: 0.73, green: 0.66, blue: 1)
    static let green = Color(red: 0.2, green: 0.84, blue: 0.4)
    static let red = Color(red: 1, green: 0.32, blue: 0.3)
    static let blue = Color(red: 0.36, green: 0.62, blue: 1)
    static let orange = Color(red: 1, green: 0.62, blue: 0.25)
    static let amber = Color(red: 0.96, green: 0.65, blue: 0.14)
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
        held = 0
        hideAfter(activity.duration)
    }

    /// Slides the message back in now — it was clicked, or dragged away.
    func dismiss() {
        guard model.activityShown else { return }
        hide?.cancel()
        slideBack()
    }

    private func hideAfter(_ delay: TimeInterval) {
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.timeUp() }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// How long a file has been kept out past its time, in seconds.
    private var held: TimeInterval = 0
    /// At most this long: a pointer parked on the notch isn't reaching for it.
    nonisolated static let longestHold: TimeInterval = 20

    /// Whether a message whose time is up stays out a second longer: a file,
    /// with the pointer on it — on its way to click or drag it.
    nonisolated static func holds(file: Bool, pointerOnNotch: Bool, heldFor: TimeInterval) -> Bool {
        file && pointerOnNotch && heldFor < longestHold
    }

    private func timeUp() {
        if Self.holds(file: model.activity?.file != nil, pointerOnNotch: model.pointerOnNotch,
                      heldFor: held) {
            held += 1
            hideAfter(1)
            return
        }
        slideBack()
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
