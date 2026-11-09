import Foundation
import ServiceManagement

/// Resonata's entry in System Settings › General › Login Items.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            NSLog("Resonata: open at login %@ (status %ld)", enabled ? "on" : "off",
                  SMAppService.mainApp.status.rawValue)
            return true
        } catch {
            NSLog("Resonata: could not change open-at-login: \(error)")
            return false
        }
    }
}
