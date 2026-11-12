import AppKit
import Combine
import SwiftUI

// Mistral Vibe in the notch, beside Claude Code: how much of its allowance
// is used, and whether a session is working or waiting for you.
//
// Vibe has one limit where Claude Code has two: the month's Vibe allowance.
// Both things are read from Vibe itself, on this Mac:
//   - a running session holds a lease in `~/.vibe/logs/session/active/`, and
//     writes what it does to its journal under `…/unified/<session>/` — a
//     turn started, an approval asked for, an approval answered;
//   - the allowance is what Vibe shows in its own status bar. It is asked for
//     the way Vibe asks: by Vibe's Python, with the sign-in Vibe keeps.
// Resonata never sees the key, and it is off until switched on in Settings.

/// What the notch shows of Mistral Vibe.
struct VibeStatus: Equatable {
    var state: ClaudeStatus.State = .idle
    /// The session that is working or waiting, by name.
    var session: String?
    /// What a waiting session wants: the command it asks to run.
    var wants: String?
    /// The allowance, once Mistral has answered.
    var usage: VibeUsage?
    /// Every running session, for the usage page.
    var sessions: [ClaudeStatus.Session] = []

    /// A session is working or waiting.
    var isActive: Bool { state != .idle }

    /// There is something for the closed notch: a session at work, or the
    /// allowance to show while nothing is playing.
    var showsInPill: Bool { isActive || usage != nil }

    /// How full the ring is, 0...1; nil until the allowance is known.
    var fraction: Double? {
        usage.map { min(max(Double($0.percent) / 100, 0), 1) }
    }

    /// The app the session in question runs in.
    var app: String? {
        sessions.first { $0.state == state && $0.name == session }?.app
    }

    /// The hover card on the ring in the open panel, a line per fact.
    func summary(now: Date) -> String {
        var lines: [String] = []
        switch state {
        case .working: lines.append(L.t("Vibe · working", "Vibe · pracuje"))
        case .waiting: lines.append(L.t("Vibe · waiting for you", "Vibe · čeká na tebe"))
        case .idle: lines.append("Vibe")
        }
        if let usage {
            lines.append(L.t("Month: \(usage.percent) % used", "Měsíc: využito \(usage.percent) %")
                         + (usage.resets.map { " · " + Self.day($0) } ?? ""))
            if let plan = usage.plan {
                lines.append(L.t("Plan: \(plan)", "Tarif: \(plan)")
                             + (usage.payAsYouGo ? L.t(" · billed past 100 %", " · nad 100 % se platí") : ""))
            }
        } else {
            lines.append(L.t("Allowance not read yet", "Limit zatím nenačtený"))
        }
        if let session { lines.append(session + (app.map { " · \($0)" } ?? "")) }
        return lines.joined(separator: "\n")
    }

    /// "resets 1 Dec" ("reset 1. 12.").
    nonisolated static func day(_ date: Date) -> String {
        let when = date.formatted(.dateTime.day().month(.abbreviated).locale(L.locale))
        return L.t("resets \(when)", "reset \(when)")
    }
}

/// The month's Vibe allowance, as Mistral's billing reports it.
struct VibeUsage: Equatable {
    /// How much of the month's allowance is used, as a percentage. Past 100
    /// where the plan bills the rest instead of stopping.
    var percent: Int
    var resets: Date?
    /// The plan by the name Vibe gives it: "Student", "Pro".
    var plan: String?
    /// Use past the allowance is billed, not paused.
    var payAsYouGo = false

