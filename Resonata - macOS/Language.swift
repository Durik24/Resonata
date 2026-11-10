import Foundation

/// The interface's language, as chosen in Settings. `system` follows the Mac:
/// Czech on a Czech Mac, English on any other.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, czech

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L.t("Same as the Mac", "Podle Macu")
        case .english: "English"
        case .czech: "Čeština"
        }
    }
}

/// The interface's two languages, side by side where each string is used —
/// the same way the Windows version keeps them (`L.T` there).
///
/// Decided once, at launch: a change in Settings counts from the next start,
/// which is what the picker says. Deciding per string would leave a panel
/// half in one language until every view had happened to redraw.
enum L {

    /// The interface is in Czech. Settable, so the tests can pin it down
    /// whatever language the Mac they run on speaks.
    nonisolated(unsafe) static var isCzech: Bool = usesCzech(
        setting: UserDefaults.standard.string(forKey: Preferences.Key.language),
        preferred: Locale.preferredLanguages)

    /// `english` or `czech`, whichever the interface is in.
    static func t(_ english: String, _ czech: String) -> String {
        isCzech ? czech : english
    }

    /// For dates and times. British English rather than American: a 24-hour
    /// clock and the day before the month, as the Czech has them.
    static var locale: Locale { Locale(identifier: isCzech ? "cs_CZ" : "en_GB") }

    /// Czech when it's chosen, English when that is; left to the Mac, Czech
    /// only where Czech is the first language in System Settings.
    static func usesCzech(setting: String?, preferred: [String]) -> Bool {
        switch AppLanguage(rawValue: setting ?? "") ?? .system {
        case .czech: true
        case .english: false
        case .system: preferred.first?.lowercased().hasPrefix("cs") == true
        }
    }

    /// "+ 3 more" under a list cut short.
    static func more(_ count: Int) -> String { more(count, czech: isCzech) }

    /// Czech counts differently from five up: 2 další, but 5 dalších.
    static func more(_ count: Int, czech: Bool) -> String {
        guard czech else { return "+ \(count) more" }
        return "+ \(count) \(count >= 5 ? "dalších" : "další")"
    }
}
