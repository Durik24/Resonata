import AppKit
import Combine
import SwiftUI

// Claude Code in the notch: how much of its limit is used, and whether a
// session is working or waiting for you.
//
// The idea is Codenotch's (github.com/vinzdg/codenotch, MIT), which does this
// for twenty tools along a screen edge; this is Claude Code only, written
// from scratch for the notch. Both things are read from Claude Code itself,
// on this Mac:
//   - each running session keeps a small file in `~/.claude/sessions/` with
//     its state — busy, waiting, idle;
//   - `claude /usage` prints the limits, the same text you get by typing
//     /usage in a session.
// No token, keychain item or account is touched, and it is off until it is
// switched on in Settings.

/// What the notch shows of Claude Code.
struct ClaudeStatus: Equatable {
    enum State: Equatable { case idle, working, waiting }

    var state: State = .idle
    /// The session that is working or waiting, by name.
    var session: String?
    /// What a waiting session wants, when it says.
    var wants: String?
    /// The limits, once `/usage` has answered.
    var usage: ClaudeUsage?
    /// Every running session, for the usage page.
    var sessions: [Session] = []

    /// One running Claude Code, as the usage page lists it.
    struct Session: Equatable, Identifiable {
        var pid: Int32
        var name: String
        var state: State
        /// The app it runs in — "Terminál", "Visual Studio Code" — when found.
        var app: String?
        /// The tool's own id for the session, where one process can hold
        /// several — Vibe's; Claude Code's are told apart by their pid.
        var key: String?
        var id: String { key ?? String(pid) }
    }

    /// A session is working or waiting.
    var isActive: Bool { state != .idle }

    /// There is something for the closed notch: a session at work, or
    /// limits to show while nothing is playing.
    var showsInPill: Bool { isActive || usage != nil }

    /// How full the week's ring is, 0...1; nil when the week isn't known.
    var weekFraction: Double? {
        usage?.weekPercent.map { min(max(Double($0) / 100, 0), 1) }
    }

    /// The app the session in question runs in.
    var app: String? {
        sessions.first { $0.state == state && $0.name == session }?.app
    }

    /// How full the ring is, 0...1; nil until the limits are known.
    var fraction: Double? {
        usage.map { min(max(Double($0.sessionPercent) / 100, 0), 1) }
    }

    /// The tooltip on the ring in the open panel, a line per fact.
    func summary(now: Date) -> String {
        var lines: [String] = []
        switch state {
        case .working: lines.append(L.t("Claude · working", "Claude · pracuje"))
        case .waiting: lines.append(L.t("Claude · waiting for you", "Claude · čeká na tebe"))
        case .idle: lines.append("Claude")
        }
        if let usage {
            lines.append(L.t("Session: \(usage.sessionPercent) % used", "Relace: využito \(usage.sessionPercent) %")
                         + (usage.sessionResets.map { " · " + Self.countdown(to: $0, now: now) } ?? ""))
            if let week = usage.weekPercent {
                lines.append(L.t("Week: \(week) %", "Týden: \(week) %")
                             + (usage.weekResets.map { " · " + Self.day($0) } ?? ""))
            }
        } else {
            lines.append(L.t("Limits not read yet", "Limity zatím nenačtené"))
        }
        // Which session, and where: "resonata · Terminál".
        if let session { lines.append(session + (app.map { " · \($0)" } ?? "")) }
        return lines.joined(separator: "\n")
    }

    /// "resets in 2 h 18 min" ("reset za 2 h 18 min"); under a minute, "now".
    nonisolated static func countdown(to date: Date, now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return L.t("resets now", "reset teď") }
        let h = minutes / 60, m = minutes % 60
        let length = h > 0 ? (m > 0 ? "\(h) h \(m) min" : "\(h) h") : "\(m) min"
        return L.t("resets in \(length)", "reset za \(length)")
    }

    /// "resets Fri 18:59" ("reset pá 18:59").
    nonisolated static func day(_ date: Date) -> String {
        let when = date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(L.locale))
        return L.t("resets \(when)", "reset \(when)")
    }
}

/// The limits `claude /usage` prints.
struct ClaudeUsage: Equatable {
    /// The current session window — five hours — as a percentage used.
    var sessionPercent: Int
    var sessionResets: Date?
    /// The week, all models together.
    var weekPercent: Int?
    var weekResets: Date?
    /// The weeks counted for one model apiece — "Fable" — where the plan has them.
    var models: [ModelWeek] = []

