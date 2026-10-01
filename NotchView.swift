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
    var showsCollapsedContent: Bool { (track != nil && !isIdle) || volumeLevel != nil }

    /// Set for a moment after the volume is scrolled, so the notch can show
    /// the new level. Nil the rest of the time.
    @Published var volumeLevel: Float?

    /// `RESONATA_DEBUG_FORCE_LIVE=1`: animate the pill as if music were
    /// playing, so the cost of playback can be measured on a silent machine.
    static let debugForceLive =
        ProcessInfo.processInfo.environment["RESONATA_DEBUG_FORCE_LIVE"] == "1"
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

    static let expandedWidth: CGFloat = 470
    /// Tall enough to seat the content below the cutout without cramping it.
    /// The base height, without lyrics — see `NotchModel.expandedHeight`.
    /// 210 rather than 190: the bottom 38 points belong to the wave, which
    /// used to share them with the last line of lyrics and drew over it.
    static let expandedHeight: CGFloat = 210
    /// The wave's strip along the bottom of the expanded panel.
    static let waveHeight: CGFloat = 26

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
    ///
    /// Everything that changes size — the panel opening and closing, the pill
    /// widening for a track, narrowing when it stops, the lyrics row arriving
    /// — settles on this one spring. Unhurried on purpose: long enough to be
    /// watched, damped enough to land without a wobble.
    private static let settle = Animation.spring(response: 0.45, dampingFraction: 0.82)

    /// Fades for content swapping in place: artwork, titles, glyphs.
    private static let fade = Animation.easeInOut(duration: 0.4)

    /// The content swap is a crossfade, deliberately *not* a spring. A scale or
    /// slide transition here competes with the box stretching underneath it,
    /// which is the other half of what looks wrong.
    private static let crossfade = AnyTransition.opacity
        .animation(.easeInOut(duration: 0.22))

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
                // The spectrum as a soft wave along the bottom edge, in the
                // album's colour. It has the bottom strip to itself — the
                // content stops above it (see `expanded`) — so it never runs
                // through the lyrics.
                if model.isExpanded {
                    SpectrumWave(source: model.spectrum,
                                 color: accent,
                                 isAnimating: isLive)
                        .frame(height: Self.waveHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottom)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                        .transition(Self.crossfade)
                }

                content
                    .padding(.horizontal, model.isExpanded ? 20 : 6)
            }
            // The notch itself: size, radii, fills, clip and hit shape, all
            // in one animatable modifier — see `NotchFrame` for why it has
            // to be one, and why the top alignment lives inside it.
            .modifier(NotchFrame(
                size: size,
                topRadius: model.isExpanded ? 12 : 0,
                bottomRadius: model.isExpanded ? 24 : 7,
                background: { shape in
                    AnyView(ZStack {
                        shape.fill(Self.panelBlack)
                        // The wash sits *over* solid black, never replacing
                        // it — the collapsed pill has to stay black enough to
                        // pass for the bezel, and a gradient that bottoms out
                        // anywhere above black would give the illusion away.
                        shape.fill(accentWash)
                        // The beat: the same wash, brighter, flashing and
                        // fading on each kick. Core Animation runs the fade,
                        // so a beat costs this app nothing per frame.
                        BeatBloom(shape: shape,
                                  color: colourable ? accent : nil,
                                  expanded: model.isExpanded,
                                  beat: model.beat)
                    })
                }
            ))
            // Size animations live *here*, on the shape, and never at the
            // root: the root frame fills the window, whose height jumps
            // 32 → 280 on open, and animating that frame centred the whole
            // panel mid-window and slid it up. Here, the shape grows out of
            // the notch and the frame around it simply snaps to fit.
            .animation(Self.settle, value: model.isExpanded)
            .animation(Self.settle, value: model.showsCollapsedContent)
            .animation(Self.settle, value: model.showsLyricsRow)
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
    }

    /// Whether the panel may carry colour at all. Nothing playing means no
    /// colour: a tinted pill sitting on the bezel with the music stopped reads
    /// as a smudge on the screen rather than as part of the hardware.
    private var colourable: Bool { model.isExpanded || model.showsCollapsedContent }

    /// Something is audibly playing: the spectrum's clocks should run.
    /// `hasAudioSignal` covers audio the metadata side can't see.
    private var isLive: Bool {
        model.track?.isPlaying == true || model.hasAudioSignal || NotchModel.debugForceLive
    }

    /// Colour bleeding out of the top-left, fading to clear before the opposite
    /// corner. Stronger when expanded, where there's room for it to read as
    /// deliberate rather than as a smudge.
    private var accentWash: LinearGradient {
        let tint = colourable ? (accent ?? .clear) : .clear
        return LinearGradient(
            stops: [
                // The collapsed wash is deliberately faint. Any tint at all
                // lifts the pill off true black, and on the bezel that's the
                // difference between "part of the hardware" and "a dark shape
                // on the screen". The expanded panel can afford the colour.
                .init(color: tint.opacity(model.isExpanded ? 0.55 : 0.38), location: 0),
                .init(color: tint.opacity(model.isExpanded ? 0.16 : 0.18), location: 0.45),
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
            // The panel's content is laid out at its final size and revealed
            // by the growing box — and since the box grows from the top
            // centre, the first thing visible is the *middle* of the panel,
            // which reads as the content popping out from there. Scaling it
            // with the box's current height, anchored at the top centre,
            // makes the whole panel zoom out of the notch and back into it.
            // `AnimatedFrame` runs layout every frame, so the reader sees the
            // interpolated size.
            GeometryReader { geo in
                expanded
                    .frame(width: geo.size.width, alignment: .top)
                    .scaleEffect(
                        max(0.05, min(1, geo.size.height / model.expandedHeight)),
                        anchor: .top
                    )
            }
            .transition(Self.crossfade)
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
                        .contentTransition(.opacity)
                        .animation(Self.fade, value: model.track?.title)
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
        .animation(Self.fade, value: model.showsCollapsedContent)
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
        let live = isLive
        return Group {
            if let level = model.volumeLevel {
                VolumeMeter(level: level, compact: true)
            } else {
                SpectrumBars(source: model.spectrum,
                             barCount: 3,
                             isAnimating: live,
                             tint: .white.opacity(live ? 0.85 : 0.35))
            }
        }
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Self.settle, value: model.showsLyricsRow)
        // Clear the hardware cutout. The expanded panel is centred and wider
        // than the notch, but its top strip runs *behind* the notch, where
        // there is no screen at all. Anything drawn there — the title, in
        // practice — simply doesn't exist. Start below it.
        .padding(.top, notchSize.height + 6)
        // Clear of the wave's strip, plus a little air.
        .padding(.bottom, Self.waveHeight + 12)
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
                    .contentTransition(.opacity)
                    .animation(Self.fade, value: model.track?.title)
                Text(model.track?.artist ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(Self.fade, value: model.track?.artist)

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
                    if let level = model.volumeLevel {
                        VolumeMeter(level: level, compact: false)
                            .transition(.opacity)
                    }
                }
                .animation(Self.fade, value: model.volumeLevel == nil)
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
                    .transition(.opacity)
                    .id(model.track?.artworkURL)
            } else if model.track?.artworkURL != nil {
                // Loading. Same shape as the art so nothing shifts when it lands.
                Color.white.opacity(0.1)
                    .transition(.opacity)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .animation(Self.fade, value: model.artwork == nil)
        .animation(Self.fade, value: model.track?.artworkURL)
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
                // play ⇄ pause morphs rather than snapping.
                .contentTransition(.symbolEffect(.replace))
                .animation(Self.fade, value: symbol)
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
/// permission not granted, or capture not started yet — so the pill still
/// reads as alive rather than broken.
///
/// A thin SwiftUI wrapper around `SpectrumBarsView`. The bars used to be a
/// `TimelineView` redrawing a `Canvas` thirty times a second, and that alone
/// was 4.5% CPU for three bars: every tick re-ran SwiftUI's view graph and
/// re-rasterised the canvas on the CPU. Now SwiftUI only hears about changes
/// of *configuration*; the animation itself never goes through it.
struct SpectrumBars: NSViewRepresentable {
    var source: AudioSpectrumSource?
    var barCount: Int = 3
    var isAnimating: Bool = true
    var tint: Color = .white
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3

    func makeNSView(context: Context) -> SpectrumBarsView { SpectrumBarsView() }

    func updateNSView(_ view: SpectrumBarsView, context: Context) {
        view.source = source
        view.configure(barCount: barCount, tint: NSColor(tint),
                       barWidth: barWidth, spacing: spacing)
        view.isAnimating = isAnimating
    }
}

/// One `CALayer` per bar, moved by a display link.
///
/// Each tick only sets a few layer frames, which the GPU composites — nothing
/// is redrawn. The link runs only while animating and only while on screen.
final class SpectrumBarsView: NSView {

    var source: AudioSpectrumSource?

    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            updateLink()
            renderFrame()
        }
    }

    private var bars: [CALayer] = []
    private var barWidth: CGFloat = 4
    private var spacing: CGFloat = 3
    private var link: CADisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Purely decorative: clicks go to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(barCount: Int, tint: NSColor, barWidth: CGFloat, spacing: CGFloat) {
        self.barWidth = barWidth
        self.spacing = spacing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if bars.count != barCount {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<barCount).map { _ in
                let bar = CALayer()
                layer?.addSublayer(bar)
                return bar
            }
        }
        for bar in bars {
            bar.backgroundColor = tint.cgColor
            bar.cornerRadius = barWidth / 2
        }
        CATransaction.commit()
        renderFrame()
    }

    override func layout() {
        super.layout()
        renderFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    private func updateLink() {
        let wanted = isAnimating && window != nil
        if wanted, link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            // The analyser has a new frame every ~21 ms; 30 Hz is all of them
            // a display at rest needs.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !wanted, let link {
            link.invalidate()
            self.link = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) { renderFrame() }

    private func renderFrame() {
        guard !bars.isEmpty else { return }
        let levels = isAnimating
            ? Self.levels(from: source?.bands ?? [], count: bars.count, at: CACurrentMediaTime())
            : Array(repeating: 0.35, count: bars.count)
        let size = bounds.size
        let total = barWidth * CGFloat(bars.count) + spacing * CGFloat(bars.count - 1)
        var x = (size.width - total) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, level) in zip(bars, levels) {
            // Never let a bar vanish: a quiet passage should read as quiet,
            // not as a rendering failure.
            let height = size.height * (isAnimating ? max(level, 0.16) : level)
            bar.frame = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
            x += barWidth + spacing
        }
        CATransaction.commit()
    }

    /// The heights to draw, 0...1, low frequency first: the analyser's bands
    /// averaged down to `count`, or the synthetic bounce when there are none.
    static func levels(from bands: [Float], count: Int, at time: TimeInterval) -> [CGFloat] {
        guard count > 0 else { return [] }
        guard !bands.isEmpty else {
            return (0..<count).map { synthetic(at: time, bar: $0) }
        }
        guard bands.count > count else { return bands.map { CGFloat($0) } }

        let per = Double(bands.count) / Double(count)
        return (0..<count).map { i in
            let lo = Int(Double(i) * per)
            let hi = min(max(lo + 1, Int(Double(i + 1) * per)), bands.count)
            let slice = bands[lo..<hi]
            return CGFloat(slice.reduce(0, +) / Float(slice.count))
        }
    }

    /// The old fake waveform, kept as the no-signal fallback. Offsetting each
    /// bar's phase is what makes it read as a waveform rather than bars
    /// pulsing in unison.
    private static func synthetic(at time: TimeInterval, bar: Int) -> CGFloat {
        let phase = time * 3.2 + Double(bar) * 0.9
        return 0.35 + 0.65 * abs(sin(phase))
    }
}