    /// Reads the line the helper prints — see `VibeMonitor.helper`:
    ///
    ///     {"percent": 2.97, "resets": "2026-12-01T00:00:00Z", "plan": "EDU", "payg": false}
    ///
    /// Nil when there is no such line: a signed-out Vibe, a plan with no
    /// allowance, a platform that doesn't say.
    nonisolated static func parse(_ text: String) -> VibeUsage? {
        // The last line that is an object: anything a library chose to
        // print on the way comes before it.
        for raw in text.split(whereSeparator: \.isNewline).reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{"),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let percent = (json["percent"] as? NSNumber)?.doubleValue, percent.isFinite
            else { continue }
            // Whole per cents, the part over dropped: that is how Vibe's
            // own status bar says it, and 2.99 read "3 %" here beside its "2 %".
            return VibeUsage(percent: Int(max(percent, 0).rounded(.down)),
                             resets: (json["resets"] as? String).flatMap(date),
                             plan: planTitle(json["plan"] as? String),
                             payAsYouGo: (json["payg"] as? Bool) ?? false)
        }
        return nil
    }

    /// "2026-12-01T00:00:00Z", with or without fractions of a second.
    private nonisolated static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// Billing's name for the plan, as Vibe's own account view words it.
    nonisolated static func planTitle(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return ["FREE": "Free", "INDIVIDUAL": "Pro", "EDU": "Student", "TEAM": "Team"][name.uppercased()] ?? name
    }
}

/// What a session's journal says it is doing.
///
/// The journal is a line of JSON per step, and three kinds matter here:
///   - `projection_delta` with a `set_envelope`: the session as Vibe shows
///     it, its status — running, idle — and its title;
///   - `callback_registered`: it has stopped to ask for an approval;
///   - `callback_resolved`: the approval was answered.
/// While it waits the status still says "running": a question registered and
/// not yet resolved is what waiting looks like.
struct VibeJournal: Equatable {
    struct Ask: Equatable {
        var id: String
        var wants: String?
    }

    private(set) var status: String?
    private(set) var title: String?
    /// Somebody named the session; Vibe's own titles are a guess at the task.
    private(set) var titleGiven = false
    /// Asked and not answered, oldest first.
    private(set) var asks: [Ask] = []

    var state: ClaudeStatus.State {
        if !asks.isEmpty || status == "blocked" { return .waiting }
        return status == "running" ? .working : .idle
    }

    /// What the oldest open question asks for.
    var wants: String? { asks.first?.wants }

    /// A new journal file: Vibe starts one each time the session comes to
    /// rest, so whatever was going on is over. Its name stays.
    mutating func startOver() {
        status = nil
        asks = []
    }

    private static let callbackMark = Data("callback_re".utf8)
    private static let envelopeMark = Data("set_envelope".utf8)