    struct ModelWeek: Equatable {
        var name: String
        var percent: Int
        var resets: Date?
    }

    /// Reads the text of `/usage`:
    ///
    ///     Current session: 6% used · resets Nov 12 at 6:39pm (Europe/Prague)
    ///     Current week (all models): 1% used · resets Nov 13 at 6:59pm (Europe/Prague)
    ///
    /// Nil when there is no session line — a signed-out CLI, an API-key
    /// account with no limits, or wording this doesn't know.
    nonisolated static func parse(_ text: String, now: Date = Date()) -> ClaudeUsage? {
        var session: (percent: Int, resets: Date?)?
        var week: (percent: Int, resets: Date?)?
        var models: [ModelWeek] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Current session") {
                session = window(in: line, now: now) ?? session
            } else if line.hasPrefix("Current week"), let read = window(in: line, now: now) {
                // "Current week (Fable): …" is one model's; the name is in
                // the brackets. Any other week line is everything together.
                if !line.contains("all models"), let open = line.firstIndex(of: "("),
                   let close = line.firstIndex(of: ")"), open < close {
                    models.append(ModelWeek(name: String(line[line.index(after: open)..<close]),
                                            percent: read.percent, resets: read.resets))
                } else {
                    week = read
                }
            }
        }
        guard let session else { return nil }
        // Only a model's own week said: that is the week, then.
        if week == nil, let only = models.first {
            week = (only.percent, only.resets)
            models.removeFirst()
        }
        return ClaudeUsage(sessionPercent: session.percent, sessionResets: session.resets,
                           weekPercent: week?.percent, weekResets: week?.resets, models: models)
    }

    /// "…: 6% used · resets Nov 12 at 6:39pm (Europe/Prague)" → 6 and the date.
    private nonisolated static func window(in line: String, now: Date) -> (percent: Int, resets: Date?)? {
        guard let sign = line.range(of: "%"),
              line[sign.upperBound...].trimmingCharacters(in: .whitespaces).hasPrefix("used") else { return nil }
        let before = line[..<sign.lowerBound].trimmingCharacters(in: .whitespaces)
        let digits = String(before.reversed().prefix(while: \.isNumber).reversed())
        guard let percent = Int(digits) else { return nil }
        let resets = line.range(of: "resets ").flatMap { resetDate(String(line[$0.upperBound...]), now: now) }
        return (percent, resets)
    }

    /// "Nov 12 at 6:39pm (Europe/Prague)", or just "6:39pm" for later today.
    /// The year is never said: it is the next such moment from `now`.
    nonisolated static func resetDate(_ text: String, now: Date) -> Date? {
        var text = text.trimmingCharacters(in: .whitespaces)
        var zone = TimeZone.current
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let name = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            if let named = TimeZone(identifier: name) { zone = named }
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        // "6:39pm" → "6:39 PM", which is what the formatter reads.
        let lower = text.lowercased()
        for (suffix, mark) in [("am", " AM"), ("pm", " PM")] where lower.hasSuffix(suffix) {
            text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces) + mark
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = zone
        // The parts the text leaves out — the year, or the whole date — are
        // taken from now.
        formatter.defaultDate = now
        let formats: [(String, Calendar.Component)] = [
            ("MMM d 'at' h:mm a", .year), ("MMM d 'at' h a", .year), ("MMM d 'at' HH:mm", .year),
            ("h:mm a", .day), ("h a", .day), ("HH:mm", .day),
        ]
        for (format, missing) in formats {
            formatter.dateFormat = format
            guard let read = formatter.date(from: text) else { continue }
            // The default date fills in the seconds too, and the minutes of
            // "6pm" — with those of the moment it was read. On the minute,
            // or on the hour.
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: read)
            if !format.contains("mm") { parts.minute = 0 }
            guard let date = calendar.date(from: parts) else { continue }
            // Already past: it means the next one — tomorrow for a bare
            // time, next year for a date read in the last days of December.
            // A minute's grace, for a reset that is happening as it's read.
            if date < now.addingTimeInterval(missing == .day ? -60 : -43_200) {
                return calendar.date(byAdding: missing, value: 1, to: date)
            }
            return date
        }
        return nil
    }
}