/// The spectrum as a smooth filled wave, bass on the left, treble on the
/// right, in the album's colour.
///
/// Same approach as `SpectrumBars`: SwiftUI only hears about configuration;
/// a display link reshapes two Core Animation layers — a gradient fill masked
/// by the curve, and a brighter line along its top.
struct SpectrumWave: NSViewRepresentable {
    var source: AudioSpectrumSource?
    /// The album's accent colour; white when the cover has none.
    var color: Color?
    var isAnimating: Bool

    func makeNSView(context: Context) -> SpectrumWaveView { SpectrumWaveView() }

    func updateNSView(_ view: SpectrumWaveView, context: Context) {
        view.source = source
        view.setColor(color.map { NSColor($0) })
        view.isAnimating = isAnimating
    }
}

final class SpectrumWaveView: NSView {

    var source: AudioSpectrumSource?

    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            updateLink()
            renderFrame()
        }
    }

    private let fill = CAGradientLayer()
    private let fillShape = CAShapeLayer()
    private let line = CAShapeLayer()
    private var link: CADisplayLink?

    /// Heights as drawn, eased toward the analyser's each frame so the curve
    /// glides between frames instead of snapping.
    private var shown: [CGFloat] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        fill.mask = fillShape
        // Bottom-left origin: colour at the crest, fading to nothing at the
        // baseline, so the wave sinks into the panel rather than sitting on it.
        fill.startPoint = CGPoint(x: 0.5, y: 1)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        line.fillColor = nil
        line.lineWidth = 1.5
        line.lineJoin = .round
        line.lineCap = .round
        layer?.addSublayer(fill)
        layer?.addSublayer(line)
        setColor(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setColor(_ color: NSColor?) {
        let base = color ?? .white
        // A colourless cover gets a quieter white: full-strength white would
        // be the brightest thing in the panel.
        let strength: CGFloat = color == nil ? 0.6 : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.colors = [base.withAlphaComponent(0.6 * strength).cgColor,
                       base.withAlphaComponent(0.05).cgColor]
        line.strokeColor = base.withAlphaComponent(0.85 * strength).cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        fillShape.frame = bounds
        line.frame = bounds
        CATransaction.commit()
        renderFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    private func updateLink() {
        let wanted = isAnimating && window != nil
        if wanted, link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !wanted, let link {
            link.invalidate()
            self.link = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) { renderFrame() }

    private func renderFrame() {
        let target = Self.levels(from: source?.bands ?? [], animating: isAnimating,
                                 at: CACurrentMediaTime())
        if shown.count != target.count { shown = target }
        for i in shown.indices { shown[i] += (target[i] - shown[i]) * 0.35 }

        let (open, closed) = Self.paths(for: shown, in: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.path = open
        fillShape.path = closed
        CATransaction.commit()
    }

    /// Wave heights, 0...1.
    ///
    /// The raw bands make a poor wave, for two reasons the first version of
    /// this showed. A loud mix puts every band between about 0.6 and 0.8, so
    /// the shape is a near-flat line; and music has far less energy up top,
    /// so the right third lay dead on the baseline. Three steps fix that:
    ///
    /// 1. Tilt the treble up — about 12 dB across the range, the usual
    ///    "pink" correction visualisers make so a balanced mix looks level.
    /// 2. Raise to a power, which pulls the quieter bands down further than
    ///    the loud ones, so peaks stand out from their neighbours.
    /// 3. Scale the frame so its peak sits near the top. Quiet passages get
    ///    less of a lift (the gain is capped), so loudness still shows.
    ///
    /// Then tapered to nothing at both ends, so the wave rises out of the
    /// baseline instead of starting and ending in mid-air.
    static func levels(from bands: [Float], animating: Bool, at time: TimeInterval) -> [CGFloat] {
        let count = bands.isEmpty ? 24 : bands.count
        let raw: [Double]
        if !animating {
            raw = Array(repeating: 0.06, count: count)            // at rest: a calm line
        } else if bands.isEmpty {
            raw = (0..<count).map { i in                           // no signal: a slow swell
                let x = Double(i)
                let travel: Double = sin(time * 1.6 - x * 0.42)
                let breathe: Double = sin(time * 0.55 + x * 0.17)
                return 0.45 + 0.35 * travel * breathe
            }
        } else {
            let span = Double(max(count - 1, 1))
            let shaped = bands.enumerated().map { i, band -> Double in
                let tilted = min(Double(max(band, 0)) + 0.22 * Double(i) / span, 1)
                return pow(tilted, 1.8)
            }
            let gain = 0.92 / max(shaped.max() ?? 0, 0.35)
            raw = shaped.map { $0 * gain }
        }
        return raw.enumerated().map { i, level in
            let edge = sin(.pi * (Double(i) + 0.5) / Double(count))
            return CGFloat(min(max(level, 0), 1) * pow(edge, 0.6))
        }
    }

    /// The curve through the levels, as an open line and as a closed shape
    /// down to the baseline. Catmull-Rom, so it passes through every band
    /// rather than approximating them; control points are kept between the
    /// baseline and the top, or a steep neighbour makes it dip below zero.
    static func paths(for levels: [CGFloat], in rect: CGRect) -> (CGPath, CGPath) {
        let open = CGMutablePath()
        guard levels.count > 1, rect.width > 0, rect.height > 0 else {
            return (open, open)
        }
        let baseline = rect.minY + 1
        let amplitude = rect.height - 2.5
        let step = rect.width / CGFloat(levels.count - 1)
        let points = levels.enumerated().map { i, level in
            CGPoint(x: rect.minX + CGFloat(i) * step, y: baseline + level * amplitude)
        }
        func clampY(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: min(max(p.y, baseline), baseline + amplitude))
        }

        open.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i]
            let p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = clampY(CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6))
            let c2 = clampY(CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            open.addCurve(to: p2, control1: c1, control2: c2)
        }

        let closed = open.mutableCopy()!
        closed.addLine(to: CGPoint(x: points.last!.x, y: rect.minY))
        closed.addLine(to: CGPoint(x: points.first!.x, y: rect.minY))
        closed.closeSubpath()
        return (open, closed)
    }
}

