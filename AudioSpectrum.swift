import Accelerate
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import os

/// A live frequency-domain view of whatever the machine is actually playing.
///
/// The point of this protocol is the same as `NowPlayingSource`'s: the thing
/// that produces the numbers is expected to be replaced. ScreenCaptureKit is
/// the backend that works everywhere today; Core Audio process taps
/// (`AudioHardwareCreateProcessTap`, macOS 14.4+) can tap a single application
/// instead of the whole machine, and swapping to one is meant to leave the DSP
/// and the UI untouched.
protocol AudioSpectrumSource: AnyObject {
    /// Band magnitudes, 0...1, lowest frequency first. Safe to read from any
    /// thread; returns an empty array before the first frame has been analysed.
    var bands: [Float] { get }

    /// Whether anything audible is coming out of the machine right now.
    ///
    /// Coarse and slow on purpose — it only decides whether the UI runs its
    /// animation clock, and it is the one piece of this that *is* worth
    /// publishing through Combine.
    var hasSignal: Bool { get }

    /// Counts up by one on every detected beat. A count rather than a flag so
    /// that two beats close together are two changes, not one; the view keys
    /// its pulse off the value changing, never off the value itself.
    var beat: Int { get }

    func start()
    func stop()

    /// The app whose sound should be analysed, by bundle ID — nil for
    /// everything. Backends that can't tell apps apart ignore it.
    func retarget(bundleID: String?)
}

extension AudioSpectrumSource {
    func retarget(bundleID: String?) {}
}

// MARK: - The DSP

/// One analysed window of audio.
struct SpectrumFrame {
    /// Smoothed band magnitudes, 0...1, lowest frequency first.
    var bands: [Float]
    /// A beat landed in this window.
    var beat: Bool
}

/// Turns a stream of PCM samples into normalised, smoothed band magnitudes.
///
/// Deliberately knows nothing about where the samples came from. Everything in
/// here is confined to one queue by its owner — none of it is thread-safe on
/// its own, and it doesn't try to be.
final class SpectrumAnalyzer {

    /// Window length. 2048 samples at 48 kHz is a 43 ms window and ~23 Hz per
    /// bin — fine enough to separate a bass line from a kick drum, short enough
    /// that the bars still feel attached to the music. Must be a power of two:
    /// `vDSP_fft_zrip` is radix-2.
    static let fftSize = 2048

    /// How many bars the spectrum is reduced to.
    let bandCount: Int

    /// Anything below this is inaudible rumble or DC offset; anything above it
    /// is mostly cymbals and hiss. Confining the range to what music actually
    /// occupies is what stops the top third of the bars from sitting dead.
    private static let minHz = 40.0
    private static let maxHz = 16_000.0

    /// dB window mapped onto 0...1. Digital full scale is 0 dB, so everything
    /// here is negative. -68 puts the noise floor at rest and -12 leaves a
    /// little headroom before a loud mix pins every bar to the ceiling.
    private static let floorDb: Float = -68
    private static let ceilingDb: Float = -12

    /// Rise fast, fall slow.
    ///
    /// Symmetric smoothing forces a choice between bars that lag the beat and
    /// bars that flicker. Splitting the two lets a transient hit its full height
    /// immediately and then fall away smoothly, which is what reads as "moving
    /// with the music" rather than as noise.
    private static let attack: Float = 0.55
    private static let release: Float = 0.13

    // Beat detection.
    //
    // Energy-based, which is the simple approach and the right one here: this
    // isn't trying to find the tempo, only to notice each kick as it lands.
    // The instantaneous energy in the low bands is compared to its own recent
    // average; a beat is a frame that stands well clear of that average.

    /// Bands that count as "low". With 32 bands from 40 Hz to 16 kHz, these
    /// cover roughly 58–215 Hz: the kick drum and the bass, and nothing else.
    /// Band 0 and 1 are skipped — sub-bass rumble is constant in most mixes and
    /// only raises the average without ever being the beat.
    private static let beatBands = 2..<9

    /// How much recent history the average is taken over, in frames. 40 frames
    /// at ~21 ms is a little under a second — long enough to span a full beat
    /// cycle at any tempo, short enough to follow a change in dynamics.
    private static let beatHistory = 40