/// One file in `~/.claude/sessions/`: a running Claude Code and its state.
struct ClaudeSessionRecord: Equatable {
    var pid: Int32
    var name: String
    var state: ClaudeStatus.State
    var wants: String?
    var cwd: String
    /// A run something else started to ask a question and leave — `claude
    /// --print`, which is how the limits are read here too. Not a session
    /// anyone is waiting on.
    var isHelper: Bool

    init?(json: [String: Any]) {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value,
              let cwd = json["cwd"] as? String else { return nil }
        self.pid = pid
        self.cwd = cwd
        // Two spellings of the same thing, depending on the version: `tempo`
        // where it is written, else `status`.
        switch (json["tempo"] as? String, json["status"] as? String) {
        case ("blocked", _), (_, "waiting"): state = .waiting
        case ("active", _), (_, "busy"): state = .working
        default: state = .idle
        }
        wants = (json["waitingFor"] as? String) ?? (json["needs"] as? String)
        // A name Claude Code made up from the folder ("josefkupec-16") says
        // less than the folder itself; one the user gave is kept.
        let folder = (cwd as NSString).lastPathComponent
        let given = (json["nameSource"] as? String).map { $0 != "derived" } ?? false
        name = given ? ((json["name"] as? String) ?? folder) : folder
        isHelper = (json["entrypoint"] as? String)?.hasPrefix("sdk-") == true
    }

    /// The state the notch shows for all the sessions together, and which
    /// one it is about: one waiting for you comes before one still working.
    nonisolated static func summary(of records: [ClaudeSessionRecord])
        -> (state: ClaudeStatus.State, session: String?, wants: String?) {
        if let waiting = records.first(where: { $0.state == .waiting }) {
            return (.waiting, waiting.name, waiting.wants)
        }
        if let working = records.first(where: { $0.state == .working }) {
            return (.working, working.name, nil)
        }
        return (.idle, nil, nil)
    }

    /// What is worth saying when a session goes from `old` to `new`: it has
    /// stopped to ask something, or it has finished. Only leaving work
    /// counts — an answered question going back to work isn't news — and a
    /// piece of work shorter than `minimumWork` ends without a word, or
    /// every one-line answer would slide out of the notch.
    nonisolated static func event(from old: ClaudeStatus.State?, to new: ClaudeSessionRecord,
                                  workedFor: TimeInterval) -> NotchActivity? {
        guard old == .working else { return nil }
        switch new.state {
        case .waiting: return .claudeWaiting(session: new.name, wants: new.wants, pid: new.pid)
        case .idle: return workedFor >= minimumWork ? .claudeDone(session: new.name, pid: new.pid) : nil
        case .working: return nil
        }
    }

    nonisolated static let minimumWork: TimeInterval = 10
}

/// Watches Claude Code's sessions and asks it for its limits.
@MainActor
final class ClaudeMonitor: ObservableObject {

    /// Nil while switched off, or with no Claude Code on this Mac.
    @Published private(set) var status: ClaudeStatus?

    /// A session has stopped to ask something, or has finished.
    var onEvent: ((NotchActivity) -> Void)?

    private var timer: Timer?
    /// Each session's state at the last look, and since when it has worked.
    private var known: [Int32: (state: ClaudeStatus.State, workingSince: Date?)] = [:]
    private var usage: ClaudeUsage?
    /// The app each session runs in, by the session's pid.
    private var apps: [Int32: String] = [:]
    private var lastAsked: Date?
    private var asking = false

    private nonisolated static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private nonisolated static var sessionsDirectory: URL {
        home.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// Where `claude /usage` is run from: a folder of its own, so the run
    /// never shows up as a session in a project of yours.
    private nonisolated static var scratch: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resonata/claude-usage", isDirectory: true)
    }

    /// How often the limits are asked for: they only move while something
    /// is working. Each asking starts `claude`, about a second and a half.
    private static let busyInterval: TimeInterval = 120
    private static let quietInterval: TimeInterval = 900

