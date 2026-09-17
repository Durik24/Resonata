import AppKit
import CoreImage
import SwiftUI

@MainActor
final class NotchModel: ObservableObject {
    @Published var isExpanded = false
    @Published var track: Track?

    /// Geometry of the display we're currently drawing on.
    ///
    /// Published rather than passed once into `NotchView`, because it changes
    /// at runtime: closing the lid moves us to the external monitor, where
    /// there's no cutout and the dimensions are different. Baking it into the
    /// view at construction left the old notch's size in place after a switch.
    @Published var notchSize: CGSize = .zero
    @Published var hasRealNotch = false

    /// Playback stopped long enough ago that the pill goes quiet.
    @Published var isIdle = false

    /// Only true with more than one display connected — no point offering a
    /// switch button with nowhere to switch to.
    @Published var canSwitchScreens = false

    /// Set by `NotchPanelController`. Moves the notch to the next display.
    var switchScreen: (() -> Void)?

    /// Where the bars get their heights. Held rather than observed: the band
    /// values change ~50 times a second and are pulled per frame by the views
    /// that draw them, never pushed through Combine.
    var spectrum: AudioSpectrumSource?

    /// Whether the machine is making any sound at all, from any app.
    ///
    /// Separate from `track?.isPlaying`, and deliberately so: audio from a
    /// browser has no metadata behind it, so this is true in cases where there
    /// is no track to speak of. It decides whether the bars' clock runs.
    @Published var hasAudioSignal = false

    /// Mirrors `AudioSpectrumSource.beat`. Increments once per detected beat.
    @Published var beat = 0

    /// The current track's artwork, decoded once per URL.
    ///
    /// The collapsed pill and the expanded panel are different views, and
    /// each used to carry its own `AsyncImage` — so every open re-fetched the
    /// art and the panel appeared a beat before its picture did. Loading it
    /// here, once, means both draw it on their first frame.
    @Published var artwork: NSImage?

    /// Synced lyrics for the current track, when LRCLIB has them.
    @Published var lyrics: [LyricLine]?
    /// Lyrics are being looked up for the current track.
    @Published var lyricsPending = false

    /// Whether the panel shows a lyrics row: real lyrics, or the space for
    /// them while a lookup is in flight — so the panel doesn't shrink and
    /// grow back on every track change.
    var showsLyricsRow: Bool { lyrics != nil || lyricsPending }

    /// The expanded panel grows a row when there are lyrics to show. Lives on
    /// the model so the panel controller and the view size from one number.
    var expandedHeight: CGFloat {
        NotchView.expandedHeight + (showsLyricsRow ? NotchView.lyricsHeight : 0)
    }

    /// The collapsed pill carries artwork and waveform only while playback is
    /// live. Idle, it shrinks back to the bare cutout — but `track` is still
    /// there, so a click brings up the last song and its play button.
    var showsCollapsedContent: Bool { track != nil && !isIdle }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel

    private var notchSize: CGSize { model.notchSize }
    /// No hardware cutout means the middle of the pill is usable space.
    private var hasRealNotch: Bool { model.hasRealNotch }

    /// Non-nil while the user owns the playhead — during a drag, and briefly
    /// after, so the once-a-second poll doesn't yank the knob back to where the
    /// track was before the seek landed.
    @State private var scrubFraction: Double?
    @State private var isScrubbing = false
    @State private var isHoveringBar = false

    /// Accent pulled from the album art, used for the background wash.
    @State private var accent: Color?

    /// 1 the instant a beat lands, easing back to 0. Everything that reacts
    /// to the beat — the scale of the whole notch, the bloom of the colour
    /// wash — reads this one value, so they move together.
    @State private var beatPulse: CGFloat = 0

    static let expandedWidth: CGFloat = 470
    /// Tall enough to seat the content below the cutout without cramping it.
    /// The base height, without lyrics — see `NotchModel.expandedHeight`.
    static let expandedHeight: CGFloat = 190
    /// Three lines of lyric and the breathing room around them.
    static let lyricsHeight: CGFloat = 58

