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
            window.title = L.t("Resonata – Settings", "Resonata – Nastavení")
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
    @AppStorage(Preferences.Key.language) private var language = AppLanguage.system.rawValue
    @AppStorage(Preferences.Key.skipDeclined) private var skipDeclined = true
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var calendar = CalendarStore.shared

    @State private var openAtLogin = LoginItem.isEnabled
    @State private var hotKeyTaken = false
    /// The calendars switched off, kept here so a toggle redraws at once.
    @State private var calendarsOff = Preferences.calendarsOff

    var body: some View {
        Form {
            Section(L.t("General", "Obecné")) {
                Toggle(L.t("Open at login", "Spouštět po přihlášení"), isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        LoginItem.set(on)
                        openAtLogin = LoginItem.isEnabled
                    }
                // Each string is picked once, at launch — see `L` — so a new
                // language shows from the next start, and the label says so.
                Picker(L.t("Language (after a restart)", "Jazyk (po restartu)"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker(L.t("Keyboard shortcut", "Klávesová zkratka"), selection: $hotKey) {
                    ForEach(HotKeyChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: hotKey) { _, value in
                    hotKeyTaken = !HotKey.shared.apply(HotKeyChoice(rawValue: value) ?? .off)
                }
                if hotKeyTaken {
                    Text(L.t("Another app already uses this shortcut. Pick a different one.",
                             "Tuhle zkratku už používá jiná aplikace. Vyber jinou."))
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(L.t("Opened with the shortcut, the panel takes the keyboard: Esc closes it, Space plays and pauses.",
                             "Po otevření zkratkou si panel vezme klávesnici: Esc ho zavře, mezerník pustí a zastaví hudbu."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L.t("Updates", "Aktualizace")) {
                Toggle(L.t("Check for new versions automatically", "Hledat nové verze automaticky"),
                       isOn: $checkForUpdates)
                LabeledContent(L.t("Version \(Updater.currentVersion)", "Verze \(Updater.currentVersion)")) {
                    updateStatus
                }
            }

            Section(L.t("Opening", "Otevírání")) {
                Picker(L.t("Open the notch", "Otevírat notch"), selection: $openMode) {
                    ForEach(OpenMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker(L.t("Animation", "Animace"), selection: $speed) {
                    ForEach(AnimationSpeed.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker(L.t("Shrink the notch after a pause of", "Zmenšit notch po pauze za"),
                       selection: $idleTimeout) {
                    ForEach(Preferences.idleChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
            }

            Section {
                Picker(L.t("Swipe between pages", "Swipe mezi stránkami"), selection: $pageSwipe) {
                    ForEach(PageSwipe.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle(L.t("Lyrics", "Texty písní"), isOn: $showLyrics)
                Toggle(L.t("Calendar beside the player", "Kalendář vedle přehrávače"), isOn: $showCalendar)
                Picker(L.t("Wave colour", "Barva vlny"), selection: $waveColour) {
                    ForEach(WaveColour.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if waveColour == WaveColour.custom.rawValue {
                    ColorPicker(L.t("Custom colour", "Vlastní barva"), selection: customColour,
                                supportsOpacity: false)
                }
            } header: {
                Text(L.t("Open panel", "Otevřený panel"))
            } footer: {
                Text(L.t("Lyrics come from LRCLIB, which is sent the song's title and artist. Switched off, nothing is sent. Click the lyric line in the panel for more of the song.",
                         "Texty jsou z LRCLIB, kam se posílá název a interpret skladby. Když jsou vypnuté, neposílá se nic. Kliknutím na řádek textu v panelu uvidíš víc písně."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Which calendars count, once the calendar is connected.
            if calendar.access == .granted, !calendar.calendars.isEmpty {
                Section {
                    ForEach(calendar.calendars) { item in
                        Toggle(isOn: calendarOn(item.id)) {
                            HStack(spacing: 6) {
                                Text(item.title)
                                Text(item.account)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle(L.t("Leave out events I declined", "Vynechat události, které jsem odmítl"),
                           isOn: $skipDeclined)
                        .onChange(of: skipDeclined) { _, _ in CalendarStore.shared.reload() }
                } header: {
                    Text(L.t("Calendars", "Kalendáře"))
                } footer: {
                    Text(L.t("Only these show beside the player and get the reminder five minutes ahead.",
                             "Jen tyhle se ukazují vedle přehrávače a jen na ně přijde připomínka pět minut předem."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(L.t("New song", "Nová skladba"), isOn: $showSongPeek)
                Toggle(L.t("Battery — charging and low battery", "Baterie — nabíjení a slabá baterie"),
                       isOn: $showChargingPeek)
                Toggle(L.t("Headphones connected", "Připojená sluchátka"), isOn: $showHeadphonesPeek)
                Toggle(L.t("Calendar event, 5 minutes before", "Událost z kalendáře 5 min předem"),
                       isOn: $meetingReminder)
            } header: {
                Text(L.t("Messages in the notch", "Zprávy v notchi"))
            } footer: {
                Text(L.t("They slide out of the closed notch for a moment. While the panel is open, a reminder, low battery or the end of the timer wait until you close it.",
                         "Na chvíli se vysunou ze zavřeného notche. Když je panel zrovna otevřený, připomínka, slabá baterie a konec časovače počkají, až ho zavřeš."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                NumberRow(title: L.t("Work", "Práce"), unit: "min", value: $pomodoroWork, range: 1...240)
                NumberRow(title: L.t("Break", "Pauza"), unit: "min", value: $pomodoroRest, range: 1...240)
                NumberRow(title: L.t("Long break", "Dlouhá pauza"), unit: "min",
                          value: $pomodoroLongRest, range: 1...240)
                NumberRow(title: L.t("Long break after", "Dlouhá pauza po"),
                          unit: pomodoroRounds == 1 ? L.t("round", "kole") : L.t("rounds", "kolech"),
                          value: $pomodoroRounds, range: 1...12)
                HStack {
                    Spacer()
                    Button(L.t("Default (25 + 5)", "Výchozí (25 + 5)")) {
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
                Text(L.t("Work and breaks take turns until you cancel the timer. A change counts from the next phase.",
                         "Práce a pauzy se střídají, dokud časovač nezrušíš. Změna platí od další fáze."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L.t("Apps in the notch", "Aplikace v notchi")) {
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
                            .accessibilityLabel(L.t("Move up", "Posunout výš"))
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == apps.count - 1)
                            .accessibilityLabel(L.t("Move down", "Posunout níž"))
                        Button { QuickApps.remove(url) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(L.t("Remove", "Odebrat"))
                            .accessibilityLabel(L.t("Remove", "Odebrat"))
                    }
                }
                HStack {
                    Button(L.t("Add an app…", "Přidat aplikaci…")) { QuickApps.chooseAndAdd() }
                        .disabled(apps.count >= QuickApps.limit)
                    Spacer()
                    Button(L.t("Defaults", "Výchozí")) {
                        QuickApps.save(QuickApps.defaultPaths().map { URL(fileURLWithPath: $0) })
                    }
                }
            }

        }
        .formStyle(.grouped)
        // A fixed height that scrolls, rather than a window that grows past
        // the bottom of the screen as settings are added.
        .frame(width: 440, height: 640)
        // The list of calendars is read with the events; nothing has asked
        // for those yet if the panel hasn't been opened since launch.
        .onAppear { CalendarStore.shared.reload() }
    }

    /// What the updater is up to, and the one button that fits it.
    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .idle:
            Button(L.t("Check now", "Zkontrolovat")) { updater.check() }
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L.t("Checking…", "Hledám…")).foregroundStyle(.secondary)
            }
        case .upToDate:
            HStack(spacing: 8) {
                Text(L.t("Up to date", "Nejnovější")).foregroundStyle(.secondary)
                Button(L.t("Check now", "Zkontrolovat")) { updater.check() }
            }
        case .available(let release):
            HStack(spacing: 8) {
                Link(L.t("What's new", "Co je nového"), destination: release.page)
                Button(updater.canInstall ? L.t("Install \(release.version)", "Nainstalovat \(release.version)")
                                          : L.t("Download \(release.version)", "Stáhnout \(release.version)")) {
                    updater.install()
                }
                .buttonStyle(.borderedProminent)
            }
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L.t("Installing…", "Instaluju…")).foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.red)
                Button(L.t("Try again", "Zkusit znovu")) { updater.check() }
            }
        }
    }

    /// One calendar's switch: on unless it's in the list of those turned off.
    private func calendarOn(_ id: String) -> Binding<Bool> {
        Binding(get: { !calendarsOff.contains(id) },
                set: { on in
                    if on { calendarsOff.remove(id) } else { calendarsOff.insert(id) }
                    Preferences.calendarsOff = calendarsOff
                    CalendarStore.shared.reload()
                })
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
