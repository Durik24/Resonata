import AppKit
import Combine
import IOKit
import IOKit.hid

/// A tap on the screen frame just left of the camera opens and closes the panel.
///
/// MacBook screens don't feel touch, so this reads two sensors that sit there
/// anyway: the ambient light sensor beside the camera goes dark under the
/// finger, and the accelerometer feels the small knock. Only both together,
/// within a fifth of a second, count — a hand passing over the screen darkens
/// the sensor without a knock, and typing or a tap on the desk knocks without
/// darkening it. The lid angle guards the rest: while the lid is moving, and
/// for three seconds after, nothing counts, since tilting the screen does both.
///
/// It needs some light in the room: with the sensor already near zero there
/// is no shadow to see, so in the dark the tap simply does nothing.
///
/// The sensors are read through IOKit's HID interface, the way macOS's own
/// sensor drivers publish them. That isn't a documented API for apps: a
/// future macOS can change the reports, and then the tap stops working —
/// the rest of Resonata doesn't depend on it.
@MainActor
final class NotchTap: ObservableObject {
    static let shared = NotchTap()

    enum State { case off, tooDark, ready }
    /// Whether a tap would work right now — for the line in Settings.
    @Published private(set) var state = State.off

    var onTap: (() -> Void)?

    /// `RESONATA_DEBUG_TAP=1` logs every tap and every near miss.
    nonisolated static let debug = ProcessInfo.processInfo.environment["RESONATA_DEBUG_TAP"] == "1"

    private var detector = TapDetector()
    private var manager: IOHIDManager?
    private var lidDevice: IOHIDDevice?
    private var lidTimer: Timer?
    private var statusTimer: Timer?
    private var counts: [Int: Int] = [:]
    private var savedLightInterval: Int?
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var running = false
    private var enabled = false
    private var asleep = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        // Nothing to do while the screen is off or the Mac is locked.
        let centre = NSWorkspace.shared.notificationCenter
        let pause: [NSNotification.Name] = [NSWorkspace.screensDidSleepNotification,
                                            NSWorkspace.willSleepNotification,
                                            NSWorkspace.sessionDidResignActiveNotification]
        let resume: [NSNotification.Name] = [NSWorkspace.screensDidWakeNotification,
                                             NSWorkspace.didWakeNotification,
                                             NSWorkspace.sessionDidBecomeActiveNotification]
        for name in pause {
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NotchTap.shared.asleep = true; NotchTap.shared.update() }
            })
        }
        // Quitting puts the light sensor's own rate back too.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if NotchTap.shared.running { NotchTap.shared.stop() } }
        })
        for name in resume {
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NotchTap.shared.asleep = false; NotchTap.shared.update() }
            })
        }
    }

    func setEnabled(_ on: Bool, sensitivity: TapSensitivity = Preferences.tapSensitivity) {
        detector.sensitivity = sensitivity
        guard on != enabled else { return }
        enabled = on
        update()
    }

    private func update() {
        let want = enabled && !asleep
        if want, !running { start() } else if !want, running { stop() }
    }

    // MARK: Sensors

    private func start() {
        running = true
        detector.reset()
        wakeSensors()

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3, kIOHIDTransportKey: "SPU"],  // accel
            [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 4, kIOHIDTransportKey: "SPU"],  // light
            [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A],                           // lid
        ] as CFArray)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        for device in devices {
            let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            if page == 0x20 { lidDevice = device; continue }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
            buffers.append(buffer)
            let context = UnsafeMutableRawPointer(bitPattern: usage)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 256, NotchTap.report, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        if Self.debug {
            NSLog("tap: started, \(devices.count) sensors\(lidDevice == nil ? ", no lid sensor" : "")")
        }

        // The lid angle has no stream of its own; ten looks a second is plenty.
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { NotchTap.shared.readLid() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lidTimer = timer
        if Self.debug {
            let status = Timer(timeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let tap = NotchTap.shared
                    NSLog("tap: status — \(tap.detector.statusLine), reports: light \(tap.counts[4, default: 0]), motion \(tap.counts[3, default: 0])")
                    tap.counts = [:]
                }
            }
            RunLoop.main.add(status, forMode: .common)
            statusTimer = status
        }
    }

    private func stop() {
        running = false
        state = .off
        lidTimer?.invalidate(); lidTimer = nil
        statusTimer?.invalidate(); statusTimer = nil
        if let manager {
            for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] {
                IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil; lidDevice = nil
        restoreLightSensor()
        buffers.forEach { $0.deallocate() }
        buffers = []
        if Self.debug { NSLog("tap: stopped") }
    }

    /// The accelerometer only streams while asked to. The light sensor
    /// always answers, but in daylight macOS has it answer five times a
    /// second; asked, it answers ten (its fastest), which halves the wait for
    /// the shadow. Its own rate is put back when the tap stops.
    private func wakeSensors() {
        forEachSensorDriver { service, name in
            if name == "accel" {
                IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, 1 as NSNumber)
                IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, 1 as NSNumber)
                IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, 10_000 as NSNumber)
            } else if name == "als" {
                let current = IORegistryEntryCreateCFProperty(service, "ReportInterval" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
                if let current, current > 0, savedLightInterval == nil { savedLightInterval = current }
                IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, 20_000 as NSNumber)
            }
        }
    }

    private func restoreLightSensor() {
        guard let saved = savedLightInterval else { return }
        savedLightInterval = nil
        forEachSensorDriver { service, name in
            if name == "als" {
                IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, saved as NSNumber)
            }
        }
    }

    private func forEachSensorDriver(_ body: (io_service_t, String?) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let name = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            body(service, name)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private static let report: IOHIDReportCallback = { context, _, _, _, _, bytes, length in
        let usage = Int(bitPattern: context)
        let raw = UnsafeRawPointer(bytes)
        func int32(_ offset: Int) -> Double { Double(raw.loadUnaligned(fromByteOffset: offset, as: Int32.self)) }
        let now = CACurrentMediaTime()
        MainActor.assumeIsolated {
            let tap = NotchTap.shared
            guard tap.running else { return }
            if NotchTap.debug { tap.counts[usage, default: 0] += 1 }
            switch usage {
            case 3 where length >= 18:
                // Three axes in 1/65536 g.
                tap.handle(tap.detector.accel(x: int32(6) / 65536, y: int32(10) / 65536,
                                              z: int32(14) / 65536, at: now), at: now)
            case 4 where length >= 36:
                // Four colour channels; their sum is how much light there is.
                tap.handle(tap.detector.light(int32(20) + int32(24) + int32(28) + int32(32), at: now), at: now)
                tap.updateState()
            default: break
            }
        }
    }

    /// Too dark below 15, light enough again from 25, so a room right at
    /// the edge doesn't flicker between the two.
    private func updateState() {
        guard let base = detector.baseline else { return }
        let next: State = base < 15 ? .tooDark : base >= 25 ? .ready : (state == .off ? .tooDark : state)
        if next != state { state = next }
    }

    private func readLid() {
        guard let lidDevice else { return }
        var buffer = [UInt8](repeating: 0, count: 16)
        var length = CFIndex(buffer.count)
        guard IOHIDDeviceGetReport(lidDevice, kIOHIDReportTypeFeature, 1, &buffer, &length) == kIOReturnSuccess,
              length >= 3 else { return }
        detector.lid(Double(UInt16(buffer[1]) | UInt16(buffer[2]) << 8), at: CACurrentMediaTime())
    }

    private func handle(_ verdict: TapDetector.Verdict, at time: Double) {
        if Self.debug { for miss in detector.takeMisses() { NSLog("tap: \(miss)") } }
        switch verdict {
        case .none: break
        case .tap:
            if Self.debug { NSLog("tap: TAP (\(detector.debugLine))") }
            onTap?()
        case .rejected(let reason):
            if Self.debug { NSLog("tap: ignored, \(reason) (\(detector.debugLine))") }
        }
    }
}

