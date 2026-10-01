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

// MARK: - ScreenCaptureKit backend

/// Taps the machine's audio output and keeps the newest analysed frame ready
/// for whoever draws next.
///
/// `@unchecked Sendable` is a claim about specific things, not a shrug:
/// `analyzer`, `mono`, `signalState` and `signalChangedAt` are only ever touched
/// on `audioQueue`; `latest` is behind a lock; `stream` and `hasSignal` are only
/// ever touched on the main actor.
final class SystemAudioSpectrum: NSObject, ObservableObject, AudioSpectrumSource,
                                 SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// Asked of ScreenCaptureKit explicitly so the analyser's bin-to-frequency
    /// mapping can be built up front rather than guessed from the first buffer.
    private static let sampleRate: Double = 48_000

    /// The newest analysed frame.
    ///
    /// Deliberately *not* `@Published`. The analyser produces a frame roughly
    /// every 20 ms, and pushing each one through Combine would re-render the
    /// notch at that rate whether or not anything was on screen to see it. The
    /// view already has a clock of its own, so it pulls the latest frame when
    /// it is ready to draw one and drops the rest — the display is the thing
    /// that should decide how often it redraws.
    private let latest = OSAllocatedUnfairLock<[Float]>(initialState: [])

    var bands: [Float] { latest.withLock { $0 } }

    /// Published, unlike `bands`, because it changes a handful of times a
    /// minute rather than fifty times a second — and because the view needs it
    /// to decide whether to start its clock at all, which is a decision that
    /// has to reach SwiftUI rather than be polled from inside a draw call.
    /// Only ever written from the main actor — see `updateSignal`.
    @Published private(set) var hasSignal = false

    /// See `AudioSpectrumSource.beat`. Only ever written from the main actor.
    /// Published, like `hasSignal`, because a few events a second is a rate
    /// SwiftUI can take — and because the pulse it drives *is* an animation,
    /// which has to go through SwiftUI state to exist at all.
    @Published private(set) var beat = 0

    /// Anything above this counts as audible. Set above the noise the analyser
    /// reports for true digital silence, and below a quiet passage.
    private static let signalThreshold: Float = 0.06

    /// Signal tracking, audio queue only.
    private var signalState = false
    private var signalChangedAt: CFAbsoluteTime = 0

    /// Run with `RESONATA_DEBUG_BANDS=1` to print the spectrum to stdout twice
    /// a second:
    ///
    ///     RESONATA_DEBUG_BANDS=1 ./Resonata.app/Contents/MacOS/Resonata
    ///
    /// Tuning `floorDb` and `ceilingDb` by eye, on bars thirty points tall
    /// behind a hardware cutout, is guesswork. This makes the numbers visible.
    private static let debugBands =
        ProcessInfo.processInfo.environment["RESONATA_DEBUG_BANDS"] == "1"
    private var lastBandPrint: CFAbsoluteTime = 0
    private var beatsSincePrint = 0

    private let analyzer: SpectrumAnalyzer?
    private let audioQueue = DispatchQueue(
        label: "com.local.resonata.audio", qos: .userInitiated
    )

    /// Scratch space for the channel mix, grown once and reused. Allocating a
    /// buffer inside an audio callback is the classic way to make one late.
    private var mono: [Float] = []

    @MainActor private var stream: SCStream?

    /// Capture should be running — cleared only by `stop()`. A stream that
    /// dies while this is set gets restarted.
    @MainActor private var wantsRunning = false
    @MainActor private var retryDelay: TimeInterval = 2

    init(bandCount: Int) {
        self.analyzer = SpectrumAnalyzer(
            bandCount: bandCount, sampleRate: Self.sampleRate
        )
        super.init()
        if analyzer == nil {
            NSLog("Resonata: could not create the FFT setup; spectrum disabled")
        }
    }

    func start() {
        Task { @MainActor in
            wantsRunning = true
            await startCapture()
        }
    }

    func stop() {
        Task { @MainActor in
            wantsRunning = false
            guard let stream else { return }
            self.stream = nil
            try? await stream.stopCapture()
            latest.withLock { $0 = [] }
            hasSignal = false
        }
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                NSLog("Resonata: no display available to attach an audio tap to")
                return
            }

            let filter = SCContentFilter(
                display: display, excludingApplications: [], exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            // Otherwise the app would analyse its own output if it ever made
            // any, which is a feedback loop waiting to happen.
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(Self.sampleRate)
            config.channelCount = 2

            // ScreenCaptureKit has no audio-only mode — a stream is always
            // attached to a display. Shrinking the video to 2x2 at one frame a
            // second makes the half we don't want essentially free, rather than
            // paying for a full-resolution screen capture to get at the audio.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
            await MainActor.run {
                self.stream = stream
                self.retryDelay = 2
            }
        } catch {
            NSLog("Resonata: audio capture failed to start: \(error)")
            // A refused permission won't change by asking again; anything
            // else — no display yet, a display mid-reconfiguration — might.
            if (error as? SCStreamError)?.code != .userDeclined {
                await scheduleRestart()
            }
        }
    }

    /// Tries again after a pause that doubles each time, up to half a minute.
    ///
    /// The stream is attached to a display (ScreenCaptureKit has no
    /// audio-only mode). Unplug the monitor it picked and the stream stops
    /// with an error — before this, the bars then fell back to the fake
    /// animation until the app was relaunched.
    @MainActor private func scheduleRestart() {
        guard wantsRunning else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard wantsRunning, stream == nil else { return }
            await startCapture()
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let analyzer else { return }

        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let first = list.first, first.mData != nil else { return }
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }

            if mono.count < frames {
                mono = [Float](repeating: 0, count: frames)
            }

            // ScreenCaptureKit hands over deinterleaved Float32: one buffer per
            // channel. Averaging them to mono is enough for a spectrum, and it
            // halves the work.
            let frame: SpectrumFrame? = mono.withUnsafeMutableBufferPointer { out in
                guard let base = out.baseAddress else { return nil }
                vDSP_vclr(base, 1, vDSP_Length(frames))

                var channels: Float = 0
                for buffer in list {
                    guard let data = buffer.mData else { continue }
                    let source = data.assumingMemoryBound(to: Float.self)
                    vDSP_vadd(base, 1, source, 1, base, 1, vDSP_Length(frames))
                    channels += 1
                }
                guard channels > 0 else { return nil }
                if channels > 1 {
                    var scale = 1 / channels
                    vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(frames))
                }
                return analyzer.process(base, count: frames)
            }

            if let frame {
                latest.withLock { $0 = frame.bands }
                updateSignal(from: frame.bands)
                if frame.beat {
                    Task { @MainActor in self.beat &+= 1 }
                }
                if Self.debugBands { printBands(frame) }
            }
        }
    }

    /// Raises `hasSignal` quickly and lowers it slowly.
    ///
    /// Asymmetric on purpose. Music is full of gaps — the space between two
    /// beats is genuinely silent — and a symmetric threshold would switch this
    /// off and on several times a second, which is worse than never having it.
    /// Coming back is instant; going away takes a second of real quiet.
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
        let bands = frame.bands
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastBandPrint > 0.5 else { return }
        lastBandPrint = now
        let beats = String(repeating: "●", count: beatsSincePrint)
        beatsSincePrint = 0

        let blocks = Array(" ▁▂▃▄▅▆▇█")
        let sparkline = String(bands.map { level -> Character in
            let index = Int((min(max(level, 0), 1) * Float(blocks.count - 1)).rounded())
            return blocks[index]
        })
        let peak = bands.max() ?? 0
        let mean = bands.reduce(0, +) / Float(max(bands.count, 1))
        print(String(format: "[%@]  peak %.3f  mean %.3f  %@", sparkline, peak, mean, beats))
        fflush(stdout)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Resonata: audio capture stopped: \(error)")
        latest.withLock { $0 = [] }
        Task { @MainActor in
            self.hasSignal = false
            self.stream = nil
            self.scheduleRestart()
        }
    }
}