    /// One spring, one clock.
    ///
    /// Everything that moves during an expand — the frame, the shape's radii,
    /// the padding, the artwork — has to be driven by *this and nothing else*.
    /// Stacking a `withAnimation` at the call site on top of `.animation`
    /// modifiers gives the container and its contents separate springs, and two
    /// springs that disagree by even a little read as broken.
    ///
    /// A quick spring: visible as motion, over before it registers as a wait.
    ///
    /// This was walked all the way down to a hard cut while chasing an
    /// "opens slowly" report that turned out to be SwiftUI not rendering at
    /// all until something unrelated woke it (see `NotchPanelController`).
    /// With rendering fixed, a 0.22s spring is what the open should feel like.
    private static let expand = Animation.spring(response: 0.22, dampingFraction: 0.86)

    /// The content swap is a crossfade, deliberately *not* a spring. A scale or
    /// slide transition here competes with the box stretching underneath it,
    /// which is the other half of what looks wrong.
    private static let crossfade = AnyTransition.opacity
        .animation(.easeInOut(duration: 0.12))

    /// Device-space black, deliberately not `Color.black`.
    ///
    /// `Color.black` is sRGB and gets colour-managed into the display's
    /// profile, which on a wide-gamut panel can land a hair above zero — enough
    /// that the pill reads as very dark grey next to the bezel rather than
    /// disappearing into it. Device space skips the conversion and drives the
    /// pixels to a true 0,0,0.
    ///
    /// That's as dark as a display can go. On the laptop the real cutout is
    /// unlit hardware, so it will always be a touch darker than any lit pixel;
    /// no colour value can close that gap.
    private static let panelBlack = Color(
        nsColor: NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
    )

    private var size: CGSize {
        model.isExpanded
            ? CGSize(width: Self.expandedWidth, height: model.expandedHeight)
            // Idle shrinks the pill back to the bare cutout, not just blacks it
            // out — an idle pill that keeps the full playing width stays
            // visibly longer than the hardware notch.
            : CGSize(width: notchSize.width
                        + (model.showsCollapsedContent ? NotchMetrics.collapsedContentWidth : 0),
                     // Height offset applies in every collapsed state, playing
                     // or not — otherwise the pill changes height when the
                     // music stops, which is visible as a twitch.
                     height: notchSize.height + NotchMetrics.collapsedExtraHeight)
    }

    private var shape: NotchShape {
        // Collapsed top radius is 0 on purpose: it's the concave flare that
        // curves the top corners *outward* into the bezel, and at this size it
        // reads as the shape tapering off rather than as a notch. Zero gives
        // straight vertical sides, rounded only along the bottom.
        //
        // It also happens to be the floor on how far out content can sit — the
        // shape's body starts that many points in from the edge — so at 0
        // nothing is held back either.
        NotchShape(
            topRadius: model.isExpanded ? 12 : 0,
            bottomRadius: model.isExpanded ? 24 : 7
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                shape.fill(Self.panelBlack)
                // The wash sits *over* solid black, never replacing it — the
                // collapsed pill has to stay black enough to pass for the
                // bezel, and a gradient that bottoms out anywhere above black
                // would give the illusion away.
                shape.fill(accentWash)

                // Full spectrum along the bottom edge, under the controls.
                // Kept faint and behind `content` on purpose: at this size a
                // bright equaliser competes with the artwork and the title for
                // attention and wins, which makes the panel look like a toy.
                if model.isExpanded {
                    SpectrumBars(source: model.spectrum,
                                 barCount: 32,
                                 isAnimating: true,
                                 tint: .white.opacity(0.22),
                                 barWidth: 3,
                                 spacing: 4)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottom)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 12)
                        .allowsHitTesting(false)
                        .transition(Self.crossfade)
                }

