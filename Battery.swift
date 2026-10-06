import Foundation
import IOKit.ps

/// The internal battery's charge, for the open panel's top bar. Read straight
/// from IOKit's power-source list — no permission, no polling of its own; the
/// panel asks while it is open. Nil on a Mac without a battery.
struct Battery: Equatable {
    var percent: Int
    var charging: Bool

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
                           charging: plugged || d[kIOPSIsChargingKey] as? Bool == true)
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