/// How hard a tap has to be, chosen in Settings.
enum TapSensitivity: String, CaseIterable, Identifiable {
    case gentle, standard, firm
    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle: L.t("Gentle", "Jemné")
        case .standard: L.t("Standard", "Běžné")
        case .firm: L.t("Firm", "Pevné")
        }
    }

    /// The smallest knock, in g, that counts.
    var bump: Double {
        switch self {
        // Gentle taps measured 0.002–0.006 g; at rest the sensor wanders
        // up to 0.002 g.
        case .gentle: 0.003
        case .standard: 0.0045
        case .firm: 0.007
        }
    }
}

/// The decision, kept apart from the sensors so it can be tested with numbers.
///
/// Measured on a MacBook Air M4: a fingertip on the frame left of the camera
/// takes the light sensor to a tenth of the room or less and knocks
/// 0.006–0.3 g; a hand over the screen dims it by 25–65% with no knock; a tap
/// on the desk or typing knocks without the shadow. A firm tap also wobbles
/// the lid by a degree or two, so only a bigger change counts as the lid
/// moving. The light sensor answers five to ten times a second, depending on
/// how bright the room is, so one shadow spans several readings.
struct TapDetector {
    enum Verdict: Equatable { case none, tap, rejected(String) }

    var sensitivity: TapSensitivity = .standard
    /// How much of the light the finger has to take away.
    var shadowDepth = 0.7
    /// The knock may come this long before or after the shadow, in seconds.
    var window = 0.3
    /// Below this the room is too dark to see a shadow.
    var minimumLight = 15.0
    /// The lid has moved when it turns this many degrees.
    var lidTurn = 4.0
    /// Nothing counts this long after the lid moves.
    var lidSettle = 2.0
    /// A tap can wait this long, so a hand that grabbed the lid to tilt it
    /// doesn't open the panel on the way. Off: waiting felt slow, and the lid
    /// guard after a tilt remains.
    var confirmDelay = 0.0
    /// Two taps closer than this are one.
    var debounce = 0.5

