import AppKit

/// `RESONATA_DEMO=1`: a made-up song instead of whatever is playing, for
/// screenshots. The README's pictures come from here, not from anyone's real
/// music: no album art that isn't ours, nothing about what you listen to.
///
/// The song, its cover, its lyrics and two calendar events are all invented;
/// nothing is read from the players or the calendar, and nothing is saved.
/// Settings can be overridden for a run with launch arguments, which are
/// never written back — e.g. `-showCalendar YES -showLyrics YES`.
@MainActor
enum Demo {
    static let isOn = ProcessInfo.processInfo.environment["RESONATA_DEMO"] == "1"

    static func install(on model: NotchModel) {
        let cover = coverURL()
        model.track = Track(title: "Neon Rain", artist: "Midnight Notes", album: "Afterglow",
                            duration: 214, sampledPosition: 83, sampledAt: Date(),
                            isPlaying: true, artworkURL: cover, source: "Spotify",
                            bundleID: "com.spotify.client")
        model.lyrics = [
            LyricLine(time: 0, text: "♪"),
            LyricLine(time: 70, text: "Streetlights hum a quiet tune"),
            LyricLine(time: 78, text: "City glowing in the rain"),
            LyricLine(time: 92, text: "Every window holds a light for you"),
            LyricLine(time: 104, text: "Neon rain, neon rain"),
        ]
        let day = Calendar.current.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            Calendar.current.date(byAdding: .minute, value: hour * 60 + minute, to: day) ?? day
        }
        CalendarStore.shared.showDemo([
            .init(id: "demo-1", title: "Studio session", start: at(14), end: at(16), isAllDay: false),
            .init(id: "demo-2", title: "Concert with friends", start: at(19, 30), end: at(22),
                  isAllDay: false),
        ])
    }

    /// A cover drawn here: a dusk gradient, a low sun and rain. Written to
    /// the temporary folder, where the artwork loader reads files from.
    private static func coverURL() -> URL? {
        let size = 600
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let s = CGFloat(size)
        let sky = CGGradient(colorsSpace: nil, colors: [
            CGColor(srgbRed: 0.98, green: 0.55, blue: 0.36, alpha: 1),
            CGColor(srgbRed: 0.72, green: 0.25, blue: 0.48, alpha: 1),
            CGColor(srgbRed: 0.16, green: 0.10, blue: 0.32, alpha: 1),
        ] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: s), options: [])
        // The sun, low on the horizon.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.82, blue: 0.55, alpha: 0.95))
        ctx.fillEllipse(in: CGRect(x: s * 0.28, y: s * 0.18, width: s * 0.44, height: s * 0.44))
        // The city: a row of blocks against it.
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.06, blue: 0.20, alpha: 1))
        let blocks: [(CGFloat, CGFloat)] = [(0, 0.22), (0.12, 0.34), (0.22, 0.26), (0.34, 0.42),
                                             (0.48, 0.30), (0.58, 0.38), (0.72, 0.24), (0.84, 0.32)]
        for (i, (x, h)) in blocks.enumerated() {
            let next = i + 1 < blocks.count ? blocks[i + 1].0 : 1
            ctx.fill(CGRect(x: x * s, y: 0, width: (next - x) * s + 1, height: h * s))
        }
        // Rain.
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
        ctx.setLineWidth(3)
        var seed: UInt64 = 7
        for _ in 0..<70 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = CGFloat((seed >> 33) % 600)
            let y = CGFloat((seed >> 13) % 600)
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x - 10, y: y - 34))
        }
        ctx.strokePath()

        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resonata-demo-cover.png")
        try? png.write(to: url)
        return url
    }
}