                content
                    .padding(.horizontal, model.isExpanded ? 20 : 6)
            }
            .frame(width: size.width, height: size.height)
            // Both states are laid out at their final size and clipped, so the
            // content is revealed by the growing box rather than re-laid-out on
            // every frame of it. Without this the title truncates and un-
            // truncates mid-animation and the artwork jumps.
            .clipShape(shape)
            // The beat. Scaled from the top edge, so the pill grows down and
            // outward from the bezel rather than lifting off it.
            .scaleEffect(1 + beatPulse * NotchMetrics.beatPulseScale, anchor: .top)
            // Hit-test the silhouette only — the rest of the panel stays
            // click-through so you can still reach the menu bar beside it.
            // Same radii as the drawn shape, or the hit area lags the visual.
            .contentShape(shape)
            // The single animation source, applied *here* — to the shape and
            // its contents — and not at the root. Keyed on `size` rather than
            // `isExpanded` so a track appearing while collapsed widens smoothly
            // too.
            //
            // It used to sit on the root, below the frame that fills the
            // window. That frame's height jumps 32 → 280 when the window grows,
            // and animating it meant a 32pt-tall frame growing inside a 280pt
            // window — centred, as any undersized frame is — so the whole
            // panel began in the middle of the window and slid up to the top
            // as it grew. That was the "pops up from the bottom".
            .animation(Self.expand, value: size)
            // Opening and closing are both handled in AppKit — see
            // `NotchPanel.onMouseDown` and the global monitor in the
            // controller. Nothing here reacts to clicks; the buttons and the
            // scrubber take their own.

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Keyed on the artwork URL, so it runs once per track rather than on
        // every one-second poll.
        .task(id: model.track?.artworkURL) {
            let url = model.track?.artworkURL
            async let colour = ArtworkAccent.color(from: url)
            async let image = Self.loadArtwork(url)
            let (c, i) = await (colour, image)
            accent = c
            model.artwork = i
        }
        .animation(.easeInOut(duration: 0.5), value: accent)
        .onChange(of: model.beat) { _, _ in
            // Snap to full without animating, then ease back down. Animating
            // the rise as well would blur the attack — the whole point of a
            // beat is that it arrives all at once.
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) { beatPulse = 1 }
            withAnimation(.easeOut(duration: 0.32)) { beatPulse = 0 }
        }
    }

    /// Colour bleeding out of the top-left, fading to clear before the opposite
    /// corner. Stronger when expanded, where there's room for it to read as
    /// deliberate rather than as a smudge.
    private var accentWash: LinearGradient {
        // Nothing playing means no colour at all. A tinted pill sitting on the
        // bezel with the music stopped reads as a smudge on the screen rather
        // than as part of the hardware — the whole illusion depends on the
        // idle shape being indistinguishable from black.
        let colourable = model.isExpanded || model.showsCollapsedContent
        let tint = colourable ? (accent ?? .clear) : .clear
        // Brightens on the beat and settles back with it.
        let bloom = 1 + Double(beatPulse) * NotchMetrics.beatWashBloom
        return LinearGradient(
            stops: [
                // The collapsed wash is deliberately faint. Any tint at all
                // lifts the pill off true black, and on the bezel that's the
                // difference between "part of the hardware" and "a dark shape
                // on the screen". The expanded panel can afford the colour.
                .init(color: tint.opacity((model.isExpanded ? 0.55 : 0.38) * bloom), location: 0),
                .init(color: tint.opacity((model.isExpanded ? 0.16 : 0.18) * bloom), location: 0.45),
                // The collapsed pill keeps a trace of colour into the far
                // corner; the expanded panel runs out to clear, as it did
                // before. Falling to nothing is what makes a wash read as a
                // smudge in one corner rather than as a coloured surface, which
                // matters more on something this small.
                .init(color: tint.opacity(model.isExpanded ? 0 : 0.06), location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var content: some View {
        if model.isExpanded {
            expanded.transition(Self.crossfade)
        } else {
            collapsed.transition(Self.crossfade)
        }
    }

    // MARK: Collapsed — artwork on the left of the notch, waveform on the right

    private var collapsed: some View {
        Group {
            if hasRealNotch {
                // The gap between artwork and waveform is the hardware cutout.
                // Nothing can go in it — there are no pixels there — so the
                // title has nowhere to live on the laptop screen.
                HStack(spacing: 0) {
                    artwork(size: notchSize.height - 8)
                    Spacer(minLength: notchSize.width - 20)
                    waveform
                }
            } else {
                // On an external display that same gap is ordinary black, so
                // the title goes where the cutout would have been. Same shape,
                // same positions either side — just with the middle used.
                HStack(spacing: 0) {
                    artwork(size: notchSize.height - 8)
                    Spacer(minLength: 8)
                    Text(model.track?.title ?? "")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    waveform
                }
            }
        }
        // Pinned to the widest collapsed state so the artwork doesn't slide
        // sideways while the box is growing. The inset moves the contents in
        // from the edges; the pill itself keeps its size.
        .frame(width: collapsedContentWidth)
        .opacity(model.showsCollapsedContent ? 1 : 0)
    }

    /// Usable width inside the collapsed pill, once the padding and the inset
    /// are taken out.
    private var collapsedContentWidth: CGFloat {
        notchSize.width + NotchMetrics.collapsedContentWidth - 12
            - (2 * NotchMetrics.collapsedInset)
    }


    /// Always rendered, so the right-hand side never collapses to nothing when
    /// playback is paused — that asymmetry is most of what reads as "off".
    private var waveform: some View {
        let playing = model.track?.isPlaying == true
        // Runs the clock for audio the metadata side can't see — a YouTube tab
        // has no `track`, but it still moves the bars.
        let live = playing || model.hasAudioSignal
        return SpectrumBars(source: model.spectrum,
                            barCount: 3,
                            isAnimating: live,
                            tint: .white.opacity(live ? 0.85 : 0.35))
            // Same width as the artwork opposite it, not the width the bars
            // happen to need. Both sit against their own edge of the pill, so
            // unequal widths put them at unequal distances from the cutout —
            // 7pt one side, 13pt the other. Matching widths is the only way to
            // have the outer margins *and* the gaps to the notch both line up.
            .frame(width: notchSize.height - 8, height: 16)
            // Trailing padding shifts only the wave inward — the artwork sits
            // on the far side of the cutout and stays put.
            .padding(.trailing, NotchMetrics.waveformNudge)
    }

    // MARK: Expanded — artwork, metadata, scrubber, transport

    private var expanded: some View {
        VStack(spacing: 0) {
            expandedMain
                .onAppear {
                    if NotchPanel.debugClick { NSLog("click: expanded body APPEARED") }
                }
            if model.showsLyricsRow {
                LyricsView(lines: model.lyrics ?? [], track: model.track)
                    .frame(height: Self.lyricsHeight - 8)
                    .padding(.top, 8)
                    .transition(Self.crossfade)
            }
        }
        // Clear the hardware cutout. The expanded panel is centred and wider
        // than the notch, but its top strip runs *behind* the notch, where
        // there is no screen at all. Anything drawn there — the title, in
        // practice — simply doesn't exist. Start below it.
        .padding(.top, notchSize.height + 6)
        .padding(.bottom, 18)
        // Laid out at the final width from frame one — see `clipShape` above.
        .frame(width: Self.expandedWidth - 40, alignment: .leading)
    }

    private var expandedMain: some View {
        HStack(spacing: 16) {
            artwork(size: 92)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.track?.title ?? "Nothing playing")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(model.track?.artist ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)

                progress
                    .padding(.top, 10)

                HStack(spacing: 26) {
                    button("backward.fill") { send(.previous) }
                    // Standard transport convention: the glyph shows what a
                    // click will do, so playing offers pause and vice versa.
                    button(model.track?.isPlaying == true ? "pause.fill" : "play.fill") {
                        send(.playPause)
                    }
                    button("forward.fill") { send(.next) }
                }
                .padding(.top, 4)
            }
            .foregroundStyle(.white)

            Spacer(minLength: 0)

            if model.canSwitchScreens {
                VStack(spacing: 0) {
                    Button { model.switchScreen?() } label: {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportButtonStyle())
                    .help("Přepnout notch na další monitor")

                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Commands go to whichever player the current track came from, so this is
    /// a no-op when nothing is loaded rather than guessing at an app.
    private func send(_ command: TransportCommand) {
        guard let source = model.track?.source else { return }
        transport(command, in: source)
    }

    /// Where the playhead is at `date`, 0...1.
    private func playbackFraction(at date: Date) -> Double {
        guard let track = model.track, track.duration > 0 else { return 0 }
        return min(max(track.position(at: date) / track.duration, 0), 1)
    }

    /// What the labels should read — the drag position while scrubbing, so the
    /// elapsed time tracks your finger rather than lagging behind.
    private func displayedPosition(at date: Date) -> TimeInterval {
        guard let track = model.track else { return 0 }
        return (scrubFraction ?? playbackFraction(at: date)) * track.duration
    }

    private var progress: some View {
        // The playhead is interpolated locally between syncs now, so the bar
        // needs a clock of its own.
        //
        // This replaces animating `.linear(duration: 1)` between once-a-second
        // jumps. That only ever looked continuous because the poll interval
        // happened to equal the animation duration — the moment the poll
        // slowed to ten seconds it would have crawled a second and then stuck.
        //
        // Paused playback needs no clock, and neither does a drag: both are
        // driven by state changes SwiftUI already re-renders for. Only built
        // while expanded (see `content`), so the collapsed pill pays nothing.
        TimelineView(
            .animation(minimumInterval: 1 / 30,
                       paused: model.track?.isPlaying != true || isScrubbing)
        ) { context in
            progressBody(at: context.date)
        }
    }

    private func progressBody(at date: Date) -> some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let shown = scrubFraction ?? playbackFraction(at: date)
                let active = isHoveringBar || isScrubbing
                let barHeight: CGFloat = active ? 6 : 4

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white)
                        // Floor at barHeight so a capsule at position zero is a
                        // dot rather than a rendering artifact.
                        .frame(width: max(barHeight, geo.size.width * shown))
                }
                .frame(height: barHeight)
                // The knob only shows on hover — the Music.app convention, and
                // it keeps the collapsed-ish resting state clean.
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 9, height: 9)
                        .offset(x: geo.size.width * shown - 4.5)
                        .opacity(active ? 1 : 0)
                }
                // Centre the thin bar inside a much taller invisible hit area —
                // a 4pt drag target is unusable.
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onHover { isHoveringBar = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            scrubFraction = fraction(at: value.location.x, in: geo.size.width)
                        }
                        .onEnded { value in
                            let target = fraction(at: value.location.x, in: geo.size.width)
                            scrubFraction = target
                            isScrubbing = false
                            if let track = model.track, track.duration > 0 {
                                seek(to: target * track.duration, in: track.source)
                            }
                            releaseScrubWhenPollCatchesUp()
                        }
                )
                .animation(.easeOut(duration: 0.12), value: active)
            }
            .frame(height: 12)

            HStack(spacing: 0) {
                Text(timeString(displayedPosition(at: date)))
                Spacer(minLength: 0)
                Text(timeString(model.track?.duration ?? 0))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    /// A click anywhere on the bar is a seek, so clamp rather than ignore
    /// out-of-bounds drags — you can overshoot the ends and still get 0 or 1.
    private func fraction(at x: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
    }

    /// Hand the playhead back to the poller once it's had time to report the
    /// post-seek position. Releasing immediately makes the knob snap backwards.
    private func releaseScrubWhenPollCatchesUp() {
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            if !isScrubbing { scrubFraction = nil }
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Fetches and decodes the artwork off the main thread.
    private static func loadArtwork(_ url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data else { return nil }
        return NSImage(data: data)
    }

    private func artwork(size: CGFloat) -> some View {
        Group {
            if let image = model.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else if model.track?.artworkURL != nil {
                // Loading. Same shape as the art so nothing shifts when it lands.
                Color.white.opacity(0.1)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        // Spotify's album art is barely rounded — roughly a 0.07 ratio. The
        // 0.22 this started with reads as a squircle app icon, not a record.
        .clipShape(RoundedRectangle(cornerRadius: size * 0.09, style: .continuous))
        // A hairline edge stops dark artwork from dissolving into the panel.
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                // A 15pt glyph is a tiny target; pad the hit area out to
                // something you can actually hit without aiming.
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
    }
}

/// Pulls a usable accent colour out of album art.
enum ArtworkAccent {

    /// Colour-managed on purpose. The previous context disabled management
    /// (`workingColorSpace: NSNull()`), which reads a wide-gamut cover's raw
    /// numbers as if they were sRGB and shifts every colour in it.
    private static let context = CIContext()

    /// 32x32 = 1024 samples. Coarser grids blend neighbouring colours into
    /// intermediates that aren't in the artwork at all.
    private static let grid = 32

    static func color(from url: URL?) async -> Color? {
        guard let url, let data = await load(url), let image = CIImage(data: data),
              let pixels = downsample(image) else { return nil }
        return dominantColour(in: pixels)
    }

    private static func downsample(_ image: CIImage) -> [UInt8]? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(grid) / extent.width,
            y: CGFloat(grid) / extent.height
        ))

        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var buffer = [UInt8](repeating: 0, count: grid * grid * 4)
        context.render(
            scaled,
            toBitmap: &buffer,
            rowBytes: grid * 4,
            bounds: CGRect(x: 0, y: 0, width: grid, height: grid),
            format: .RGBA8,
            colorSpace: srgb
        )
        return buffer
    }

    /// Picks the colour the artwork is actually *about*, rather than averaging
    /// it.
    ///
    /// Averaging was the old approach and it's wrong in a specific way: mix all
    /// the pixels of any busy cover and you land on grey-brown every time, so
    /// the saturation then had to be forced back up, which invented a hue that
    /// wasn't in the image. Monochrome covers came out tinted at random.
    ///
    /// Instead, pixels vote for a bin weighted by how colourful they are, so a
    /// small vivid area beats a large muddy one, and the winner is reported as
    /// the average of the actual pixels that landed in it. Nothing is
    /// reconstructed from clamped hue/saturation numbers, so the result is a
    /// colour that genuinely appears in the artwork.
    ///
    /// Pixels with no usable hue — near-black, near-white, near-grey — abstain.
    /// If they all abstain the cover really has no colour (a black-and-white
    /// sleeve, say) and this returns nil so the panel stays black, rather than
    /// inventing a tint.
    private static func dominantColour(in pixels: [UInt8]) -> Color? {
        struct Bin {
            var weight = 0.0
            var r = 0.0, g = 0.0, b = 0.0
        }

        // Binned by hue *and* by lightness: without the second axis a dark
        // burgundy and a bright pink land together and average into neither.
        let hueBins = 24, levelBins = 3
        var bins = [Bin](repeating: Bin(), count: hueBins * levelBins)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255

            let high = max(r, g, b), low = min(r, g, b)
            let chroma = high - low
            let saturation = high <= 0 ? 0 : chroma / high
            guard saturation > 0.15, high > 0.12, high < 0.98 else { continue }

            var hue: Double
            if high == r        { hue = (g - b) / chroma / 6 }
            else if high == g   { hue = ((b - r) / chroma + 2) / 6 }
            else                { hue = ((r - g) / chroma + 4) / 6 }
            if hue < 0 { hue += 1 }

            let level = min(levelBins - 1, Int(high * Double(levelBins)))
            let index = min(hueBins - 1, Int(hue * Double(hueBins))) * levelBins + level
            let weight = saturation * high

            bins[index].weight += weight
            bins[index].r += r * weight
            bins[index].g += g * weight
            bins[index].b += b * weight
        }

        // Roughly "at least a few strongly coloured samples out of 1024".
        guard let best = bins.max(by: { $0.weight < $1.weight }), best.weight > 1.5 else {
            return nil
        }

        var r = best.r / best.weight
        var g = best.g / best.weight
        var b = best.b / best.weight

        // The only correction applied, and it's proportional: a colour too dark
        // to register against a black panel is scaled up along its own RGB
        // ratios. That preserves the hue exactly — the old code re-derived the
        // colour from clamped values instead, which shifted it.
        let peak = max(r, g, b)
        if peak > 0, peak < 0.55 {
            let lift = 0.55 / peak
            r = min(1, r * lift)
            g = min(1, g * lift)
            b = min(1, b * lift)
        }

        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    private static func load(_ url: URL) async -> Data? {
        // Music's artwork is a file we wrote ourselves; Spotify's is remote.
        if url.isFileURL { return try? Data(contentsOf: url) }
        return try? await URLSession.shared.data(from: url).0
    }
}