    private(set) var baseline: Double?
    private var gravity: (Double, Double, Double)?
    private var inShadow = false
    private var shadowStart = -Double.infinity
    private var shadowEnd = -Double.infinity
    private var shadowUsed = true
    private var lastBump = -Double.infinity
    private var lastTap = -Double.infinity
    private var pendingAt: Double?
    private var lidAngle: Double?
    private var lidCandidate: Double?
    private var lidReference: Double?
    private var lidMovedAt = -Double.infinity
    private var lastLight = 0.0, lastJolt = 0.0
    private var dimSince: Double?
    // For the debug log: each shadow that didn't become a tap, how dark it
    // got and the biggest knock around it.
    private var recentJolts: [(Double, Double)] = []
    private var episodeDarkest = 1.0
    private var episodeEndedAt: Double?
    private(set) var misses: [String] = []
    mutating func takeMisses() -> [String] { defer { misses = [] }; return misses }

    mutating func reset() { self = TapDetector(sensitivity: sensitivity) }

    init(sensitivity: TapSensitivity = .standard) { self.sensitivity = sensitivity }

    var statusLine: String {
        let base = baseline ?? -1
        let dark = base < minimumLight ? " — TOO DARK, taps off" : ""
        return String(format: "room light %.0f%@, lid %.0f°", base, dark, lidAngle ?? -1)
    }

    var debugLine: String {
        String(format: "light %.0f of %.0f, knock %.4f g", lastLight, baseline ?? -1, lastJolt)
    }

    mutating func light(_ level: Double, at time: Double) -> Verdict {
        lastLight = level
        guard let base = baseline else { baseline = level; return .none }
        let shadow = base > 0 ? 1 - level / base : 0
        if shadow >= shadowDepth, base >= minimumLight {
            if !inShadow {                       // the finger arrives
                inShadow = true
                shadowStart = time
                shadowUsed = false
                episodeDarkest = 1
            }
            shadowEnd = time
            episodeDarkest = min(episodeDarkest, level / base)
        } else if shadow < shadowDepth * 0.6 {
            if inShadow { episodeEndedAt = time }
            inShadow = false                     // and has gone
        }
        if level > base {
            baseline = base + (level - base) * 0.5          // brighter: catch up quickly
            dimSince = nil
        } else if shadow < 0.25 {
            baseline = base + (level - base) * 0.1          // follow the room, never the finger
            dimSince = nil
        } else if let since = dimSince {
            // Darker for this long is the room, not a finger: a lamp went off.
            if time - since > 3 { baseline = level; dimSince = nil; inShadow = false }
        } else {
            dimSince = time
        }
        return decide(at: time)
    }

    mutating func accel(x: Double, y: Double, z: Double, at time: Double) -> Verdict {
        guard let g = gravity else { gravity = (x, y, z); return .none }
        let k = 0.05
        let next = (g.0 + (x - g.0) * k, g.1 + (y - g.1) * k, g.2 + (z - g.2) * k)
        gravity = next
        let dx = x - next.0, dy = y - next.1, dz = z - next.2
        let jolt = (dx * dx + dy * dy + dz * dz).squareRoot()
        lastJolt = jolt
        if jolt >= sensitivity.bump { lastBump = time }
        recentJolts.append((time, jolt))
        if recentJolts.count > 150 { recentJolts.removeFirst(recentJolts.count - 150) }
        if let ended = episodeEndedAt, time - ended > window {
            episodeEndedAt = nil
            if !shadowUsed {
                shadowUsed = true
                let knock = recentJolts.filter { $0.0 >= shadowStart - window && $0.0 <= shadowEnd + window }
                    .map(\.1).max() ?? 0
                misses.append(String(format: "missed a shadow: darkest %.0f%% of the room, biggest knock %.4f g (needs %.3f)",
                                     episodeDarkest * 100, knock, sensitivity.bump))
            }
        }
        return decide(at: time)
    }

    mutating func lid(_ angle: Double, at time: Double) {
        // One reading on its own can be nonsense (a jump of 100°); two in a
        // row that agree are the lid. A quick tilt turns it 2–6° a reading.
        defer { lidCandidate = angle }
        guard let candidate = lidCandidate, abs(angle - candidate) <= 10 else { return }
        lidAngle = angle
        guard let reference = lidReference else { lidReference = angle; return }
        if abs(angle - reference) >= lidTurn {
            lidMovedAt = time
            lidReference = angle
        }
    }

    private mutating func decide(at time: Double) -> Verdict {
        // A tap found a moment ago: let it through unless the lid started moving.
        if let pending = pendingAt, time - pending >= confirmDelay {
            pendingAt = nil
            if lidMovedAt >= pending - 0.15 { return .rejected("the lid started moving") }
            lastTap = pending
            return .tap
        }
        guard !shadowUsed, pendingAt == nil,
              lastBump >= shadowStart - window, lastBump <= shadowEnd + window else { return .none }
        shadowUsed = true
        if time - lidMovedAt < lidSettle { return .rejected("the lid moved") }
        if let angle = lidAngle, angle < 30 { return .rejected("the lid is nearly closed") }
        if time - lastTap < debounce { return .rejected("too soon after the last tap") }
        pendingAt = time
        return .none
    }
}