/// The beat flash: the accent wash, brighter, fading out over a third of a
/// second on every beat.
///
/// Done in Core Animation because the SwiftUI version — animating the wash's
/// opacity — re-rendered the whole notch for a third of every beat, which at
/// 120 BPM doubled the app's CPU (4.5% → 8.7%). A `CABasicAnimation` runs in
/// the render server: once added, the app does no work at all until the next
/// beat.
struct BeatBloom: NSViewRepresentable {
    var shape: NotchShape
    var color: Color?
    var expanded: Bool
    var beat: Int

    func makeNSView(context: Context) -> BeatBloomView { BeatBloomView() }

    func updateNSView(_ view: BeatBloomView, context: Context) {
        view.update(shape: shape, color: color.map { NSColor($0) }, expanded: expanded)
        view.pulse(beat)
    }
}

final class BeatBloomView: NSView {
    private let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()
    private var shape = NotchShape()
    private var lastBeat: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        gradient.opacity = 0
        gradient.mask = mask
        // Unit space with the origin at the bottom left: top-leading to
        // bottom-trailing, the same diagonal as the SwiftUI wash beneath.
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.locations = [0, 0.45, 1]
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(shape: NotchShape, color: NSColor?, expanded: Bool) {
        self.shape = shape
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let color {
            // The SwiftUI wash's stops, scaled by the bloom strength: drawn on
            // top of it at full opacity, this is the wash at its brightest.
            let bloom = CGFloat(NotchMetrics.beatWashBloom)
            let stops: [CGFloat] = expanded ? [0.55, 0.16, 0] : [0.38, 0.18, 0.06]
            gradient.colors = stops.map { color.withAlphaComponent($0 * bloom).cgColor }
            gradient.isHidden = false
        } else {
            gradient.isHidden = true
        }
        CATransaction.commit()
        layoutLayers()
    }

