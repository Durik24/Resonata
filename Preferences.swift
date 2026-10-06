import AppKit
import SwiftUI

/// Everything the settings window can change, in one place, stored in
/// `UserDefaults`. Views read the same keys through `@AppStorage`, so a
/// change in the settings window shows in the notch at once.
enum Preferences {

    enum Key {
        static let idleTimeout = "idleTimeout"
        static let animationSpeed = "animationSpeed"
        static let waveColour = "waveColour"
        static let customWaveColour = "customWaveColour"
        static let showLyrics = "showLyrics"
        static let hotKey = "hotKey"
        static let showSongPeek = "showSongPeek"
        static let quickApps = "quickApps"
        static let showCalendar = "showCalendar"
    }

    /// Call before anything reads a preference.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.idleTimeout: 10.0,
            Key.animationSpeed: AnimationSpeed.normal.rawValue,
            Key.waveColour: WaveColour.album.rawValue,
            Key.customWaveColour: "#FFFFFF",
            Key.showLyrics: true,
            Key.hotKey: HotKeyChoice.shiftCommandSpace.rawValue,
            Key.showSongPeek: true,
            Key.showCalendar: true,
            Key.quickApps: QuickApps.defaultPaths().joined(separator: "\n"),
        ])
    }

    /// Seconds after a pause before the pill goes idle — and audio capture
    /// stops with it.
    static var idleTimeout: TimeInterval {
        let value = UserDefaults.standard.double(forKey: Key.idleTimeout)
        return value > 0 ? value : 10
    }

    static var showLyrics: Bool { UserDefaults.standard.bool(forKey: Key.showLyrics) }

    static var showSongPeek: Bool { UserDefaults.standard.bool(forKey: Key.showSongPeek) }

    static var showCalendar: Bool { UserDefaults.standard.bool(forKey: Key.showCalendar) }

    static var animationSpeed: AnimationSpeed {
        AnimationSpeed(rawValue: UserDefaults.standard.string(forKey: Key.animationSpeed) ?? "")
            ?? .normal
    }

    static var hotKey: HotKeyChoice {
        HotKeyChoice(rawValue: UserDefaults.standard.string(forKey: Key.hotKey) ?? "") ?? .off
    }

    static let idleChoices: [TimeInterval] = [5, 10, 20, 30, 60]
}

/// How unhurried the notch's springs and fades are.
enum AnimationSpeed: String, CaseIterable, Identifiable {
    case fast, normal, slow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: "Rychlé"
        case .normal: "Normální"
        case .slow: "Pomalé"
        }
    }

    /// The spring for everything that changes size.
    var spring: Animation {
        switch self {
        case .fast: .spring(response: 0.25, dampingFraction: 0.86)
        case .normal: .spring(response: 0.45, dampingFraction: 0.82)
        case .slow: .spring(response: 0.7, dampingFraction: 0.8)
        }
    }

    /// The fade for content swapping in place.
    var fade: Animation {
        switch self {
        case .fast: .easeInOut(duration: 0.2)
        case .normal: .easeInOut(duration: 0.4)
        case .slow: .easeInOut(duration: 0.65)
        }
    }
}

/// What colour the wave in the open panel is.
enum WaveColour: String, CaseIterable, Identifiable {
    case album, white, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .album: "Podle obalu alba"
        case .white: "Bílá"
        case .custom: "Vlastní"
        }
    }
}

extension Color {
    /// `#RRGGBB`; nil for anything else.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }

    /// `#RRGGBB` in sRGB.
    var hex: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
    }
}
