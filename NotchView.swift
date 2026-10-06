import AppKit
import SwiftUI

struct NotchView: View {
    @ObservedObject var model: NotchModel

    var notchSize: CGSize { model.notchSize }
    /// No hardware cutout means the middle of the pill is usable space.
    private var hasRealNotch: Bool { model.hasRealNotch }

    /// Non-nil while the user owns the playhead — during a drag, and briefly
    /// after, so the once-a-second poll doesn't yank the knob back to where the
    /// track was before the seek landed.
    // Not private: the expanded panel lives in an extension in
    // NotchView+Expanded.swift and reads this state and the animations.
    @State var scrubFraction: Double?
    @State var isScrubbing = false
    @State var isHoveringBar = false

    /// Accent pulled from the album art, used for the background wash.
    @State private var accent: Color?

    // Settings, read here so a change in the settings window re-renders.
    @AppStorage(Preferences.Key.animationSpeed) private var speedSetting = AnimationSpeed.normal.rawValue
    @AppStorage(Preferences.Key.waveColour) private var waveColourSetting = WaveColour.album.rawValue
    @AppStorage(Preferences.Key.customWaveColour) private var customWaveHex = "#FFFFFF"
    @AppStorage(Preferences.Key.showLyrics) private var showLyricsSetting = true

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

    /// The song-change peek: the playing pill, slid out to the right past the
    /// bars by this much, with the title and artist in the new space.
    static let peekExtraWidth: CGFloat = 160

    /// The peek's shape — shared with `NotchPanelController` so the window,
    /// the shape and the click target agree. Same height as the pill: it
    /// grows sideways only.
    static func peekSize(notch: CGSize) -> CGSize {
        CGSize(width: notch.width + NotchMetrics.collapsedContentWidth + peekExtraWidth,
               height: notch.height + NotchMetrics.collapsedExtraHeight)
    }

    /// The window during a peek: symmetric about the notch, so the notch
    /// stays at its centre, and wide enough for the shape shifted right.
    static func peekWindowSize(notch: CGSize) -> CGSize {
        let shape = peekSize(notch: notch)
        return CGSize(width: shape.width + peekExtraWidth, height: shape.height)
    }

    /// How far right the peeking shape sits, so its left edge doesn't move.
    static let peekShift: CGFloat = peekExtraWidth / 2

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
    var settle: Animation { (AnimationSpeed(rawValue: speedSetting) ?? .normal).spring }

    /// Fades for content swapping in place: artwork, titles, glyphs.
    var fade: Animation { (AnimationSpeed(rawValue: speedSetting) ?? .normal).fade }

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
        if !model.isExpanded, model.peeking { return Self.peekSize(notch: notchSize) }
        return model.isExpanded
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
                // A soft wave along the bottom edge, in the album's colour.
                // It has the bottom strip to itself — the content stops above
                // it (see `expanded`) — so it never runs through the lyrics.
                if model.isExpanded && model.tab == .music {
                    MusicWave(color: waveColour,
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
                xOffset: !model.isExpanded && model.peeking ? Self.peekShift : 0,
                background: { shape in
                    AnyView(ZStack {
                        shape.fill(Self.panelBlack)
                        // The wash sits *over* solid black, never replacing
                        // it — the collapsed pill has to stay black enough to
                        // pass for the bezel, and a gradient that bottoms out
                        // anywhere above black would give the illusion away.
                        shape.fill(accentWash)
                        // The same wash, brighter, flashing and fading as
                        // each new lyric line begins. Core Animation runs the
                        // fade, so a flash costs this app nothing per frame.
                        GlowFlash(shape: shape,
                                  color: colourable ? accent : nil,
                                  expanded: model.isExpanded,
                                  pulse: model.pulse)
                    })
                }
            ))
            // Size animations live *here*, on the shape, and never at the
            // root: the root frame fills the window, whose height jumps
            // 32 → 280 on open, and animating that frame centred the whole
            // panel mid-window and slid it up. Here, the shape grows out of
            // the notch and the frame around it simply snaps to fit.
            .animation(settle, value: model.isExpanded)
            .animation(settle, value: model.showsCollapsedContent)
            .animation(settle, value: model.showsLyricsRow)
            .animation(settle, value: model.peeking)
            .animation(settle, value: model.tab)
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

    /// The wave's colour, per the setting: the album's accent, white (nil),
    /// or the user's own.
    private var waveColour: Color? {
        switch WaveColour(rawValue: waveColourSetting) ?? .album {
        case .album: accent
        case .white: nil
        case .custom: Color(hex: customWaveHex)
        }
    }

    /// Something is playing: the bars and the wave move.
    private var isLive: Bool {
        model.track?.isPlaying == true || NotchModel.debugForceLive
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
            closedRow.transition(Self.crossfade)
        }
    }

    /// The closed pill's content, peeking or not.
    ///
    /// One row for both, never a swap. Crossfading between a "closed" view
    /// and a "peek" view drew two sets of bars for a moment — the old one
    /// re-centred in the growing pill — a ghost mid-slide. Here the artwork
    /// and bars are the same views the whole time, pinned left where they
    /// always sit; peeking only fades the title and artist in beside them as
    /// the pill slides out to the right.
    private var closedRow: some View {
        HStack(spacing: 0) {
            collapsed
                .padding(.leading, NotchMetrics.collapsedInset)
            if model.peeking {
                VStack(alignment: .leading, spacing: 1) {
                    // Without a cutout the title is already in the pill's middle.
                    if hasRealNotch {
                        Text(model.track?.title ?? "")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text(model.track?.artist ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The fade rides on the transition only. An `.animation`
                // keyed on `peeking` around the whole row also animated the
                // row's *position* on the fade's curve, against the shape's
                // spring — measured: artwork and bars drifting 8pt right
                // mid-slide and creeping back.
                .transition(.opacity.animation(fade))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
                        .animation(fade, value: model.track?.title)
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
        .animation(fade, value: model.showsCollapsedContent)
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
                MusicBars(barCount: 3,
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
}