    /// A frame must exceed the running average by this factor to be a beat...
    private static let beatRatio: Float = 1.32
    /// ...and by at least this much in absolute terms, so a whisper-quiet
    /// passage doesn't fire on its own noise floor...
    private static let beatMinimumRise: Float = 0.07
    /// ...and no two beats can land closer than this. 160 ms is 375 BPM, well
    /// past anything musical; it exists to stop one kick's decay counting twice.
    ///
    /// Measured in *samples*, not wall-clock time. ScreenCaptureKit can hand
    /// over several queued buffers at once, and timed by the clock on the wall
    /// those arrive "simultaneously" — every beat in the burst after the first
    /// was thrown away. The audio's own clock doesn't care when it was delivered.
    private static let beatRefractory: TimeInterval = 0.16

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    /// Internal for `Tests/`, which checks the spacing.
    let bandRanges: [Range<Int>]

    /// The most recent `fftSize` samples, oldest first.
    private var ring: [Float]
    /// How much of `ring` is real audio rather than the zeros it started as.
    private var filled = 0

    private var window: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]
    private var smoothed: [Float]

    /// Unsmoothed band levels for the current frame. Beat detection reads these
    /// rather than `smoothed`: the release smoothing that makes the bars fall
    /// gracefully also flattens exactly the transient a beat is.
    private var instant: [Float]

    private var energyHistory: [Float]
    private var energyIndex = 0
    private var energyFilled = 0

    private let sampleRate: Double
    /// Samples seen since start — the audio clock beats are timed on.
    private var samplesSeen = 0
    private var lastBeatSample = Int.min / 2

    init?(bandCount: Int, sampleRate: Double) {
        let n = Self.fftSize
        self.bandCount = bandCount
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(log2(Double(n)))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.fftSetup = setup

        self.ring = [Float](repeating: 0, count: n)
        self.windowed = [Float](repeating: 0, count: n)
        self.realp = [Float](repeating: 0, count: n / 2)
        self.imagp = [Float](repeating: 0, count: n / 2)
        self.magnitudes = [Float](repeating: 0, count: n / 2)
        self.smoothed = [Float](repeating: 0, count: bandCount)
        self.instant = [Float](repeating: 0, count: bandCount)
        self.energyHistory = [Float](repeating: 0, count: Self.beatHistory)

        // Hann, to stop a note that doesn't fit a whole number of times into the
        // window from smearing its energy across every bin (spectral leakage).
        // Without it a steady tone lights up the entire spectrum faintly, and
        // the bars all move together.
        self.window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        self.bandRanges = Self.bandRanges(
            bandCount: bandCount, fftSize: n, sampleRate: sampleRate
        )
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Bin ranges for each band, spaced logarithmically.
    ///
    /// Linear spacing is the classic mistake. Half of a linear spectrum covers
    /// 12 kHz upwards, where music has almost nothing, so the right-hand bars
    /// never move and everything interesting is crushed into the first two. We
    /// hear pitch logarithmically — an octave is a doubling — so the bands have
    /// to be spaced the same way for the display to look like the music sounds.
    private static func bandRanges(
        bandCount: Int, fftSize: Int, sampleRate: Double
    ) -> [Range<Int>] {
        let binCount = fftSize / 2
        let hzPerBin = sampleRate / Double(fftSize)
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(bandCount)

        for i in 0..<bandCount {
            let ratio = maxHz / minHz
            let lo = minHz * pow(ratio, Double(i) / Double(bandCount))
            let hi = minHz * pow(ratio, Double(i + 1) / Double(bandCount))

            // Bin 0 is DC — a constant offset, not a frequency — and including
            // it makes the first bar respond to silence.
            var loBin = max(1, Int(lo / hzPerBin))
            var hiBin = Int(hi / hzPerBin)
            loBin = min(loBin, binCount - 1)
            // The lowest bands are narrower than one bin. Widening them to at
            // least one keeps every bar backed by real data instead of leaving
            // the bottom of the spectrum permanently flat.
            hiBin = min(max(hiBin, loBin + 1), binCount)
            ranges.append(loBin..<hiBin)
        }
        return ranges
    }

    /// Feeds `count` mono samples in and returns new bands once there is a full
    /// window to transform. Returns nil until then.
    func process(_ samples: UnsafePointer<Float>, count: Int) -> SpectrumFrame? {
        ingest(samples, count: count)
        guard filled >= Self.fftSize else { return nil }
        let bands = analyse()
        return SpectrumFrame(bands: bands, beat: detectBeat())
    }

    /// Slides the newest samples into the ring, dropping the oldest.
    private func ingest(_ samples: UnsafePointer<Float>, count: Int) {
        let n = Self.fftSize
        let bytes = MemoryLayout<Float>.size

        ring.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            if count >= n {
                // A buffer bigger than the window: only its tail can matter.
                memcpy(base, samples + (count - n), n * bytes)
            } else {
                let keep = n - count
                memmove(base, base + count, keep * bytes)
                memcpy(base + keep, samples, count * bytes)
            }
        }
        filled = min(filled + count, n)
        samplesSeen += count
    }

    private func analyse() -> [Float] {
        let n = Self.fftSize
        let half = n / 2

        // 1. Window the samples.
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // 2. Pack the real signal into split-complex form, which is the only
        //    layout the real-to-complex FFT accepts: `vDSP_ctoz` reads pairs of
        //    adjacent reals as (real, imaginary).
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(
                    realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!
                )
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: half
                    ) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }

                // 3. Forward FFT, in place.
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                // 4. Magnitude of each bin. `vDSP_zvabs` gives |z| directly;
                //    the 1/n corrects `vDSP_fft_zrip`'s internal scaling so the
                //    dB values below are comparable to full scale.
                magnitudes.withUnsafeMutableBufferPointer { mags in
                    vDSP_zvabs(&split, 1, mags.baseAddress!, 1, vDSP_Length(half))
                    var scale = Float(1) / Float(n)
                    vDSP_vsmul(mags.baseAddress!, 1, &scale,
                               mags.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // 5. Collapse bins into bands, convert to dB, normalise, smooth.
        var out = [Float](repeating: 0, count: bandCount)
        for (i, range) in bandRanges.enumerated() {
            // Peak rather than mean across the band. A mean dilutes a sharp
            // transient across whatever else sits in the same band and leaves
            // the bars looking sluggish; a peak keeps the attack.
            var peak: Float = 0
            magnitudes.withUnsafeBufferPointer { mags in
                vDSP_maxv(mags.baseAddress! + range.lowerBound, 1, &peak,
                          vDSP_Length(range.count))
            }

            let db = 20 * log10f(max(peak, 1e-9))
            let normalised = (db - Self.floorDb) / (Self.ceilingDb - Self.floorDb)
            let clamped = min(max(normalised, 0), 1)
            instant[i] = clamped

            let previous = smoothed[i]
            let rate = clamped > previous ? Self.attack : Self.release
            smoothed[i] = previous + (clamped - previous) * rate
            out[i] = smoothed[i]
        }
        return out
    }

    /// Whether the frame just analysed is a beat.
    private func detectBeat() -> Bool {
        let range = Self.beatBands.clamped(to: 0..<bandCount)
        guard !range.isEmpty else { return false }

        var energy: Float = 0
        for i in range { energy += instant[i] }
        energy /= Float(range.count)

        // The average is of the frames *before* this one — comparing a frame
        // against a history that already contains it dulls every peak.
        let average: Float
        if energyFilled > 0 {
            var sum: Float = 0
            for i in 0..<energyFilled { sum += energyHistory[i] }
            average = sum / Float(energyFilled)
        } else {
            average = energy
        }

        energyHistory[energyIndex] = energy
        energyIndex = (energyIndex + 1) % Self.beatHistory
        energyFilled = min(energyFilled + 1, Self.beatHistory)

        // Needs most of a beat cycle of history before it can say anything.
        guard energyFilled >= Self.beatHistory / 2 else { return false }

        let refractory = Int(Self.beatRefractory * sampleRate)
        guard samplesSeen - lastBeatSample > refractory,
              energy > average * Self.beatRatio,
              energy - average > Self.beatMinimumRise
        else { return false }

        lastBeatSample = samplesSeen
        return true
    }
}