    /// Takes in whole lines of the journal, in order. Only lines that can
    /// matter are parsed: a line carrying a tool's output runs to hundreds
    /// of kilobytes, and there is one envelope after every step.
    mutating func read(_ data: Data) {
        var envelopes: [(index: Int, line: Data)] = []
        var lastAsk = -1
        for (index, line) in data.split(separator: 0x0A).enumerated() {
            if line.range(of: Self.callbackMark) != nil, let record = Self.object(line),
               let type = record["type"] as? String, type.hasPrefix("callback_"),
               let payload = record["payload"] as? [String: Any],
               let id = payload["callback_id"] as? String {
                asks.removeAll { $0.id == id }
                if type == "callback_registered" {
                    asks.append(Ask(id: id, wants: Self.wants(payload)))
                    lastAsk = index
                }
            } else if line.range(of: Self.envelopeMark) != nil {
                envelopes.append((index, line))
            }
        }
        // The newest envelope is the one that counts. A line that merely
        // quotes the word — this file, read by a session — is passed over.
        for candidate in envelopes.reversed() {
            guard let record = Self.object(candidate.line),
                  record["type"] as? String == "projection_delta",
                  let deltas = (record["payload"] as? [String: Any])?["delta"] as? [Any],
                  let envelope = deltas.compactMap({ $0 as? [String: Any] })
                      .last(where: { $0["op"] as? String == "set_envelope" }),
                  let session = (envelope["state"] as? [String: Any])?["session"] as? [String: Any]
            else { continue }
            status = (session["status"] as? [String: Any])?["type"] as? String
            title = (session["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            titleGiven = title != nil && (session["titleSource"] as? String).map { $0 != "auto" } ?? false
            // At rest after the question was put: the turn was stopped, and
            // the question went with it.
            if status != "running", status != "blocked", candidate.index > lastAsk { asks = [] }
            break
        }
    }

    private static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// What an approval is for, short enough for the notch: the command, the
    /// file, or failing those the tool.
    nonisolated static func wants(_ payload: [String: Any]) -> String? {
        let routing = payload["routing"] as? [String: Any]
        let effect = (routing?["detail"] as? [String: Any])?["effect"] as? [String: Any]
        let input = effect?["input"] as? [String: Any]
        var text: String?
        if let command = input?["command"] as? String {
            text = command.split(whereSeparator: \.isNewline).first.map(String.init)
        } else if let path = (input?["path"] ?? input?["file_path"]) as? String {
            text = (path as NSString).lastPathComponent
        } else if let tool = effect?["toolName"] as? String {
            // "file_system.write_file" → "write_file"
            text = tool.split(separator: ".").last.map(String.init)
        } else if let title = routing?["title"] as? String {
            text = title
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
    }
}

/// A running Vibe session and its state.
struct VibeSessionRecord: Equatable {
    /// Vibe's own id for the session.
    var id: String
    /// The process that holds it open.
    var pid: Int32
    var name: String
    var state: ClaudeStatus.State
    var wants: String?

    /// The name the notch uses, as for Claude Code: the folder it runs in,
    /// unless somebody gave the session a name of its own.
    nonisolated static func name(title: String?, given: Bool, folder: String?) -> String {
        if given, let title { return title }
        if let folder, !folder.isEmpty { return (folder as NSString).lastPathComponent }
        return title ?? "Vibe"
    }

    /// The state the notch shows for all the sessions together, and which
    /// one it is about: one waiting for you comes before one still working.
    nonisolated static func summary(of records: [VibeSessionRecord])
        -> (state: ClaudeStatus.State, session: String?, wants: String?) {
        if let waiting = records.first(where: { $0.state == .waiting }) {
            return (.waiting, waiting.name, waiting.wants)
        }
        if let working = records.first(where: { $0.state == .working }) {
            return (.working, working.name, nil)
        }
        return (.idle, nil, nil)
    }

    /// What is worth saying when a session goes from `old` to `new` — the
    /// same rule as Claude Code's: it has stopped to ask, or it has finished
    /// a piece of work long enough to have looked away from.
    nonisolated static func event(from old: ClaudeStatus.State?, to new: VibeSessionRecord,
                                  workedFor: TimeInterval) -> NotchActivity? {
        guard old == .working else { return nil }
        switch new.state {
        case .waiting: return .vibeWaiting(session: new.name, wants: new.wants, pid: new.pid)
        case .idle:
            return workedFor >= ClaudeSessionRecord.minimumWork ? .vibeDone(session: new.name, pid: new.pid) : nil
        case .working: return nil
        }
    }
}

/// Reads Vibe's session files. Its journals grow to megabytes, so this is
/// kept off the main thread, on the monitor's queue and nowhere else, and
/// each journal is read once: after that, only what was added.
final class VibeSessionReader: @unchecked Sendable {

    private struct Tail {
        var file: String
        var offset: UInt64 = 0
        var journal = VibeJournal()
    }

    private struct Meta {
        var folder: String?
        /// A session another session started to do part of its work.
        var isChild: Bool
    }

    private var tails: [String: Tail] = [:]
    private var metas: [String: Meta] = [:]

    private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe/logs/session", isDirectory: true)
    }

    /// The sessions whose process is still there, with what each is doing.
    func read() -> [VibeSessionRecord] {
        let active = Self.root.appendingPathComponent("active", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: active.path) else {
            tails = [:]
            return []
        }
        var records: [VibeSessionRecord] = []
        for name in names.sorted() where name.hasSuffix(".lock.json") {
            // The lease beside the lock: which session, held by which
            // process. A session that was killed leaves it behind.
            guard let data = try? Data(contentsOf: active.appendingPathComponent(name)),
                  let lease = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = lease["session_id"] as? String, Self.isSessionID(id),
                  let pid = (lease["process_id"] as? NSNumber)?.int32Value, pid > 0,
                  kill(pid, 0) == 0 || errno == EPERM
            else { continue }
            let folder = Self.root.appendingPathComponent("unified/\(id)", isDirectory: true)
            let meta = meta(of: id, in: folder)
            guard meta?.isChild != true else { continue }
            let journal = journal(of: id, in: folder)
            records.append(VibeSessionRecord(
                id: id, pid: pid,
                name: VibeSessionRecord.name(title: journal.title, given: journal.titleGiven, folder: meta?.folder),
                state: journal.state, wants: journal.wants))
        }
        let live = Set(records.map(\.id))
        tails = tails.filter { live.contains($0.key) }
        metas = metas.filter { live.contains($0.key) }
        return records
    }

    /// Letters, digits, dash and underscore: the id goes into a path.
    static func isSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.first != "-" && id.first != "_"
            && id.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
            }
    }