    /// Flashes once per new beat number. The first value seen is only
    /// recorded: appearing on screen is not a beat.
    func pulse(_ beat: Int) {
        defer { lastBeat = beat }
        guard let lastBeat, beat != lastBeat, !gradient.isHidden else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.32
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        gradient.add(fade, forKey: "beat")
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    /// Clipped to the notch silhouette by its own mask rather than trusting
    /// SwiftUI's clip to reach into a platform view. The shape's path is in
    /// SwiftUI's top-left space; the layer's origin is bottom-left.
    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        mask.frame = bounds
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        mask.path = shape.path(in: bounds).cgPath.copy(using: &flip)
        CATransaction.commit()
    }
}

/// The volume level, shown for a moment after scrolling on the notch.
struct VolumeMeter: View {
    var level: Float
    /// Sized for the collapsed pill's wing rather than the expanded panel.
    var compact: Bool

    var body: some View {
        HStack(spacing: compact ? 3 : 6) {
            Image(systemName: level <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: compact ? 8 : 11, weight: .medium))
                .frame(width: compact ? 10 : 18)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white)
                    .frame(width: max(compact ? 2 : 3, (compact ? 16 : 64) * CGFloat(level)))
            }
            .frame(width: compact ? 16 : 64, height: compact ? 3 : 4)
        }
        .foregroundStyle(.white.opacity(0.85))
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

