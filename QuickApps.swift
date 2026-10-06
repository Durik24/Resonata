import AppKit
import UniformTypeIdentifiers

/// The apps on the open panel's "Aplikace" page.
///
/// Stored as one string of paths, one per line, so SwiftUI's `@AppStorage`
/// can watch it directly and the grid updates the moment the list changes.
enum QuickApps {

    /// Two rows of six, one tile kept for "add".
    static let limit = 11

    /// Apps worth having from the first launch, where they exist here.
    static func defaultPaths(fileManager: FileManager = .default) -> [String] {
        [
            "/System/Library/CoreServices/Finder.app",
            "/Applications/Safari.app",
            "/Applications/Spotify.app",
            "/System/Applications/Music.app",
            "/System/Applications/Mail.app",
            "/System/Applications/Messages.app",
            "/System/Applications/Notes.app",
            "/System/Applications/Calendar.app",
            "/System/Applications/System Settings.app",
        ]
        .filter { fileManager.fileExists(atPath: $0) }
        // The real app, not a link to it: on recent macOS /Applications/Safari
        // is a link into the system, and its icon then carries an alias arrow.
        .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    static func urls(from stored: String) -> [URL] {
        var seen = Set<String>()
        return stored.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0) }
    }

    static func string(from urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }

    static var current: [URL] {
        urls(from: UserDefaults.standard.string(forKey: Preferences.Key.quickApps) ?? "")
    }

    static func save(_ urls: [URL]) {
        UserDefaults.standard.set(string(from: Array(urls.prefix(limit))),
                                  forKey: Preferences.Key.quickApps)
    }

    static func add(_ url: URL) {
        let url = url.resolvingSymlinksInPath()
        var list = current
        guard !list.contains(url), list.count < limit else { return }
        list.append(url)
        save(list)
    }

    static func remove(_ url: URL) {
        save(current.filter { $0 != url })
    }

    static func name(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    static func launch(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { NSLog("Resonata: could not open \(url.lastPathComponent): \(error)") }
        }
    }

    /// The standard "choose an app" dialog, starting in Applications.
    @MainActor
    static func chooseAndAdd() {
        let panel = NSOpenPanel()
        panel.title = "Přidat aplikaci do notche"
        panel.prompt = "Přidat"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        // An accessory app has to step forward for its dialog to take clicks.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { add(url) }
        }
    }
}
