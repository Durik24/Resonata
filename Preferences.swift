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
        static let openStyle = "openStyle"
        static let pillStyle = "pillStyle"
        static let trackChange = "trackChange"
        static let trackFlash = "trackFlash"
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
            Key.openStyle: OpenStyle.zoom.rawValue,
            Key.pillStyle: PillStyle.bars.rawValue,
            Key.trackChange: TrackChange.fade.rawValue,
            Key.trackFlash: true,
        ])
    }

    /// Seconds after a pause before the pill goes idle — and audio capture
    /// stops with it.
    static var idleTimeout: TimeInterval {
        let value = UserDefaults.standard.double(forKey: Key.idleTimeout)
        return value > 0 ? value : 10
    }

    static var showLyrics: Bool { UserDefaults.standard.bool(forKey: Key.showLyrics) }

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

/// How the panel opens and closes. The speed setting scales each of them.
enum OpenStyle: String, CaseIterable, Identifiable {
    /// The content grows with the box, out of the notch. The default.
    case zoom
    /// A spring with a visible overshoot: the panel lands and rebounds.
    case bounce
    /// An ease-out curve with no overshoot at all.
    case smooth
    /// Very fast and fully damped — there, not travelling.
    case snap
    /// The content stays put and the box reveals it, top down, like a
    /// curtain falling out of the notch.
    case pour

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zoom: "Přiblížení"
        case .bounce: "Pružina"
        case .smooth: "Plynulé"
        case .snap: "Cvaknutí"
        case .pour: "Vylití"
        }
    }

    /// Whether the content scales with the box (true) or is revealed by it.
    var scalesContent: Bool { self != .pour }

    func animation(speed: AnimationSpeed) -> Animation {
        let k: Double = switch speed {
        case .fast: 0.6
        case .normal: 1
        case .slow: 1.5
        }
        return switch self {
        case .zoom: .spring(response: 0.45 * k, dampingFraction: 0.82)
        case .bounce: .spring(response: 0.55 * k, dampingFraction: 0.58)
        case .smooth: .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.5 * k)
        case .snap: .spring(response: 0.18 * k, dampingFraction: 1)
        case .pour: .spring(response: 0.6 * k, dampingFraction: 0.78)
        }
    }
}

/// What the closed notch shows on the right of the cover.
enum PillStyle: String, CaseIterable, Identifiable {
    case bars, wave, dots, ring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bars: "Sloupce"
        case .wave: "Vlnka"
        case .dots: "Pulzující tečky"
        case .ring: "Kruh kolem obalu"
        }
    }
}

/// How the cover changes when the song does.
enum TrackChange: String, CaseIterable, Identifiable {
    case fade, flip, slide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fade: "Prolnutí"
        case .flip: "Otočení"
        case .slide: "Posun"
        }
    }
}
