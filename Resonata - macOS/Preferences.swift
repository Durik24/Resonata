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
        static let openMode = "openMode"
        static let showChargingPeek = "showChargingPeek"
        static let showHeadphonesPeek = "showHeadphonesPeek"
        static let meetingReminder = "meetingReminder"
        static let pomodoroWork = "pomodoroWork"
        static let pomodoroRest = "pomodoroRest"
        static let pomodoroLongRest = "pomodoroLongRest"
        static let pomodoroRounds = "pomodoroRounds"
        static let pageSwipe = "pageSwipe"
        static let checkForUpdates = "checkForUpdates"
        static let language = "language"
        static let pinnedScreen = "pinnedScreen"
        static let calendarsOff = "calendarsOff"
        static let skipDeclined = "skipDeclinedEvents"
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
            Key.showChargingPeek: true,
            Key.showHeadphonesPeek: true,
            Key.meetingReminder: true,
            Key.pomodoroWork: 25,
            Key.pomodoroRest: 5,
            Key.pomodoroLongRest: 15,
            Key.pomodoroRounds: 4,
            Key.pageSwipe: PageSwipe.withFingers.rawValue,
            Key.checkForUpdates: true,
            Key.language: AppLanguage.system.rawValue,
            Key.skipDeclined: true,
            Key.openMode: OpenMode.nook.rawValue,
            Key.quickApps: QuickApps.defaultPaths().joined(separator: "\n"),
        ])
    }

    static var pageSwipe: PageSwipe {
        PageSwipe(rawValue: UserDefaults.standard.string(forKey: Key.pageSwipe) ?? "") ?? .withFingers
    }

    /// Seconds after a pause before the pill goes idle.
    static var idleTimeout: TimeInterval {
        let value = UserDefaults.standard.double(forKey: Key.idleTimeout)
        return value > 0 ? value : 10
    }

    /// Whether to look for a new version on GitHub once a day.
    static var checkForUpdates: Bool { UserDefaults.standard.bool(forKey: Key.checkForUpdates) }

    /// Calendars switched off in Settings, by identifier. Kept as the ones
    /// *off*, so a calendar added later counts without anyone having to
    /// notice it and switch it on.
    static var calendarsOff: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.calendarsOff) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Key.calendarsOff) }
    }

    /// Events you said no to stay out of the panel and get no reminder.
    static var skipDeclined: Bool { UserDefaults.standard.bool(forKey: Key.skipDeclined) }

    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: Key.language) ?? "") ?? .system
    }

    static var showLyrics: Bool { UserDefaults.standard.bool(forKey: Key.showLyrics) }

    static var showSongPeek: Bool { UserDefaults.standard.bool(forKey: Key.showSongPeek) }

    static var showCalendar: Bool { UserDefaults.standard.bool(forKey: Key.showCalendar) }

    static var showChargingPeek: Bool { UserDefaults.standard.bool(forKey: Key.showChargingPeek) }

    static var showHeadphonesPeek: Bool { UserDefaults.standard.bool(forKey: Key.showHeadphonesPeek) }

    static var meetingReminder: Bool { UserDefaults.standard.bool(forKey: Key.meetingReminder) }

    /// The Pomodoro lengths the user has set — see `PomodoroPlan`.
    static var pomodoroPlan: PomodoroPlan {
        let d = UserDefaults.standard
        return PomodoroPlan(work: d.integer(forKey: Key.pomodoroWork),
                            rest: d.integer(forKey: Key.pomodoroRest),
                            longRest: d.integer(forKey: Key.pomodoroLongRest),
                            rounds: d.integer(forKey: Key.pomodoroRounds)).clamped
    }

    static var openMode: OpenMode {
        OpenMode(rawValue: UserDefaults.standard.string(forKey: Key.openMode) ?? "") ?? .click
    }

    static var animationSpeed: AnimationSpeed {
        AnimationSpeed(rawValue: UserDefaults.standard.string(forKey: Key.animationSpeed) ?? "")
            ?? .normal
    }

    static var hotKey: HotKeyChoice {
        HotKeyChoice(rawValue: UserDefaults.standard.string(forKey: Key.hotKey) ?? "") ?? .off
    }

    static let idleChoices: [TimeInterval] = [5, 10, 20, 30, 60]
}

