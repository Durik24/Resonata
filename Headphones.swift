import CoreAudio
import Foundation

/// Tells Resonata when sound moves to Bluetooth headphones — the moment they
/// connect and macOS switches to them.
///
/// Read from Core Audio's default output device and its transport type: no
/// Bluetooth API, so no Bluetooth permission, and nothing is recorded — only
/// the device's name and kind are read. (Asking the Bluetooth framework for
/// connections would need its own permission prompt.)
@MainActor
final class OutputWatcher {
    static let shared = OutputWatcher()

    var onHeadphones: ((String) -> Void)?

    private var lastDevice: AudioObjectID?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        lastDevice = Self.defaultOutput()
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                            DispatchQueue.main) { _, _ in
            MainActor.assumeIsolated { OutputWatcher.shared.changed() }
        }
    }

    func changed() {
        guard let device = Self.defaultOutput(), device != lastDevice else { return }
        lastDevice = device
        if Self.isBluetooth(device), let name = Self.name(of: device) { onHeadphones?(name) }
    }

    /// The current output's name, for the debug trigger.
    static var currentName: String? { defaultOutput().flatMap(name(of:)) }

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func defaultOutput() -> AudioObjectID? {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func isBluetooth(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
        else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
