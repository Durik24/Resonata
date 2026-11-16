import AppKit

// GitHub in the notch: somebody else pushed to a repository you follow, its
// checks failed, or it has a new release. Each slides out to the left; a
// click opens the commit, the run or the release.
//
// Asked every couple of minutes, three small questions a repository. Through
// the `gh` command when it is installed and signed in — it does the signing
// in itself, so Resonata never sees a token, and private repositories work —
// and otherwise straight from api.github.com without signing in, which only
// sees public ones and is asked less often. Off until a repository is named
// in Settings.

/// What GitHub last said of one repository: the newest commit, the newest
/// finished run of its checks, the newest release.
struct GitHubSnapshot: Equatable, Sendable {
    var commit: String?
    var run: Int?
    var release: Int?
}

enum GitHubFeed {

    struct Commit: Equatable, Sendable {
        var sha: String
        /// The author's GitHub name, when the commit is tied to an account.
        var login: String?
        /// The name the commit itself carries.
        var name: String
        /// The first line of the message.
        var message: String
        var url: URL?
    }

    struct Run: Equatable, Sendable {
        var id: Int
        var name: String
        var branch: String
        /// "success", "failure", …; nil while it is still running.
        var conclusion: String?
        var url: URL?
    }

    struct Release: Equatable, Sendable {
        var id: Int
        var tag: String
        var author: String?
        var draft: Bool
        var url: URL?
    }