    /// Where the session runs, read once: it is written when the session
    /// starts and doesn't move.
    private func meta(of id: String, in folder: URL) -> Meta? {
        if let known = metas[id] { return known }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let meta = Meta(folder: (json["environment"] as? [String: Any])?["working_directory"] as? String,
                        isChild: json["parent_session_id"] is String)
        metas[id] = meta
        return meta
    }

    /// The newest journal file, read from where the last look left off.
    private func journal(of id: String, in folder: URL) -> VibeJournal {
        let directory = folder.appendingPathComponent("journal", isDirectory: true)
        // Named by the step each starts at, zero-padded: the last by name
        // is the newest.
        guard let file = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter({ $0.hasSuffix(".jsonl") }).max() else { return tails[id]?.journal ?? VibeJournal() }
        var tail = tails[id] ?? Tail(file: file)
        if tail.file != file {
            tail.file = file
            tail.offset = 0
            tail.journal.startOver()
        }
        if let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent(file)) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size < tail.offset {
                // Shorter than what was read: written afresh.
                tail.offset = 0
                tail.journal.startOver()
            }
            if size > tail.offset, (try? handle.seek(toOffset: tail.offset)) != nil,
               let data = try? handle.readToEnd(), let end = data.lastIndex(of: 0x0A) {
                // Up to the last whole line; one half written waits a second.
                let whole = data[data.startIndex...end]
                tail.journal.read(whole)
                tail.offset += UInt64(whole.count)
            }
        }
        tails[id] = tail
        return tail.journal
    }
}

/// Watches Vibe's sessions and asks Mistral for the allowance.
@MainActor
final class VibeMonitor: ObservableObject {

    /// Nil while switched off, or with no Vibe on this Mac.
    @Published private(set) var status: VibeStatus?

    /// A session has stopped to ask something, or has finished.
    var onEvent: ((NotchActivity) -> Void)?

    private var timer: Timer?
    /// Each session's state at the last look, and since when it has worked.
    private var known: [String: (state: ClaudeStatus.State, workingSince: Date?)] = [:]
    private var usage: VibeUsage?
    /// The app each session runs in, by the session's id.
    private var apps: [String: String] = [:]
    private var lastAsked: Date?
    private var asking = false
    private var looking = false
    private let reader = VibeSessionReader()
    private let queue = DispatchQueue(label: "com.local.resonata.vibe", qos: .utility)

    private nonisolated static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// How often the allowance is asked for, as for Claude Code's limits:
    /// it only moves while something is working. Each asking starts Vibe's
    /// Python, a little under a second.
    private static let busyInterval: TimeInterval = 120
    private static let quietInterval: TimeInterval = 900