/// Press feedback for the transport controls. `.plain` gives none at all, so
/// clicks felt like they hadn't registered even when they had.
private struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Bars whose heights are the actual frequency content of what the machine is
/// playing.
///
/// Falls back to a synthetic bounce when there is no spectrum to draw — capture
/// permission not granted, or nothing playing yet — so the pill still reads as
/// alive rather than broken. That fallback is what this whole widget used to be.
struct SpectrumBars: View {

    /// Where the heights come from.
    ///
    /// Read inside the draw call rather than observed. The analyser produces a
    /// frame every ~21ms; routing that through `@Published` would rebuild this
    /// view 50 times a second, and the whole reason the bars are drawn into a
    /// `Canvas` is to keep redraws from propagating that far.
    var source: AudioSpectrumSource?

    /// How many bars to draw. The analyser produces more bands than the
    /// collapsed pill has room for, so they are averaged down to fit.
    var barCount: Int = 3

    /// Paused playback shows the bars at rest rather than removing them, so the
    /// collapsed row keeps its shape.
    var isAnimating: Bool = true

    /// Canvas draws with an explicit colour — `foregroundStyle` from outside
    /// doesn't reach into it.
    var tint: Color = .white

    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3

    /// Drawn into a `Canvas` rather than built from `Capsule` views.
    ///
    /// The view-based version re-ran SwiftUI layout for the *entire* notch on
    /// every tick — a profile showed `StackLayout.sizeChildren` and
    /// `_ZStackLayout.sizeThatFits` firing 30x a second and costing ~9% CPU at
    /// rest. A Canvas has a fixed size, so its redraws never propagate outward.
    /// That mattered at three bars; at thirty-two it is the only workable way.
    var body: some View {
        // 30fps rather than 60: the analyser only produces a frame every ~21ms,
        // so a faster clock would redraw the same numbers twice.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isAnimating)) { context in
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
                let levels = levels(at: context.date.timeIntervalSinceReferenceDate)
                guard !levels.isEmpty else { return }

                let total = barWidth * CGFloat(levels.count)
                    + spacing * CGFloat(levels.count - 1)
                var x = (size.width - total) / 2

                for level in levels {
                    // Never let a bar vanish: a quiet passage should read as
                    // quiet, not as a rendering failure.
                    let factor = isAnimating ? max(level, 0.16) : 0.35
                    let height = size.height * factor
                    let rect = CGRect(x: x, y: (size.height - height) / 2,
                                      width: barWidth, height: height)
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(tint)
                    )
                    x += barWidth + spacing
                }
            }
        }
    }

    /// The heights to draw, 0...1, low frequency first.
    private func levels(at time: TimeInterval) -> [CGFloat] {
        let bands = source?.bands ?? []
        guard !bands.isEmpty else {
            return (0..<barCount).map { synthetic(at: time, bar: $0) }
        }
        return downsample(bands, to: barCount)
    }

    /// Averages the analyser's bands down to the number of bars there is room
    /// for, keeping the low-to-high ordering.
    private func downsample(_ bands: [Float], to count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        guard bands.count > count else { return bands.map { CGFloat($0) } }

        let per = Double(bands.count) / Double(count)
        return (0..<count).map { i in
            let lo = Int(Double(i) * per)
            let hi = min(max(lo + 1, Int(Double(i + 1) * per)), bands.count)
            let slice = bands[lo..<hi]
            return CGFloat(slice.reduce(0, +) / Float(slice.count))
        }
    }

    /// The old fake waveform, kept as the no-signal fallback.
    ///
    /// Driven by the clock rather than by animating a `phase` value. The
    /// obvious version — `withAnimation(.repeatForever) { phase = .pi * 2 }`
    /// with the height computed as `abs(sin(phase))` — cannot work: SwiftUI
    /// doesn't re-evaluate `sin` at each step, it interpolates the *resulting*
    /// scale between its start and end values. `abs(sin(0))` and `abs(sin(2pi))`
    /// are both 0, so it animates from a value to the identical value and
    /// nothing moves, forever.
    private func synthetic(at time: TimeInterval, bar: Int) -> CGFloat {
        // Offsetting each bar's phase is what makes it read as a waveform
        // rather than bars pulsing in unison.
        let phase = time * 3.2 + Double(bar) * 0.9
        return 0.35 + 0.65 * abs(sin(phase))
    }
}