    func setEnabled(_ enabled: Bool) {
        if enabled, timer == nil {
            guard FileManager.default.fileExists(atPath: Self.home.appendingPathComponent(".claude").path)
            else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.look() }
            }
            timer.tolerance = 0.3
            self.timer = timer
            look()
        } else if !enabled, timer != nil {
            timer?.invalidate()
            timer = nil
            known = [:]
            status = nil
        }
    }

    /// Reads the session files — a handful of a few hundred bytes each.
    private func look() {
        let records = Self.liveSessions()
        let now = Date()
        var events: [NotchActivity] = []
        var seen: [Int32: (state: ClaudeStatus.State, workingSince: Date?)] = [:]
        var finished = false
        for record in records {
            let before = known[record.pid]
            let since = record.state == .working ? (before?.workingSince ?? now) : nil
            seen[record.pid] = (record.state, since)
            let worked = before?.workingSince.map { now.timeIntervalSince($0) } ?? 0
            if let event = ClaudeSessionRecord.event(from: before?.state, to: record, workedFor: worked) {
                events.append(event)
            }
            if before?.state == .working, record.state != .working { finished = true }
        }
        known = seen

        let summary = ClaudeSessionRecord.summary(of: records)
        apps = apps.filter { seen[$0.key] != nil }
        let sessions = records.map { record -> ClaudeStatus.Session in
            // Looked up once per session: it never moves to another app.
            let app = apps[record.pid] ?? Self.hostApp(of: record.pid)?.localizedName
            apps[record.pid] = app
            return ClaudeStatus.Session(pid: record.pid, name: record.name, state: record.state, app: app)
        }
        let new = ClaudeStatus(state: summary.state, session: summary.session, wants: summary.wants,
                               usage: usage, sessions: sessions)
        if status != new { status = new }

        // One at a time: a session waiting for you is said before one that
        // has merely finished.
        if let event = events.first(where: { if case .claudeWaiting = $0 { true } else { false } })
            ?? events.first {
            onEvent?(event)
        }

        // The limits: just after a piece of work ends, when the window they
        // were read for has rolled over, and otherwise now and then.
        let rolledOver = usage?.sessionResets.map { $0 < now } ?? false
        let interval = finished || rolledOver ? 20 : (new.isActive ? Self.busyInterval : Self.quietInterval)
        refreshUsage(ifOlderThan: interval)
    }

    /// Asks `claude /usage`, unless it was asked less than `age` ago.
    func refreshUsage(ifOlderThan age: TimeInterval = 0) {
        guard timer != nil, !asking else { return }
        if let lastAsked, Date().timeIntervalSince(lastAsked) < age { return }
        guard let binary = Self.locateCLI() else { return }
        asking = true
        lastAsked = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let text = Self.run(binary)
            let parsed = text.flatMap { ClaudeUsage.parse($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.asking = false
                    // A failed asking keeps the last answer rather than
                    // emptying the ring.
                    guard let parsed, self.timer != nil else { return }
                    self.usage = parsed
                    if var status = self.status, status.usage != parsed {
                        status.usage = parsed
                        self.status = status
                    }
                }
            }
        }
    }

    /// The sessions whose process is still there. A session that was killed
    /// leaves its file behind, still saying "busy".
    private nonisolated static func liveSessions() -> [ClaudeSessionRecord] {
        let directory = sessionsDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let ours = scratch.resolvingSymlinksInPath().path
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let record = ClaudeSessionRecord(json: json),
                  !record.isHelper,
                  URL(fileURLWithPath: record.cwd).resolvingSymlinksInPath().path != ours,
                  kill(record.pid, 0) == 0 || errno == EPERM
            else { return nil }
            return record
        }
    }

    /// The app a session runs in: the first ordinary app up the process
    /// tree from it — the terminal, the editor, Claude's own desktop app. A
    /// session says its pid and nothing about its window, so this is as
    /// near as "where is it" gets; which tab is the terminal's to know.
    nonisolated static func hostApp(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let parent = info.kp_eproc.e_ppid
            guard parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// Where `claude` is installed, trying the usual places: an app started
    /// from the Finder has no shell `PATH` to look along.
    nonisolated static func locateCLI() -> URL? {
        let inHome = [".local/bin/claude", ".claude/local/claude", ".bun/bin/claude", ".volta/bin/claude",
                      "Library/pnpm/claude", ".npm-global/bin/claude"].map { home.appendingPathComponent($0) }
        let system = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].map { URL(fileURLWithPath: $0) }
        return (inHome + system).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs `claude /usage` and hands back what it printed; nil if it
    /// couldn't be run or took longer than twenty seconds.
    private nonisolated static func run(_ binary: URL) -> String? {
        let folder = scratch
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = binary
        // Print and leave: no transcript kept, none of your MCP servers started.
        process.arguments = ["--print", "--no-session-persistence", "--strict-mcp-config", "/usage"]
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PWD"] = folder.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch {
            NSLog("Resonata: could not run claude /usage: \(error)")
            return nil
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)
    }
}