/// The notch's frame, silhouette and fills, animated as one unit.
///
/// Three things had to end up in one `Animatable` modifier:
///
/// 1. A plain `.frame(width:height:)` reports its *final* size to the parent
///    and renders the *animated* size centred in that slot, so an opening
///    panel started in the middle of its final area. An animatable modifier
///    re-runs its body with the interpolated size, so layout is real on
///    every frame.
/// 2. Even then, SwiftUI animates the view's *position* on its own, a frame
///    ahead of the layout-driven size — and the shape sat a few points below
///    the notch while it grew: the "little gap". Aligning to the top of a
///    constant outer frame *inside* this body sidesteps that: results of an
///    animatable body are applied directly, never re-animated, and the node
///    the parent places never changes size or position at all.
/// 3. The clip, the hit shape and the fills must use the *same* interpolated
///    radii as each other, so they are built here from the same numbers.
struct NotchFrame: ViewModifier, Animatable {
    var size: CGSize
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// What to draw under the content, given the current silhouette.
    var background: (NotchShape) -> AnyView

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(size.width, size.height),
                           AnimatablePair(topRadius, bottomRadius))
        }
        set {
            size = CGSize(width: newValue.first.first, height: newValue.first.second)
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
        content
            .frame(width: size.width, height: size.height)
            .background(background(shape))
            // Both states are laid out at their final size and clipped, so
            // the content is revealed by the growing box rather than
            // re-laid-out on every frame of it.
            .clipShape(shape)
            // Hit-test the silhouette only — the rest of the panel stays
            // click-through so you can still reach the menu bar beside it.
            .contentShape(shape)
            // Fill whatever the window is and pin the shape to its top
            // centre. Not a fixed canvas size: the hosting view reports a
            // fixed frame as the content's intrinsic size, and AppKit then
            // refuses to shrink the window below it — the pill window stayed
            // 640 wide at the origin meant for a 303-wide one, 168pt right of
            // the notch. The window's size is the controller's business; the
            // controller never resizes it mid-animation, so this outer frame
            // is constant while anything inside moves.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