    func setEnabled(_ enabled: Bool) {
        if enabled, timer == nil {
            guard FileManager.default.fileExists(atPath: Self.home.appendingPathComponent(".vibe").path)
            else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.look() }
            }
            timer.tolerance = 0.3
            self.timer = timer
            status = VibeStatus(usage: usage)
            look()
        } else if !enabled, timer != nil {
            timer?.invalidate()
            timer = nil
            known = [:]
            status = nil
        }
    }

    /// Has the session files read, off the main thread; a look still under
    /// way is not started twice.
    private func look() {
        guard !looking else { return }
        looking = true
        queue.async { [weak self, reader] in
            let records = reader.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.looking = false
                    if self.timer != nil { self.take(records) }
                }
            }
        }
    }

    private func take(_ records: [VibeSessionRecord]) {
        let now = Date()
        var events: [NotchActivity] = []
        var seen: [String: (state: ClaudeStatus.State, workingSince: Date?)] = [:]
        var finished = false
        for record in records {
            let before = known[record.id]
            let since = record.state == .working ? (before?.workingSince ?? now) : nil
            seen[record.id] = (record.state, since)
            let worked = before?.workingSince.map { now.timeIntervalSince($0) } ?? 0
            if let event = VibeSessionRecord.event(from: before?.state, to: record, workedFor: worked) {
                events.append(event)
            }
            if before?.state == .working, record.state != .working { finished = true }
        }
        known = seen

        let summary = VibeSessionRecord.summary(of: records)
        apps = apps.filter { seen[$0.key] != nil }
        let sessions = records.map { record -> ClaudeStatus.Session in
            // Looked up once per session: it never moves to another app.
            let app = apps[record.id] ?? ClaudeMonitor.hostApp(of: record.pid)?.localizedName
            apps[record.id] = app
            return ClaudeStatus.Session(pid: record.pid, name: record.name, state: record.state, app: app,
                                        key: record.id)
        }
        let new = VibeStatus(state: summary.state, session: summary.session, wants: summary.wants,
                             usage: usage, sessions: sessions)
        if status != new { status = new }

        if let event = events.first(where: { if case .vibeWaiting = $0 { true } else { false } })
            ?? events.first {
            onEvent?(event)
        }

        // The allowance: just after a piece of work ends, and otherwise now
        // and then.
        refreshUsage(ifOlderThan: finished ? 20 : (new.isActive ? Self.busyInterval : Self.quietInterval))
    }

    /// Asks for the allowance, unless it was asked less than `age` ago.
    func refreshUsage(ifOlderThan age: TimeInterval = 0) {
        guard timer != nil, !asking else { return }
        if let lastAsked, Date().timeIntervalSince(lastAsked) < age { return }
        guard let python = Self.locatePython() else { return }
        asking = true
        lastAsked = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let parsed = Self.run(python).flatMap { VibeUsage.parse($0) }
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

    /// The Python Vibe is installed into: the one its `vibe` command names
    /// on its first line. An app started from the Finder has no shell `PATH`
    /// to look along, so the usual places are tried.
    nonisolated static func locatePython() -> URL? {
        let inHome = [".local/bin/vibe", ".local/pipx/venvs/mistral-vibe/bin/vibe"]
            .map { home.appendingPathComponent($0) }
        let system = ["/opt/homebrew/bin/vibe", "/usr/local/bin/vibe"].map { URL(fileURLWithPath: $0) }
        let files = FileManager.default
        for launcher in inHome + system where files.isExecutableFile(atPath: launcher.path) {
            if let handle = try? FileHandle(forReadingFrom: launcher) {
                let head = (try? handle.read(upToCount: 1024)) ?? Data()
                try? handle.close()
                if let path = interpreter(inFirstLine: String(decoding: head, as: UTF8.self)),
                   files.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
            // No such first line: the Python beside the command it links to.
            let beside = launcher.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent("python")
            if files.isExecutableFile(atPath: beside.path) { return beside }
        }
        return nil
    }

    /// "#!/Users/…/mistral-vibe/bin/python3" → that path. Nil for anything
    /// that isn't a Python by its full path: `env python3` would be some
    /// other Python, with no Vibe in it.
    nonisolated static func interpreter(inFirstLine text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("#!") else { return nil }
        let path = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/"), !path.contains(" "),
              (path as NSString).lastPathComponent.hasPrefix("python") else { return nil }
        return path
    }

    /// What Vibe's Python is given to run. It asks Mistral's billing for the
    /// Vibe allowance through the code behind Vibe's own status bar, and
    /// prints one line — see `VibeUsage.parse`. Should that code have moved
    /// in a newer Vibe, the same two addresses are asked directly, with the
    /// key Vibe looks up for itself. Nothing is printed on any failure.
    nonisolated static let helper = """
    import asyncio, json, logging
    logging.disable(logging.CRITICAL)
    BASE = "https://api.mistral.ai/v1"
    KEY = "MISTRAL_API_KEY"

    def say(budget, plan):
        if not budget or (budget.get("initial_budget") or 0) <= 0:
            return False
        print(json.dumps({"percent": budget.get("usage_percentage"), "resets": budget.get("reset_at"),
                          "payg": bool(budget.get("payg_enabled")), "plan": plan}))
        return True

    def vibes_own():
        from vibe.app_server._billing import HttpBillingGateway
        from vibe.core.platform_auth._mistral import api_key_credentials
        read = asyncio.run(HttpBillingGateway().read(
            api_base=BASE, credentials=api_key_credentials(KEY), with_budget=True))
        detail = read.budget.vibe_budget if read.budget else None
        plan = read.subscription.plan_name if read.subscription else None
        return say(detail.model_dump() if detail else None, plan)

    def direct():
        import urllib.request
        from vibe.utils.api_keys import resolve_api_key
        key = resolve_api_key(KEY)
        if not key:
            return False
        def get(path):
            request = urllib.request.Request(BASE + "/billing/" + path,
                                             headers={"Authorization": "Bearer " + key})
            with urllib.request.urlopen(request, timeout=8) as answer:
                return json.load(answer)
        budget = get("budget").get("vibe_budget")
        try:
            plan = get("subscription").get("plan_name")
        except Exception:
            plan = None
        return say(budget, plan)

    for way in (vibes_own, direct):
        try:
            if way():
                break
        except Exception:
            pass
    """

    /// Runs the helper and hands back what it printed; nil if it couldn't
    /// be run or took longer than twenty seconds.
    private nonisolated static func run(_ python: URL) -> String? {
        let process = Process()
        process.executableURL = python
        // Isolated: nothing but Vibe's own packages on its path, and not the
        // folder it happens to be run from.
        process.arguments = ["-I", "-c", helper]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch {
            NSLog("Resonata: could not run Vibe's Python: \(error)")
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

extension PillRing {
    /// Claude Code's session in its orange, its week in blue, Vibe in
    /// Mistral's redder orange.
    var tint: NSColor {
        switch tool {
        case .claude: ClaudeRingView.tint
        case .claudeWeek: ClaudeRingView.blue
        case .vibe: ClaudeRingView.vibe
        }
    }
}

extension ClaudeUsagePage {

    /// Vibe's card: the month's allowance, and the plan it comes with.
    func vibeCard(_ status: VibeStatus) -> some View {
        let usage = status.usage
        return card {
            header(mark: "M", tint: Self.vibe, title: "Vibe") {
                switch status.state {
                case .working: chip(L.t("Working", "Pracuje"), tint: .white)
                case .waiting: chip(L.t("Waiting", "Čeká"), tint: Self.amber)
                case .idle: chip(L.t("Idle", "Volno"), tint: Self.quiet)
                }
            }
            reading(ring: ClaudeRing(fraction: status.fraction, state: status.state, lineWidth: 4.5,
                                     tint: ClaudeRingView.vibe),
                    label: L.t("Month", "Měsíc"),
                    percent: usage?.percent,
                    detail: usage?.resets.map { VibeStatus.day($0) })
            Spacer(minLength: 0)
            if let plan = usage?.plan {
                // A line, no bar: the ring above is the only measure there is.
                HStack {
                    Text(L.t("Plan", "Tarif"))
                    Spacer(minLength: 2)
                    Text(plan)
                }
                .font(.system(size: 7.5))
                .foregroundStyle(Self.quiet)
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
