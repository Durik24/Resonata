import AudioToolbox
import CoreAudio
import Foundation

/// Listens to the playing app's sound through a Core Audio process tap.
///
/// The replacement for ScreenCaptureKit, for three reasons:
///
/// - **Permission.** A tap needs "System Audio Recording Only", not Screen
///   Recording. No dialog about recording the screen, and nothing that ever
///   could.
/// - **Only the music.** The tap is aimed at the processes of the app that
///   is playing, so notification sounds and calls don't move the bars.
/// - **No display.** ScreenCaptureKit attaches every stream to a display,
///   and unplugging that display killed it. A tap is pure audio.
///
/// It also taps *before* the output device's volume and mute, so the bars
/// keep moving when the Mac is muted or turned right down.
///
/// The machinery: a tap description names the processes; Core Audio turns it
/// into a tap object; a private aggregate device wraps the tap so it can be
/// read like an input; an IO block on `audioQueue` receives the buffers.
@available(macOS 14.2, *)
final class ProcessTapSpectrum: SpectrumCapture, @unchecked Sendable {

    @MainActor private var tap = AudioObjectID(kAudioObjectUnknown)
    @MainActor private var aggregate = AudioObjectID(kAudioObjectUnknown)
    @MainActor private var ioProc: AudioDeviceIOProcID?

    /// Capture should be running — cleared only by `stop()`.
    @MainActor private var wantsRunning = false
    /// Bundle ID of the app to listen to; nil for the whole system.
    @MainActor private var targetBundleID: String?
    /// The processes the running tap covers; empty means it's global.
    @MainActor private var tapped: [AudioObjectID] = []
    @MainActor private var listening = false
    /// Audio queue only: whether the first buffer has been logged.
    private var loggedFirstBuffer = false

    override func start() {
        Task { @MainActor in
            wantsRunning = true
            installListeners()
            if aggregate == kAudioObjectUnknown { startTap() }
        }
    }

    override func stop() {
        Task { @MainActor in
            wantsRunning = false
            teardown()
            clear()
        }
    }

    override func retarget(bundleID: String?) {
        Task { @MainActor in
            guard bundleID != targetBundleID else { return }
            targetBundleID = bundleID
            refresh()
        }
    }

    /// Rebuilds the tap if the processes it should cover have changed — a
    /// different app took over, or the app started or ended a helper process
    /// (browsers play sound from one).
    @MainActor private func refresh() {
        guard wantsRunning, aggregate != kAudioObjectUnknown else { return }
        let wanted = Self.processes(of: targetBundleID)
        guard Set(wanted) != Set(tapped) else { return }
        teardown()
        startTap()
    }

    @MainActor private func startTap() {
        let processes = Self.processes(of: targetBundleID)
        // An app with no audio process yet — or one whose sound comes from a
        // process we can't attribute — falls back to the whole system rather
        // than to silence.
        let description = processes.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcess().map { [$0] } ?? [])
            : CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Resonata"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            NSLog("Resonata: could not create the audio tap (%d)", status)
            return
        }

        guard let outputUID = Self.defaultOutputUID() else {
            AudioHardwareDestroyProcessTap(tapID)
            return
        }
        // Private, so it never appears in anyone's sound settings; clocked by
        // the real output device; the tap is its only input.
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Resonata Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
        aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else {
            NSLog("Resonata: could not create the tap's device (%d)", status)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        guard let format = Self.format(of: tapID),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else {
            NSLog("Resonata: the tap's audio format isn't 32-bit float")
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(format.mChannelsPerFrame)
        audioQueue.sync { prepareAnalyzer(sampleRate: format.mSampleRate) }

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, audioQueue) {
            [weak self] _, input, _, _, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if !self.loggedFirstBuffer {
                self.loggedFirstBuffer = true
                NSLog("Resonata: first tap buffer: %d buffer(s), %u bytes",
                      list.count, list.first?.mDataByteSize ?? 0)
            }
            self.ingest(list, interleaved: interleaved, channelsPerFrame: channels)
        }
        guard status == noErr, let procID else {
            NSLog("Resonata: could not attach to the tap (%d)", status)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            NSLog("Resonata: could not start the tap (%d)", status)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        tap = tapID
        aggregate = aggregateID
        ioProc = procID
        tapped = processes
        if ProcessInfo.processInfo.environment["RESONATA_DEBUG_TAP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.logDiagnostics(outputUID: outputUID) }
            }
        }
        NSLog("Resonata: listening to %@ (%.0f Hz, %d ch, %@)",
              processes.isEmpty ? "the whole system" : "\(targetBundleID ?? "?") (\(processes.count) process(es))",
              format.mSampleRate, channels, interleaved ? "interleaved" : "planar")
    }

    /// `RESONATA_DEBUG_TAP=1`: the tap device's state, two seconds in.
    ///
    /// `running=0` with nothing playing is normal: a tap idles until the
    /// processes it covers make sound, and costs nothing meanwhile.
    @MainActor private func logDiagnostics(outputUID: String) {
        func u32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Int {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? Int(value) : -1
        }
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(aggregate, &streams, 0, nil, &size)
        NSLog("tap diag: output=%@ alive=%d running=%d runningSomewhere=%d inputStreams=%d buffered=%@",
              outputUID, u32(aggregate, kAudioDevicePropertyDeviceIsAlive),
              u32(aggregate, kAudioDevicePropertyDeviceIsRunning),
              u32(aggregate, kAudioDevicePropertyDeviceIsRunningSomewhere),
              Int(size) / MemoryLayout<AudioStreamID>.size,
              audioQueue.sync { loggedFirstBuffer ? "yes" : "no" })
    }

    @MainActor private func teardown() {
        if let ioProc, aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        ioProc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
        tapped = []
    }

    /// Two things can make a running tap wrong: the target app's processes
    /// coming and going, and the output device changing — headphones plugged
    /// in — which the aggregate is clocked by.
    @MainActor private func installListeners() {
        guard !listening else { return }
        listening = true
        let system = AudioObjectID(kAudioObjectSystemObject)

        var processList = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(system, &processList, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        var output = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(system, &output, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsRunning, self.aggregate != kAudioObjectUnknown else { return }
                self.teardown()
                self.startTap()
            }
        }
    }

    // MARK: Finding processes

    /// Whether a process belongs to the app with `bundleID`.
    ///
    /// Its own process, or any helper whose bundle ID extends it — Chrome
    /// plays sound from `com.google.Chrome.helper`, Electron apps from
    /// `….helper` processes. Safari is the exception: WebKit plays every
    /// page's sound from one shared `com.apple.WebKit.GPU` process.
    static func belongs(_ processBundleID: String, to bundleID: String) -> Bool {
        processBundleID == bundleID
            || processBundleID.hasPrefix(bundleID + ".")
            || (bundleID == "com.apple.Safari" && processBundleID == "com.apple.WebKit.GPU")
    }

    static func processes(of bundleID: String?) -> [AudioObjectID] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        return allProcesses().filter { process in
            guard let id = string(process, kAudioProcessPropertyBundleID) else { return false }
            return belongs(id, to: bundleID)
        }
    }

    private static func allProcesses() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    /// This app's own process object, excluded from a global tap. It makes no
    /// sound today; this keeps it from ever analysing itself if it does.
    private static func ownProcess() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
        return status == noErr && process != kAudioObjectUnknown ? process : nil
    }

    private static func defaultOutputUID() -> String? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func format(of tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr ? format : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
