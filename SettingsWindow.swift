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

    @State private var openAtLogin = LoginItem.isEnabled
    @State private var hotKeyTaken = false

    var body: some View {
        Form {
            Section {
                Toggle("Spouštět po přihlášení", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        LoginItem.set(on)
                        openAtLogin = LoginItem.isEnabled
                    }
                Picker("Otevřít notch zkratkou", selection: $hotKey) {
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

            Section {
                Picker("Zmenšit notch po pauze za", selection: $idleTimeout) {
                    ForEach(Preferences.idleChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Picker("Animace", selection: $speed) {
                    ForEach(AnimationSpeed.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Zobrazovat texty písní", isOn: $showLyrics)
            }

            Section {
                Picker("Barva vlny", selection: $waveColour) {
                    ForEach(WaveColour.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if waveColour == WaveColour.custom.rawValue {
                    ColorPicker("Vlastní barva", selection: customColour, supportsOpacity: false)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var customColour: Binding<Color> {
        Binding(get: { Color(hex: customHex) ?? .white },
                set: { customHex = $0.hex })
    }
}
