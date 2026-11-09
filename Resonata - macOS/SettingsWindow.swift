import AppKit
import SwiftUI

/// Opens the settings window from the right-click menu.
///
/// An ordinary window rather than SwiftUI's `Settings` scene: that scene is
/// opened from an app's menu bar, and Resonata has none.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Resonata – Nastavení"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // An accessory app has to step forward for its window to take keys.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @AppStorage(Preferences.Key.idleTimeout) private var idleTimeout = 10.0
    @AppStorage(Preferences.Key.animationSpeed) private var speed = AnimationSpeed.normal.rawValue
    @AppStorage(Preferences.Key.waveColour) private var waveColour = WaveColour.album.rawValue
    @AppStorage(Preferences.Key.customWaveColour) private var customHex = "#FFFFFF"
    @AppStorage(Preferences.Key.showLyrics) private var showLyrics = true
    @AppStorage(Preferences.Key.hotKey) private var hotKey = HotKeyChoice.shiftCommandSpace.rawValue
    @AppStorage(Preferences.Key.showSongPeek) private var showSongPeek = true
    @AppStorage(Preferences.Key.showCalendar) private var showCalendar = true
    @AppStorage(Preferences.Key.showChargingPeek) private var showChargingPeek = true
    @AppStorage(Preferences.Key.showHeadphonesPeek) private var showHeadphonesPeek = true
    @AppStorage(Preferences.Key.meetingReminder) private var meetingReminder = true
    @AppStorage(Preferences.Key.pomodoroWork) private var pomodoroWork = 25
    @AppStorage(Preferences.Key.pomodoroRest) private var pomodoroRest = 5
    @AppStorage(Preferences.Key.pomodoroLongRest) private var pomodoroLongRest = 15
    @AppStorage(Preferences.Key.pomodoroRounds) private var pomodoroRounds = 4
    @AppStorage(Preferences.Key.openMode) private var openMode = OpenMode.nook.rawValue
    @AppStorage(Preferences.Key.pageSwipe) private var pageSwipe = PageSwipe.withFingers.rawValue
    @AppStorage(Preferences.Key.quickApps) private var quickApps = ""
    @AppStorage(Preferences.Key.checkForUpdates) private var checkForUpdates = true
    @ObservedObject private var updater = Updater.shared

    @State private var openAtLogin = LoginItem.isEnabled
    @State private var hotKeyTaken = false

    var body: some View {
        Form {
            Section("Obecné") {
                Toggle("Spouštět po přihlášení", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        LoginItem.set(on)
                        openAtLogin = LoginItem.isEnabled
                    }
                Picker("Klávesová zkratka", selection: $hotKey) {
                    ForEach(HotKeyChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: hotKey) { _, value in
                    hotKeyTaken = !HotKey.shared.apply(HotKeyChoice(rawValue: value) ?? .off)
                }
                if hotKeyTaken {
                    Text("Tuhle zkratku už používá jiná aplikace. Vyber jinou.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Aktualizace") {
                Toggle("Hledat nové verze automaticky", isOn: $checkForUpdates)
                LabeledContent("Verze \(Updater.currentVersion)") {
                    updateStatus
                }
            }

            Section("Otevírání") {
                Picker("Otevírat notch", selection: $openMode) {
                    ForEach(OpenMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Animace", selection: $speed) {
                    ForEach(AnimationSpeed.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Zmenšit notch po pauze za", selection: $idleTimeout) {
                    ForEach(Preferences.idleChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
            }

            Section("Otevřený panel") {
                Picker("Swipe mezi stránkami", selection: $pageSwipe) {
                    ForEach(PageSwipe.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Texty písní", isOn: $showLyrics)
                Toggle("Kalendář vedle přehrávače", isOn: $showCalendar)
                Picker("Barva vlny", selection: $waveColour) {
                    ForEach(WaveColour.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if waveColour == WaveColour.custom.rawValue {
                    ColorPicker("Vlastní barva", selection: customColour, supportsOpacity: false)
                }
            }

            Section {
                Toggle("Nová skladba", isOn: $showSongPeek)
                Toggle("Baterie — nabíjení a slabá baterie", isOn: $showChargingPeek)
                Toggle("Připojená sluchátka", isOn: $showHeadphonesPeek)
                Toggle("Událost z kalendáře 5 min předem", isOn: $meetingReminder)
            } header: {
                Text("Zprávy v notchi")
            } footer: {
                Text("Na chvíli se vysunou ze zavřeného notche. Když je panel zrovna otevřený, připomínka, slabá baterie a konec časovače počkají, až ho zavřeš.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                NumberRow(title: "Práce", unit: "min", value: $pomodoroWork, range: 1...240)
                NumberRow(title: "Pauza", unit: "min", value: $pomodoroRest, range: 1...240)
                NumberRow(title: "Dlouhá pauza", unit: "min", value: $pomodoroLongRest, range: 1...240)
                NumberRow(title: "Dlouhá pauza po", unit: pomodoroRounds == 1 ? "kole" : "kolech",
                          value: $pomodoroRounds, range: 1...12)
                HStack {
                    Spacer()
                    Button("Výchozí (25 + 5)") {
                        let plan = PomodoroPlan.standard
                        pomodoroWork = plan.work
                        pomodoroRest = plan.rest
                        pomodoroLongRest = plan.longRest
                        pomodoroRounds = plan.rounds
                    }
                }
            } header: {
                Text("Pomodoro")
            } footer: {
                Text("Práce a pauzy se střídají, dokud časovač nezrušíš. Změna platí od další fáze.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Aplikace v notchi") {
                let apps = QuickApps.urls(from: quickApps)
                ForEach(Array(apps.enumerated()), id: \.element) { index, url in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(QuickApps.name(of: url))
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == apps.count - 1)
                        Button { QuickApps.remove(url) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Odebrat")
                    }
                }
                HStack {
                    Button("Přidat aplikaci…") { QuickApps.chooseAndAdd() }
                        .disabled(apps.count >= QuickApps.limit)
                    Spacer()
                    Button("Výchozí") { QuickApps.save(QuickApps.defaultPaths().map { URL(fileURLWithPath: $0) }) }
                }
            }

        }
        .formStyle(.grouped)
        // A fixed height that scrolls, rather than a window that grows past
        // the bottom of the screen as settings are added.
        .frame(width: 440, height: 640)
    }

    /// What the updater is up to, and the one button that fits it.
    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .idle:
            Button("Zkontrolovat") { updater.check() }
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Hledám…").foregroundStyle(.secondary)
            }
        case .upToDate:
            HStack(spacing: 8) {
                Text("Nejnovější").foregroundStyle(.secondary)
                Button("Zkontrolovat") { updater.check() }
            }
        case .available(let release):
            HStack(spacing: 8) {
                Link("Co je nového", destination: release.page)
                Button(updater.canInstall ? "Nainstalovat \(release.version)" : "Stáhnout \(release.version)") {
                    updater.install()
                }
                .buttonStyle(.borderedProminent)
            }
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Instaluju…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Zkusit znovu") { updater.check() }
            }
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var apps = QuickApps.urls(from: quickApps)
        let target = index + offset
        guard apps.indices.contains(index), apps.indices.contains(target) else { return }
        apps.swapAt(index, target)
        QuickApps.save(apps)
    }

    private var customColour: Binding<Color> {
        Binding(get: { Color(hex: customHex) ?? .white },
                set: { customHex = $0.hex })
    }
}

/// A number the user can type or step: "Práce   [ 25 ] min  ⌃⌄".
/// Typed values are kept within `range`.
private struct NumberRow: View {
    var title: String
    var unit: String
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        // LabeledContent, not an HStack with a Text in it: a form lays out a
        // bare text field as a row of its own, and while one was being typed
        // in, a three-digit value pushed it onto a second line and the row
        // grew — the button below moved out from under the pointer.
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: $value, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .onChange(of: value) { _, new in
                        let kept = min(max(new, range.lowerBound), range.upperBound)
                        if kept != new { value = kept }
                    }
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                Stepper(title, value: $value, in: range)
                    .labelsHidden()
            }
        }
    }
}