// MARK: - Shared capture core

/// Everything a capture backend has in common: the analyser, the newest
/// frame, and the coarse signal and beat events. A backend only delivers
/// buffers to `ingest`, always on `audioQueue`.
///
/// `@unchecked Sendable` is a claim about specific things, not a shrug:
/// `analyzer`, `mono`, the signal tracking and the debug counters are only
/// touched on `audioQueue`; `latest` is behind a lock; the published values
/// are only written on the main actor.
class SpectrumCapture: NSObject, ObservableObject, AudioSpectrumSource, @unchecked Sendable {

    /// The newest analysed frame.
    ///
    /// Deliberately *not* `@Published`. The analyser produces a frame roughly
    /// every 20 ms, and pushing each one through Combine would re-render the
    /// notch at that rate whether or not anything was on screen to see it. The
    /// views have clocks of their own and pull the latest frame when they draw.
    private let latest = OSAllocatedUnfairLock<[Float]>(initialState: [])

    var bands: [Float] { latest.withLock { $0 } }

    /// Published, unlike `bands`, because it changes a handful of times a
    /// minute — and because it decides whether a view's clock runs at all.
    @Published private(set) var hasSignal = false

    /// See `AudioSpectrumSource.beat`.
    @Published private(set) var beat = 0

    /// Anything above this counts as audible. Set above the noise the analyser
    /// reports for true digital silence, and below a quiet passage.
    private static let signalThreshold: Float = 0.06

