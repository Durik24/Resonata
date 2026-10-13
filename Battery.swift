import Foundation
import IOKit.ps

/// The internal battery's charge, for the open panel's top bar. Read straight
/// from IOKit's power-source list — no permission, no polling of its own; the
/// panel asks while it is open. Nil on a Mac without a battery.
struct Battery: Equatable {
    var percent: Int
    var charging: Bool
    /// On the charger, whether or not it's charging right now — a full
    /// battery on the charger isn't charging, but it is plugged in.
    var onPower = false

    static func read() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            // On the charger counts as charging — the bolt is what the menu
            // bar shows then too, even when it's sitting at 100%.
            let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return Battery(percent: min(100, current * 100 / max),
                           charging: plugged || d[kIOPSIsChargingKey] as? Bool == true,
                           onPower: plugged)
        }
        return nil
    }

    /// The SF Symbol for this level, in the quarters SF Symbols has.
    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var isLow: Bool { !charging && percent <= 20 }
}

/// Tells Resonata when the Mac is plugged in. IOKit's power-source
/// notification, delivered on the main run loop, so nothing polls: it fires
/// when the power source or the charge changes, and only a change from
/// battery to charger counts.
@MainActor
final class PowerWatcher {
    static let shared = PowerWatcher()

    var onPlugIn: ((Battery) -> Void)?

    private var source: CFRunLoopSource?
    private var wasOnPower: Bool?

    func start() {
        guard source == nil else { return }
        wasOnPower = Battery.read()?.onPower
        guard let src = IOPSNotificationCreateRunLoopSource(powerSourcesChanged, nil)?
            .takeRetainedValue() else { return }
        // Common modes, not just the default: in the default mode alone the
        // notice waits while a menu is open — the notch's own right-click
        // menu, say.
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
    }

    func changed() {
        guard let battery = Battery.read() else { return }
        defer { wasOnPower = battery.onPower }
        if Self.isPlugIn(was: wasOnPower, now: battery.onPower) { onPlugIn?(battery) }
    }

    /// Battery to charger, and nothing else: the notice also fires as the
    /// charge ticks up or down, and on launch the state isn't a change.
    nonisolated static func isPlugIn(was: Bool?, now: Bool) -> Bool {
        was == false && now
    }
}

/// IOKit wants a plain C function; it's called on the main run loop.
private func powerSourcesChanged(_ context: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated { PowerWatcher.shared.changed() }
}