/// The ring: how much of the limit is used, with a small arc turning inside
/// it while a session works, or the whole ring pulsing amber while one waits.
///
/// Core Animation layers, like the bars: the turning and the pulsing are
/// animations the window server runs by itself, so a ring that spins for an
/// hour costs the app nothing. A SwiftUI animation would redraw the view
/// thirty times a second for it.
struct ClaudeRing: NSViewRepresentable {
    var fraction: Double?
    var state: ClaudeStatus.State = .idle
    var lineWidth: CGFloat = 2.5
    /// The percentage written in the middle — where the ring is big enough
    /// to read it, and nothing is turning there.
    var showsNumber = false
    var tint = ClaudeRingView.tint

    func makeNSView(context: Context) -> ClaudeRingView { ClaudeRingView() }

    func updateNSView(_ view: ClaudeRingView, context: Context) {
        let number = showsNumber && state != .working ? fraction.map { "\(Int(($0 * 100).rounded()))" } : nil
        view.show(fraction: fraction, state: state, lineWidth: lineWidth, number: number, tint: tint)
    }
}

final class ClaudeRingView: NSView {
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let spinner = CAShapeLayer()
    private let text = CATextLayer()
    private var fraction: Double?
    private var state = ClaudeStatus.State.idle
    private var lineWidth: CGFloat = 2.5
    private var number: String?
    private var colour = ClaudeRingView.tint

    static let tint = NSColor(red: 0.91, green: 0.53, blue: 0.36, alpha: 1)
    static let amber = NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1)
    /// The week's ring, so it isn't taken for the session's.
    static let blue = NSColor(red: 0.5, green: 0.7, blue: 1, alpha: 1)
    static let violet = NSColor(red: 0.73, green: 0.66, blue: 1, alpha: 1)
    /// Mistral's orange, for Vibe's ring: redder than Claude Code's.
    static let vibe = NSColor(red: 0.98, green: 0.31, blue: 0.06, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [track, progress, spinner] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        spinner.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        text.alignmentMode = .center
        text.foregroundColor = NSColor.white.cgColor
        layer?.addSublayer(text)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks go to whatever the ring is drawn on — the button, in the panel.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(fraction: Double?, state: ClaudeStatus.State, lineWidth: CGFloat, number: String?,
              tint: NSColor) {
        guard fraction != self.fraction || state != self.state || lineWidth != self.lineWidth
                || number != self.number || tint != colour else { return }
        self.fraction = fraction
        self.state = state
        self.lineWidth = lineWidth
        self.number = number
        colour = tint
        redraw()
    }

    override func layout() {
        super.layout()
        redraw()
    }

    /// A window that leaves the screen takes its animations with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        redraw()
    }

    private func redraw() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        // From twelve o'clock, clockwise.
        func circle(radius: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.addArc(center: centre, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi,
                        clockwise: true)
            return path
        }
        let radius = (side - lineWidth) / 2
        for shape in [track, progress] {
            shape.frame = bounds
            shape.path = circle(radius: radius)
            shape.lineWidth = lineWidth
        }
        spinner.frame = bounds
        spinner.path = circle(radius: max(radius - lineWidth - 1.5, 1))
        spinner.lineWidth = max(lineWidth * 0.6, 1)
        spinner.strokeEnd = 0.28

        // The number, in the middle: three digits still fit inside the ring.
        text.isHidden = number == nil
        if let number {
            let size = (side - 2 * lineWidth) * (number.count > 2 ? 0.44 : 0.56)
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            text.font = font
            text.fontSize = size
            text.string = number
            text.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let height = (font.ascender - font.descender).rounded(.up)
            // A text layer draws from its top; this puts the digits' middle
            // on the ring's.
            text.frame = CGRect(x: 0, y: centre.y - height / 2 + (font.descender + font.ascender - font.capHeight) / 2,
                                width: bounds.width, height: height)
        }

        progress.removeAnimation(forKey: "pulse")
        spinner.removeAnimation(forKey: "turn")
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch state {
        case .waiting:
            // The whole ring, amber: it wants you, however full it is.
            progress.strokeColor = Self.amber.cgColor
            progress.strokeEnd = 1
            spinner.isHidden = true
            if !still {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.35
                pulse.duration = 0.7
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.isRemovedOnCompletion = false
                progress.add(pulse, forKey: "pulse")
            }
        case .working, .idle:
            progress.strokeColor = colour.cgColor
            progress.strokeEnd = CGFloat(fraction ?? 0)
            spinner.isHidden = state != .working
            if state == .working, !still {
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = 0
                turn.toValue = -2 * Double.pi
                turn.duration = 1.1
                turn.repeatCount = .infinity
                turn.isRemovedOnCompletion = false
                spinner.add(turn, forKey: "turn")
            }
        }
        CATransaction.commit()
    }
}