    private var signalState = false
    private var signalChangedAt: CFAbsoluteTime = 0

    /// Run with `RESONATA_DEBUG_BANDS=1` to print the spectrum to stdout twice
    /// a second. Tuning the dB window by eye, on bars thirty points tall
    /// behind a hardware cutout, is guesswork; this makes the numbers visible.
    private static let debugBands =
        ProcessInfo.processInfo.environment["RESONATA_DEBUG_BANDS"] == "1"
    private var lastBandPrint: CFAbsoluteTime = 0
    private var beatsSincePrint = 0

    let bandCount: Int
    private var analyzer: SpectrumAnalyzer?
    private var analyzerRate: Double = 0

    let audioQueue = DispatchQueue(label: "com.local.resonata.audio", qos: .userInitiated)

    /// Scratch space for the channel mix, grown once and reused. Allocating a
    /// buffer inside an audio callback is the classic way to make one late.
    private var mono: [Float] = []

    init(bandCount: Int) {
        self.bandCount = bandCount
        super.init()
    }

    func start() { fatalError("subclass") }
    func stop() { fatalError("subclass") }
    func retarget(bundleID: String?) {}

    /// Builds the analyser for `sampleRate`, keeping the existing one when the
    /// rate hasn't changed. Audio queue only — or before audio flows.
    func prepareAnalyzer(sampleRate: Double) {
        guard analyzer == nil || analyzerRate != sampleRate else { return }
        analyzer = SpectrumAnalyzer(bandCount: bandCount, sampleRate: sampleRate)
        analyzerRate = sampleRate
        if analyzer == nil {
            NSLog("Resonata: could not create the FFT setup; spectrum disabled")
        }
    }

    /// Mixes one buffer of Float32 audio to mono and analyses it.
    ///
    /// Handles both layouts: one buffer per channel (what ScreenCaptureKit
    /// sends), or one buffer with the channels interleaved (what a tap may).
    func ingest(_ list: UnsafeMutableAudioBufferListPointer, interleaved: Bool, channelsPerFrame: Int) {
        guard let analyzer, let first = list.first, let firstData = first.mData else { return }
        let channelsInFirst = interleaved ? max(channelsPerFrame, 1) : 1
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channelsInFirst)
        guard frames > 0 else { return }
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }

        let frame: SpectrumFrame? = mono.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return nil }
            let n = vDSP_Length(frames)
            vDSP_vclr(base, 1, n)
            var channels: Float = 0
            if interleaved {
                let source = firstData.assumingMemoryBound(to: Float.self)
                for channel in 0..<channelsInFirst {
                    vDSP_vadd(base, 1, source + channel, vDSP_Stride(channelsInFirst), base, 1, n)
                }
                channels = Float(channelsInFirst)
            } else {
                for buffer in list {
                    guard let data = buffer.mData else { continue }
                    vDSP_vadd(base, 1, data.assumingMemoryBound(to: Float.self), 1, base, 1, n)
                    channels += 1
                }
            }
            guard channels > 0 else { return nil }
            if channels > 1 {
                var scale = 1 / channels
                vDSP_vsmul(base, 1, &scale, base, 1, n)
            }
            return analyzer.process(base, count: frames)
        }
        if let frame { publish(frame) }
    }

    /// Empties the frame and drops the signal, for when capture stops.
    func clear() {
        latest.withLock { $0 = [] }
        Task { @MainActor in self.hasSignal = false }
    }

    private func publish(_ frame: SpectrumFrame) {
        latest.withLock { $0 = frame.bands }
        updateSignal(from: frame.bands)
        if frame.beat { Task { @MainActor in self.beat &+= 1 } }
        if Self.debugBands { printBands(frame) }
    }

    /// Raises `hasSignal` quickly and lowers it slowly.
    ///
    /// Asymmetric on purpose. Music is full of gaps — the space between two
    /// beats is genuinely silent — and a symmetric threshold would switch this
    /// off and on several times a second. Coming back is instant; going away
    /// takes a second of real quiet.
    private func updateSignal(from bands: [Float]) {
        let loud = bands.contains { $0 > Self.signalThreshold }
        guard loud != signalState else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let settle: CFAbsoluteTime = loud ? 0.05 : 1.0
        guard now - signalChangedAt > settle else { return }
        signalState = loud
        signalChangedAt = now
        Task { @MainActor in self.hasSignal = loud }
    }

    /// A sparkline of the current spectrum, low frequency on the left, and a
    /// dot per beat detected since the last line.
    private func printBands(_ frame: SpectrumFrame) {
        if frame.beat { beatsSincePrint += 1 }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastBandPrint > 0.5 else { return }
        lastBandPrint = now
        let beats = String(repeating: "●", count: beatsSincePrint)
        beatsSincePrint = 0
        let blocks = Array(" ▁▂▃▄▅▆▇█")
        let sparkline = String(frame.bands.map { level -> Character in
            blocks[Int((min(max(level, 0), 1) * Float(blocks.count - 1)).rounded())]
        })
        let peak = frame.bands.max() ?? 0
        let mean = frame.bands.reduce(0, +) / Float(max(frame.bands.count, 1))
        print(String(format: "[%@]  peak %.3f  mean %.3f  %@", sparkline, peak, mean, beats))
        fflush(stdout)
    }
}