/// Three lines of lyric: the one being sung, bright, with its neighbours dimmed
/// either side. Slides up a line as the song moves on.
struct LyricsView: View {
    var lines: [LyricLine]
    var track: Track?

    var body: some View {
        // Ten times a second is plenty for something that changes every few
        // seconds, and it is only built while the panel is open.
        TimelineView(.animation(minimumInterval: 1 / 10,
                                paused: track?.isPlaying != true)) { context in
            let position = track?.position(at: context.date) ?? 0
            let index = LyricsStore.index(in: lines, at: position)
            rows(around: index)
                // Keyed on the index, so each new line is a fresh view that
                // slides in rather than the old text morphing into the new.
                .id(index)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: index)
        }
        .clipped()
    }

    private func rows(around index: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            row(at: (index ?? 0) - 1, dim: true)
            row(at: index, dim: false)
            row(at: (index ?? -1) + 1, dim: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(at index: Int?, dim: Bool) -> some View {
        let text = index.flatMap { lines.indices.contains($0) ? lines[$0].text : nil } ?? ""
        Text(text.isEmpty ? "\u{2026}" : text)
            .font(.system(size: dim ? 11 : 13, weight: dim ? .regular : .semibold))
            .foregroundStyle(.white.opacity(dim ? 0.38 : 0.95))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: 15)
    }
}
