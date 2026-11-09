import AppKit
import Foundation
import Security

/// Looks for a newer Resonata on GitHub and, when asked, installs it.
///
/// Checking reads the latest release's version number from GitHub's public
/// API: nothing about this Mac is sent, and nothing is downloaded until the
/// user clicks Install.
///
/// Installing from here, rather than from the browser, is also what spares
/// the "Open Anyway" trip to System Settings on every update. A browser marks
/// what it downloads as quarantined and Gatekeeper then stops the app, which
/// isn't notarized. Resonata's own download carries no such mark. That makes
/// this the one gate, so it's a strict one: the new copy must be signed with
/// the very certificate the running copy is — `isSignedLikeMe` — or nothing
/// is replaced.
@MainActor
final class Updater: ObservableObject {

    static let shared = Updater()

    struct Release: Equatable {
        var version: String
        var page: URL
        var zip: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing
        case failed(String)
    }

    @Published private(set) var state = State.idle

    /// Called once per new version found, so the notch can say so.
    var onFound: ((Release) -> Void)?

    nonisolated static let repo = "Durik24/Resonata"
    nonisolated static let releasesPage = URL(string: "https://github.com/\(repo)/releases")!
    /// `RESONATA_UPDATE_FEED`, in a debug run only, points at a local stand-in
    /// for GitHub, so installing can be tried without publishing a release.
    private static let latestURL: URL = {
        if NotchPanel.debugClick, let feed = ProcessInfo.processInfo.environment["RESONATA_UPDATE_FEED"],
           let url = URL(string: feed) { return url }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }()
    /// Once a day is plenty; the hourly timer only asks whether a day has passed.
    private static let interval: TimeInterval = 24 * 3600
    private static let lastCheckKey = "updateLastCheck"
    private static let announcedKey = "updateAnnounced"

    private var timer: Timer?

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Installing replaces the app where it is, so only an installed copy
    /// does it; a build in the project folder just links to the page.
    var canInstall: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
    }

    // MARK: Checking

    /// Checks a little after launch and then daily, while the preference is on.
    func start() {
        // Debug: `com.local.resonata.check` and `com.local.resonata.install`.
        if NotchPanel.debugClick {
            let center = DistributedNotificationCenter.default()
            center.addObserver(forName: Notification.Name("com.local.resonata.check"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Updater.shared.check() }
            }
            center.addObserver(forName: Notification.Name("com.local.resonata.install"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Updater.shared.install() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard Preferences.checkForUpdates else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= Self.interval else { return }
        check()
    }

    func check() {
        switch state {
        case .checking, .installing: return
        default: break
        }
        state = .checking
        Task {
            do {
                let release = try await Self.fetchLatest()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                guard let release, Self.isNewer(release.version, than: Self.currentVersion) else {
                    state = .upToDate
                    return
                }
                state = .available(release)
                if UserDefaults.standard.string(forKey: Self.announcedKey) != release.version {
                    UserDefaults.standard.set(release.version, forKey: Self.announcedKey)
                    onFound?(release)
                }
            } catch {
                NSLog("Resonata: update check failed: \(error)")
                state = .failed("Nepodařilo se spojit s GitHubem.")
            }
        }
    }

    private static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Resonata/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return parseRelease(data)
    }

    /// The release's version and its zip, from GitHub's JSON. Nil when it
    /// has no zip to install.
    nonisolated static func parseRelease(_ data: Data) -> Release? {
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
        struct Latest: Decodable {
            var tag_name: String
            var html_url: URL
            var draft: Bool?
            var prerelease: Bool?
            var assets: [Asset]
        }
        guard let latest = try? JSONDecoder().decode(Latest.self, from: data),
              latest.draft != true, latest.prerelease != true else { return nil }
        let zips = latest.assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        guard let zip = zips.first(where: { $0.name.contains("AppleSilicon") }) ?? zips.first else { return nil }
        let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
        return Release(version: version, page: latest.html_url, zip: zip.browser_download_url)
    }

    /// "1.0.10" is newer than "1.0.9"; missing parts count as 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    func install() {
        guard case .available(let release) = state else { return }
        guard canInstall else {
            NSWorkspace.shared.open(release.page)
            return
        }
        state = .installing
        Task {
            do {
                try await Self.download(release, replacing: Bundle.main.bundleURL)
                NSLog("Resonata: updated to %@, relaunching", release.version)
                Self.relaunch()
            } catch {
                NSLog("Resonata: update failed: \(error)")
                state = .failed((error as? UpdateError)?.message ?? "Aktualizace se nepovedla.")
            }
        }
    }

    struct UpdateError: Error {
        var message: String
    }

    /// Downloads, unpacks and checks the new copy, then swaps it in for the
    /// running one in a single step, so a failure leaves the old one intact.
    private nonisolated static func download(_ release: Release, replacing current: URL) async throws {
        let fm = FileManager.default
        // Beside the app, on the same volume, so the final swap is atomic.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                              appropriateFor: current, create: true)
        defer { try? fm.removeItem(at: work) }

        var request = URLRequest(url: release.zip, timeoutInterval: 120)
        request.setValue("Resonata/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(message: "Stažení se nepovedlo.")
        }
        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: file, to: zip)

        let unpacked = work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let app = unpacked.appendingPathComponent("Resonata.app")
        guard fm.fileExists(atPath: app.path) else {
            throw UpdateError(message: "V balíčku chybí Resonata.app.")
        }

        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let version = info?["CFBundleShortVersionString"] as? String,
              isNewer(version, than: currentVersion) else {
            throw UpdateError(message: "Stažená aplikace není novější Resonata.")
        }
        guard isSignedLikeMe(app) else {
            throw UpdateError(message: "Stažená aplikace nemá správný podpis, nic jsem nevyměnil.")
        }

        _ = try fm.replaceItemAt(current, withItemAt: app)
    }

    /// True when `app` has an intact signature that meets the running app's
    /// designated requirement — for Resonata, its own bundle ID signed by the
    /// same leaf certificate. Anyone else's build, or a tampered one, fails.
    nonisolated static func isSignedLikeMe(_ app: URL) -> Bool {
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        var theirs: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(theirs, flags, requirement) == errSecSuccess
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(message: "Balíček se nepodařilo rozbalit.")
        }
    }

    /// Opens the new copy once this one has quit. A small shell waits for
    /// this process to be gone first; opening while it still runs would only
    /// bring the old one forward.
    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                             "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            NSLog("Resonata: could not schedule relaunch: \(error)")
        }
        NSApp.terminate(nil)
    }
}