// MARK: - ScreenCaptureKit backend (macOS before 14.2)

/// Captures the system mix through ScreenCaptureKit.
///
/// Kept only for macOS versions without Core Audio taps (`ProcessTap.swift`).
/// It needs the Screen Recording permission, and a stream is always attached
/// to a display — ScreenCaptureKit has no audio-only mode.
final class ScreenCaptureSpectrum: SpectrumCapture, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private static let sampleRate: Double = 48_000

    @MainActor private var stream: SCStream?
    /// Capture should be running — cleared only by `stop()`. A stream that
    /// dies while this is set gets restarted.
    @MainActor private var wantsRunning = false
    @MainActor private var isStarting = false
    /// Whether this launch has already let macOS show its Screen Recording
    /// dialog. Without permission, every start would bring it back.
    @MainActor private var askedForPermission = false
    @MainActor private var retryDelay: TimeInterval = 2

    override init(bandCount: Int) {
        super.init(bandCount: bandCount)
        prepareAnalyzer(sampleRate: Self.sampleRate)
    }

    /// Idempotent: playback starting twice must not open two streams.
    override func start() {
        Task { @MainActor in
            wantsRunning = true
            guard stream == nil, !isStarting else { return }
            if !CGPreflightScreenCaptureAccess() {
                guard !askedForPermission else { return }
                askedForPermission = true
            }
            isStarting = true
            await startCapture()
        }
    }

    override func stop() {
        Task { @MainActor in
            wantsRunning = false
            guard let stream else { return }
            self.stream = nil
            try? await stream.stopCapture()
            clear()
        }
    }

    private func startCapture() async {
        defer { Task { @MainActor in self.isStarting = false } }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(Self.sampleRate)
            config.channelCount = 2
            // The video half is unwanted; 2x2 at one frame a second makes it
            // essentially free.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
            let keep = await MainActor.run { () -> Bool in
                guard self.wantsRunning else { return false }
                self.stream = stream
                self.retryDelay = 2
                return true
            }
            if !keep { try? await stream.stopCapture() }
        } catch {
            NSLog("Resonata: audio capture failed to start: \(error)")
            if (error as? SCStreamError)?.code != .userDeclined {
                await scheduleRestart()
            }
        }
    }

    /// Retries after a pause that doubles each time, up to half a minute —
    /// for a display unplugged mid-capture, say.
    @MainActor private func scheduleRestart() {
        guard wantsRunning else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard wantsRunning, stream == nil, !isStarting,
                  CGPreflightScreenCaptureAccess() else { return }
            isStarting = true
            await startCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            ingest(list, interleaved: false, channelsPerFrame: 2)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Resonata: audio capture stopped: \(error)")
        clear()
        Task { @MainActor in
            self.stream = nil
            self.scheduleRestart()
        }
    }
}