/// The open panel's usage page: the session limit, the week, and what each
/// running session is doing — three cards side by side.
struct ClaudeUsagePage: View {
    var status: ClaudeStatus?
    /// Mistral Vibe's, when that is switched on — see `VibeMonitor`.
    var vibe: VibeStatus?
    /// The panel at its full width: room for a fourth card.
    var wide = false

    static let orange = Color(nsColor: ClaudeRingView.tint)
    static let blue = Color(nsColor: ClaudeRingView.blue)
    static let violet = Color(nsColor: ClaudeRingView.violet)
    static let amber = Color(nsColor: ClaudeRingView.amber)
    static let vibe = Color(nsColor: ClaudeRingView.vibe)
    static let quiet = Color.white.opacity(0.62)

    var body: some View {
        if status != nil || vibe != nil {
            // The countdown is against the clock, so it stays right between
            // readings; twice a minute is as often as its minutes change.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 8) {
                    if let status {
                        sessionCard(status, now: context.date)
                        // Three cards fit the narrow panel. With Vibe's
                        // among them the week gives up its own: it keeps
                        // its line at the foot of the session's.
                        if vibe == nil || wide { weekCard(status) }
                    }
                    if let vibe { vibeCard(vibe) }
                    sessionsCard(Self.rows(claude: status, vibe: vibe))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(L.t("Switch on Claude Code or Mistral Vibe in Settings",
                     "Zapni Claude Code nebo Mistral Vibe v Nastavení"))
                .font(.system(size: 11))
                .foregroundStyle(Self.quiet)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The five-hour window: the ring the closed notch shows.
    private func sessionCard(_ status: ClaudeStatus, now: Date) -> some View {
        let usage = status.usage
        return card {
            header(mark: "C", tint: Self.orange, title: "Claude") {
                switch status.state {
                case .working: chip(L.t("Working", "Pracuje"), tint: .white)
                case .waiting: chip(L.t("Waiting", "Čeká"), tint: Self.amber)
                case .idle: chip(L.t("Idle", "Volno"), tint: Self.quiet)
                }
            }
            reading(ring: ClaudeRing(fraction: status.fraction, state: status.state, lineWidth: 4.5),
                    label: L.t("Session · 5 h", "Relace · 5 h"),
                    percent: usage?.sessionPercent,
                    detail: usage?.sessionResets.map { ClaudeStatus.countdown(to: $0, now: now) })
            Spacer(minLength: 0)
            if let week = usage?.weekPercent {
                foot(label: L.t("Week", "Týden"), value: "\(week) %", fraction: Double(week) / 100, tint: Self.orange)
            }
        }
    }

    /// The week, all models together, and one model's under it.
    private func weekCard(_ status: ClaudeStatus) -> some View {
        let usage = status.usage
        return card {
            header(mark: "7", tint: Self.blue, title: L.t("Week", "Týden")) { EmptyView() }
            reading(ring: ClaudeRing(fraction: status.weekFraction, lineWidth: 4.5, tint: ClaudeRingView.blue),
                    label: L.t("All models", "Všechny modely"),
                    percent: usage?.weekPercent,
                    detail: usage?.weekResets.map { ClaudeStatus.day($0) })
            Spacer(minLength: 0)
            if let model = usage?.models.first {
                foot(label: model.name, value: "\(model.percent) %", fraction: Double(model.percent) / 100,
                     tint: Self.violet)
            }
        }
    }

    /// A line of the sessions card: a session, and whose it is.
    struct Row: Identifiable, Equatable {
        var id: String
        var session: ClaudeStatus.Session
        var isVibe = false
        /// "Claude" or "Vibe", said only while both are switched on.
        var tool: String?
    }

    /// Both tools' sessions in one list. The ones at work or waiting come
    /// first: the card has room for four.
    nonisolated static func rows(claude: ClaudeStatus?, vibe: VibeStatus?) -> [Row] {
        let both = claude != nil && vibe != nil
        let all = (claude?.sessions ?? []).map { Row(id: "c" + $0.id, session: $0, tool: both ? "Claude" : nil) }
            + (vibe?.sessions ?? []).map { Row(id: "v" + $0.id, session: $0, isVibe: true, tool: both ? "Vibe" : nil) }
        func rank(_ row: Row) -> Int {
            switch row.session.state {
            case .waiting: 0
            case .working: 1
            case .idle: 2
            }
        }
        return all.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Every running session and what it is doing.
    private func sessionsCard(_ rows: [Row]) -> some View {
        card {
            header(mark: "\(rows.count)", tint: Self.violet, title: L.t("Sessions", "Relace")) { EmptyView() }
            if rows.isEmpty {
                Text(L.t("None running", "Žádná neběží"))
                    .font(.system(size: 9))
                    .foregroundStyle(Self.quiet)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows.prefix(4)) { row in
                        let session = row.session
                        HStack(spacing: 6) {
                            Circle()
                                .fill(session.state == .working ? (row.isVibe ? Self.vibe : Self.orange)
                                      : session.state == .waiting ? Self.amber : Color.white.opacity(0.3))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(session.name)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(Self.doing(row))
                                    .font(.system(size: 8))
                                    .foregroundStyle(Self.quiet)
                            }
                            .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// "working · Terminál", "waiting for you", "idle" — "Vibe · working ·
    /// Terminál" where the tool has to be said.
    nonisolated static func doing(_ row: Row) -> String {
        let state = switch row.session.state {
        case .working: L.t("working", "pracuje")
        case .waiting: L.t("waiting for you", "čeká na tebe")
        case .idle: L.t("idle", "volno")
        }
        return (row.tool.map { "\($0) · " } ?? "") + state + (row.session.app.map { " · \($0)" } ?? "")
    }

    // MARK: The pieces of a card

    func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
    }

    func header(mark: String, tint: Color, title: String,
                        @ViewBuilder chip: () -> some View) -> some View {
        HStack(spacing: 5) {
            Text(mark)
                .font(.system(size: 8.5, weight: .heavy))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 15, height: 15)
                .background(Circle().fill(tint))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 2)
            chip()
        }
    }

    func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 7.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.white.opacity(0.12)))
            .fixedSize()
    }

