import Carbon
import Foundation

/// The shortcuts the settings window offers.
///
/// A fixed list rather than "press any keys": a recorder would happily accept
/// combinations macOS or the keyboard layout already use. These were picked
/// to avoid the defaults — not ⌥Space (types a non-breaking space), not
/// ⌃Space or ⌃⌥Space (switch input source on a Czech keyboard), not ⌥⌘Space
/// (Finder search) or ⌃⌘Space (emoji).
enum HotKeyChoice: String, CaseIterable, Identifiable {
    case off
    case shiftCommandSpace
    case controlOptionCommandN

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Vypnuto"
        case .shiftCommandSpace: "⇧⌘ Mezerník"
        case .controlOptionCommandN: "⌃⌥⌘ N"
        }
    }

    /// Carbon key code and modifier mask, or nil for off.
    var combo: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .off: nil
        case .shiftCommandSpace: (UInt32(kVK_Space), UInt32(shiftKey | cmdKey))
        case .controlOptionCommandN: (UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey | cmdKey))
        }
    }
}

/// A system-wide shortcut that opens and closes the notch.
///
/// Carbon's hot-key API is old, but it is the one way to get a global
/// shortcut on macOS without the Accessibility permission — an event tap or a
/// global key monitor needs it, and an ad-hoc-signed app kept losing it.
final class HotKey {
    nonisolated(unsafe) static let shared = HotKey()

    /// Run on the main queue when the shortcut is pressed.
    var action: (() -> Void)?

    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Registers `choice`, replacing any previous one. Returns false when the
    /// combination is already taken by another app.
    @discardableResult
    func apply(_ choice: HotKeyChoice) -> Bool {
        if let registration {
            UnregisterEventHotKey(registration)
            self.registration = nil
        }
        guard let combo = choice.combo else { return true }
        installHandler()
        let id = EventHotKeyID(signature: 0x524E_5441 /* 'RNTA' */, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                         GetApplicationEventTarget(), 0, &registration)
        if status != noErr {
            NSLog("Resonata: shortcut %@ unavailable (%d)", choice.title, status)
            registration = nil
            return false
        }
        return true
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        // A C callback can't capture anything, which is why this is a
        // singleton the callback can reach.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.action?() }
            return noErr
        }, 1, &pressed, nil, &handler)
    }
}
