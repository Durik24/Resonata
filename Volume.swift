import AudioToolbox
import CoreAudio

/// The Mac's output volume, read and set directly through Core Audio.
///
/// Not AppleScript's `set volume`: that spins up a scripting component on
/// every scroll event. Not posting volume-key events either: that needs
/// Accessibility permission, which an ad-hoc-signed app keeps losing. Core
/// Audio needs no permission at all.
enum SystemVolume {

    /// Current level, 0...1, of the default output device — 0 when muted.
    /// Nil when the device has no volume control (HDMI, some AirPlay).
    static var level: Float? {
        guard let device = defaultOutputDevice(), let volume = volume(of: device) else { return nil }
        return isMuted(device) == true ? 0 : volume
    }

    /// Nudges the volume by `delta` and returns the level now in effect.
    ///
    /// Turning it *up* also unmutes: scrolling up on a muted Mac and hearing
    /// nothing reads as the control being broken.
    @discardableResult
    static func change(by delta: Float) -> Float? {
        guard let device = defaultOutputDevice(), let current = volume(of: device) else { return nil }
        let target = min(max(current + delta, 0), 1)
        guard setVolume(target, of: device) else { return nil }
        if delta > 0, isMuted(device) == true { setMuted(false, device) }
        return isMuted(device) == true ? 0 : target
    }

    /// Volume change for one scroll event.
    ///
    /// Up is louder — a wheel rolled away, or fingers moving up — whatever
    /// the user's natural-scrolling setting, which is why the device direction
    /// is recovered from `inverted` first. A trackpad reports points (a calm
    /// two-finger swipe is ~25 of them, worth 10%); a mouse wheel reports
    /// lines, each a sixteenth — the step the volume keys use. Capped per
    /// event so a flung wheel can't jump from quiet to full in one go.
    static func scrollDelta(deltaY: Double, precise: Bool, inverted: Bool) -> Double {
        let physical = inverted ? -deltaY : deltaY
        let raw = precise ? physical * 0.004 : physical * 0.0625
        return min(max(raw, -0.125), 0.125)
    }

    // MARK: Core Audio

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// The "virtual main" volume is the one the menu bar slider moves: a
    /// single value for the device, however many channels it has.
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static func volume(of device: AudioObjectID) -> Float? {
        guard AudioObjectHasProperty(device, &volumeAddress) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// Whether the volume can be set at all — false for fixed-level outputs.
    static var isAdjustable: Bool {
        guard let device = defaultOutputDevice(), AudioObjectHasProperty(device, &volumeAddress)
        else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr
            && settable.boolValue
    }

    private static func setVolume(_ value: Float, of device: AudioObjectID) -> Bool {
        var value = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, size, &value) == noErr
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool? {
        guard AudioObjectHasProperty(device, &muteAddress) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    private static func setMuted(_ muted: Bool, _ device: AudioObjectID) {
        guard AudioObjectHasProperty(device, &muteAddress) else { return }
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &muteAddress, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