    /// The ring with its figures beside it.
    func reading(ring: ClaudeRing, label: String, percent: Int?, detail: String?) -> some View {
        HStack(spacing: 8) {
            ring
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 7.5))
                    .foregroundStyle(Self.quiet)
                Text(percent.map { "\($0) %" } ?? "–")
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(detail ?? " ")
                    .font(.system(size: 7.5))
                    .foregroundStyle(Self.quiet)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    /// A line and a thin bar along the card's foot.
    func foot(label: String, value: String, fraction: Double, tint: Color) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                Spacer(minLength: 2)
                Text(value)
            }
            .font(.system(size: 7.5))
            .foregroundStyle(Self.quiet)
            .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(tint)
                        .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the rings in the top bar say when the pointer rests on them: the
/// state, the limits, and which session — a block of lines for each tool.
struct ClaudeHoverCard: View {
    var sections: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, lines in
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: index == 0 ? 9.5 : 8.5, weight: index == 0 ? .bold : .regular))
                            .foregroundStyle(index == 0 ? Color.white
                                             : Color.white.opacity(index == lines.count - 1 ? 0.62 : 0.85))
                    }
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.11)))
        .shadow(color: .black.opacity(0.55), radius: 8, y: 4)
        .fixedSize()
        .allowsHitTesting(false)
    }
}