/// Two fingers sideways on the open panel.
enum PageSwipe: String, CaseIterable, Identifiable {
    /// The way the fingers go along the strip: right to the next page.
    case withFingers
    /// The other way round, as on a phone: left to the next page.
    case reversed
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .withFingers: L.t("Right = next", "Doprava = další")
        case .reversed: L.t("Left = next (like a phone)", "Doleva = další (jako telefon)")
        case .off: L.t("Off", "Vypnuto")
        }
    }
}

/// How the closed notch opens. A click always works.
/// - hover: the boring.notch way — rest the pointer on it to open, leave
///   to close.
/// - nook: the NotchNook way — hovering only previews the song; swipes on
///   the notch open, close and skip.
enum OpenMode: String, CaseIterable, Identifiable {
    case click, hover, nook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .click: L.t("Click", "Kliknutím")
        case .hover: L.t("Hover (like boring.notch)", "Najetím myší (jako boring.notch)")
        case .nook: L.t("Click and gestures (like NotchNook)", "Kliknutím a gesty (jako NotchNook)")
        }
    }
}

enum AnimationSpeed: String, CaseIterable, Identifiable {
    case fast, normal, slow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: L.t("Fast", "Rychlé")
        case .normal: L.t("Normal", "Normální")
        case .slow: L.t("Slow", "Pomalé")
        }
    }

    /// The spring for everything that changes size.
    var spring: Animation {
        switch self {
        case .fast: .spring(response: 0.25, dampingFraction: 0.86)
        // boring.notch's spring: quicker than ours was, with a hint of
        // overshoot, so the panel lands rather than just stops.
        case .normal: .spring(response: 0.38, dampingFraction: 0.8)
        case .slow: .spring(response: 0.7, dampingFraction: 0.8)
        }
    }

    /// The spring for the panel opening: `spring`, already moving.
    ///
    /// A spring starts from rest — 3% of the way after one frame, 11% after
    /// two — and the panel's content takes a few hundredths of a second to
    /// build before the first frame at all. Together that was a click, a
    /// pause, and then the panel: the open felt stuck. The same spring with
    /// a push behind it is 11% out on its first frame and lands exactly as
    /// before, overshoot included.
    var openSpring: Animation {
        func pushed(response: Double, damping: Double, velocity: Double) -> Animation {
            let stiffness = pow(2 * Double.pi / response, 2)
            return .interpolatingSpring(mass: 1, stiffness: stiffness,
                                        damping: 2 * damping * stiffness.squareRoot(),
                                        initialVelocity: velocity)
        }
        return switch self {
        case .fast: pushed(response: 0.25, damping: 0.86, velocity: 8)
        case .normal: pushed(response: 0.38, damping: 0.8, velocity: 6)
        case .slow: pushed(response: 0.7, damping: 0.8, velocity: 3)
        }
    }

    /// The spring for the open panel going back into the notch: no bounce.
    ///
    /// The opening spring's little overshoot, played backwards, is the pill
    /// dipping *under* its own size before settling — measured at 1.9 pt
    /// short and 3.8 pt narrow, a third of a second in. The pill is the
    /// hardware cutout's height, so for those frames the real notch stuck
    /// out below it. Critically damped, it arrives and stops; a touch
    /// quicker than the opening, because leaving shouldn't be watched.
    var closeSpring: Animation {
        switch self {
        case .fast: .spring(response: 0.22, dampingFraction: 1)
        case .normal: .spring(response: 0.32, dampingFraction: 1)
        case .slow: .spring(response: 0.6, dampingFraction: 1)
        }
    }

    /// How long that spring takes to land, near enough. The window is cut
    /// down to the new shape only after this (`NotchPanelController.apply`),
    /// and whatever waits for a slide to finish waits this long. It was one
    /// fixed 0.55 s, right for the first two; the slow spring was still a few
    /// points out by then, and the window clipped them off.
    var settleTime: TimeInterval {
        switch self {
        case .fast, .normal: 0.55
        case .slow: 1.0
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
        case .album: L.t("From the album cover", "Podle obalu alba")
        case .white: L.t("White", "Bílá")
        case .custom: L.t("Custom", "Vlastní")
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