    /// The repositories named in the settings' field: "owner/name", several
    /// apart by commas, spaces or lines; a pasted github.com address counts
    /// too. At most `limit`, each once.
    nonisolated static func repos(from text: String, limit: Int = 4) -> [String] {
        var found: [String] = []
        for var piece in text.components(separatedBy: CharacterSet(charactersIn: ", \n\t;")) {
            for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where piece.hasPrefix(prefix) {
                piece.removeFirst(prefix.count)
            }
            if piece.hasSuffix(".git") { piece.removeLast(4) }
            let parts = piece.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            let owner = String(parts[0]), name = String(parts[1])
            guard owner.unicodeScalars.allSatisfy(allowed.contains),
                  name.unicodeScalars.allSatisfy(allowed.contains) else { continue }
            let repo = "\(owner)/\(name)"
            if !found.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) { found.append(repo) }
            if found.count == limit { break }
        }
        return found
    }

    /// The newest commit, from `repos/…/commits?per_page=1`.
    nonisolated static func commit(from data: Data) -> Commit? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = list.first, let sha = first["sha"] as? String else { return nil }
        let commit = first["commit"] as? [String: Any]
        let message = (commit?["message"] as? String ?? "").components(separatedBy: .newlines).first ?? ""
        return Commit(sha: sha,
                      login: (first["author"] as? [String: Any])?["login"] as? String,
                      name: (commit?["author"] as? [String: Any])?["name"] as? String ?? "",
                      message: message.trimmingCharacters(in: .whitespaces),
                      url: (first["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// The latest runs of the checks, newest first, from `repos/…/actions/runs`.
    nonisolated static func runs(from data: Data) -> [Run] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["workflow_runs"] as? [[String: Any]] else { return [] }
        return list.compactMap { run in
            guard let id = (run["id"] as? NSNumber)?.intValue else { return nil }
            return Run(id: id, name: run["name"] as? String ?? "",
                       branch: run["head_branch"] as? String ?? "",
                       conclusion: run["conclusion"] as? String,
                       url: (run["html_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// The newest release, from `repos/…/releases?per_page=1`.
    nonisolated static func release(from data: Data) -> Release? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = list.first, let id = (first["id"] as? NSNumber)?.intValue else { return nil }
        return Release(id: id, tag: first["tag_name"] as? String ?? "",
                       author: (first["author"] as? [String: Any])?["login"] as? String,
                       draft: first["draft"] as? Bool ?? false,
                       url: (first["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// What is worth saying, given what the repository looked like last time
    /// (`before`, nil the first time — which says nothing: everything is new
    /// then) and what it looks like now. A part that couldn't be read is nil
    /// and keeps what was known. `me` is the user's own GitHub name: their
    /// own pushes and releases are no news to them.
    nonisolated static func news(repo: String, before: GitHubSnapshot?, commit: Commit?, runs: [Run],
                                 release: Release?, me: String?)
        -> (events: [NotchActivity], snapshot: GitHubSnapshot) {
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        func mine(_ who: String?) -> Bool {
            guard let who, let me else { return false }
            return who.caseInsensitiveCompare(me) == .orderedSame
        }
        var events: [NotchActivity] = []
        var snapshot = before ?? GitHubSnapshot()

        // Failed checks first: of everything here, that is the one to act on.
        let finished = runs.filter { $0.conclusion != nil }
        if let newest = finished.map(\.id).max() {
            if let seen = before?.run,
               let failed = finished.filter({ $0.id > seen && $0.conclusion == "failure" }).max(by: { $0.id < $1.id }) {
                let detail = [failed.branch, failed.name].filter { !$0.isEmpty }.joined(separator: " · ")
                events.append(.githubChecksFailed(repo: name, detail: detail, url: failed.url))
            }
            snapshot.run = max(newest, before?.run ?? 0)
        }
        if let commit {
            if let seen = before?.commit, seen != commit.sha, !mine(commit.login) {
                let who = commit.login ?? (commit.name.isEmpty ? "?" : commit.name)
                events.append(.githubPush(who: who, repo: name, message: commit.message, url: commit.url))
            }
            snapshot.commit = commit.sha
        }
        if let release, !release.draft {
            if let seen = before?.release, seen != release.id, !mine(release.author) {
                events.append(.githubRelease(repo: name, tag: release.tag, url: release.url))
            }
            snapshot.release = release.id
        }
        // A repository with no release or no checks yet: remembered as
        // "none so far" rather than "never looked", so its first one is news.
        if before == nil {
            if snapshot.run == nil { snapshot.run = 0 }
            if snapshot.release == nil, release == nil { snapshot.release = 0 }
        }
        return (events, snapshot)
    }
}

/// Asks GitHub about the followed repositories, now and then.
@MainActor
final class GitHubWatcher {

    /// Something worth saying happened in a followed repository.
    var onEvent: ((NotchActivity) -> Void)?

    private var timer: Timer?
    private var repos: [String] = []
    private var snapshots: [String: GitHubSnapshot] = [:]
    private var asking = false
    private let queue = DispatchQueue(label: "com.local.resonata.github", qos: .utility)

    /// Every two minutes through `gh`; without it, GitHub allows sixty
    /// questions an hour, and three a repository have to fit.
    nonisolated static func interval(repos: Int, signedIn: Bool) -> TimeInterval {
        signedIn ? 120 : max(300, TimeInterval(repos) * 240)
    }

    /// Starts, stops or re-aims the asking, to match the settings.
    func apply(enabled: Bool, repos text: String) {
        let wanted = enabled ? GitHubFeed.repos(from: text) : []
        guard wanted != repos else { return }
        repos = wanted
        snapshots = snapshots.filter { wanted.contains($0.key) }
        timer?.invalidate()
        timer = nil
        guard !wanted.isEmpty else { return }
        let every = Self.interval(repos: wanted.count, signedIn: GitHubClient.gh != nil)
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ask() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        ask()
    }

    /// Debug only: forgets the newest commit of each repository and asks
    /// again, so the real one is said as if it had just been pushed.
    func askAsIfNew() {
        for repo in repos where snapshots[repo] != nil { snapshots[repo]?.commit = "forgotten" }
        ask()
    }

    private func ask() {
        guard !asking, !repos.isEmpty else { return }
        asking = true
        let repos = repos, before = snapshots
        queue.async { [weak self] in
            let me = GitHubClient.me()
            var results: [(String, [NotchActivity], GitHubSnapshot)] = []
            for repo in repos {
                let commit = GitHubClient.get("repos/\(repo)/commits?per_page=1").flatMap(GitHubFeed.commit(from:))
                let runs = GitHubClient.get("repos/\(repo)/actions/runs?per_page=10").map(GitHubFeed.runs(from:)) ?? []
                let release = GitHubClient.get("repos/\(repo)/releases?per_page=1").flatMap(GitHubFeed.release(from:))
                // Nothing came back at all: offline, or no such repository.
                // What was known stays known.
                guard commit != nil || !runs.isEmpty || release != nil else { continue }
                let news = GitHubFeed.news(repo: repo, before: before[repo], commit: commit, runs: runs,
                                           release: release, me: me)
                results.append((repo, news.events, news.snapshot))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.asking = false
                    for (repo, events, snapshot) in results where self.repos.contains(repo) {
                        if NotchPanel.debugClick {
                            NSLog("github: %@ commit %@ run %ld release %ld, %ld to say", repo,
                                  String((snapshot.commit ?? "-").prefix(7)), snapshot.run ?? -1,
                                  snapshot.release ?? -1, events.count)
                        }
                        self.snapshots[repo] = snapshot
                        // One at a time; the notch shows one message.
                        if let first = events.first { self.onEvent?(first) }
                    }
                }
            }
        }
    }
}

/// The two ways of asking GitHub a question.
enum GitHubClient {

    /// The `gh` command, where it is installed.
    nonisolated static let gh: URL? = {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let places = [home.appendingPathComponent(".local/bin/gh"),
                      URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
                      URL(fileURLWithPath: "/usr/local/bin/gh"),
                      URL(fileURLWithPath: "/usr/bin/gh")]
        return places.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var login: String?
    nonisolated(unsafe) private static var askedLogin = false
    /// `gh` is there but isn't signed in: straight to the public address.
    nonisolated(unsafe) private static var ghRefused = false

    /// The user's own GitHub name, from `gh`; nil without it. Asked once.
    nonisolated static func me() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if askedLogin { return login }
        askedLogin = true
        guard let data = runGH(["api", "user", "--jq", ".login"]),
              let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        login = name
        return name
    }

    /// The answer to `path` under api.github.com; nil when there is none.
    nonisolated static func get(_ path: String) -> Data? {
        if gh != nil, !ghRefused {
            if let data = runGH(["api", path]) { return data }
            // Not signed in is a failure every time; a repository that isn't
            // there is one too — the public address answers which.
            if runGH(["auth", "status"]) == nil { ghRefused = true }
            else { return nil }
        }
        guard let url = URL(string: "https://api.github.com/" + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Resonata/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { answer = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return answer
    }

    /// Runs `gh` and hands back what it printed; nil if it failed or took
    /// longer than twenty seconds.
    private nonisolated static func runGH(_ arguments: [String]) -> Data? {
        guard let gh else { return nil }
        let process = Process()
        process.executableURL = gh
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Its answers are read by a program: no colours, no pager, no
        // "a new version is out".
        environment["NO_COLOR"] = "1"
        environment["GH_PAGER"] = "cat"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_PROMPT_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
