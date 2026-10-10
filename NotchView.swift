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
    // Not private: the expanded panel and its calendar take their colour
    // from it too.
    @State var accent: Color?

    // Settings, read here so a change in the settings window re-renders.
    @AppStorage(Preferences.Key.animationSpeed) private var speedSetting = AnimationSpeed.normal.rawValue
    @AppStorage(Preferences.Key.waveColour) private var waveColourSetting = WaveColour.album.rawValue
    @AppStorage(Preferences.Key.customWaveColour) private var customWaveHex = "#FFFFFF"
    @AppStorage(Preferences.Key.showLyrics) var showLyricsSetting = true
    @AppStorage(Preferences.Key.showCalendar) var showCalendarSetting = true

    /// The open panel with the calendar beside the player, and without it.
    static let expandedWidth: CGFloat = 640
    static let expandedWidthWithoutCalendar: CGFloat = 470
    /// The calendar column, right of the divider.
    static let calendarWidth: CGFloat = 196
    /// Tall enough to seat the content below the cutout without cramping it.
    /// The same for every page and every song: the lyric is one line under
    /// the artist now, so the panel no longer grows when lyrics turn up.
    static let expandedHeight: CGFloat = 204
    /// The wave's strip along the bottom of the expanded panel.
    static let waveHeight: CGFloat = 26

    /// The song-change peek: the playing pill, slid out to the right past the
    /// bars by this much, with the title and artist in the new space.
    static let peekExtraWidth: CGFloat = 118

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

    /// The closed row fades back in on close as before, but on open it's
    /// gone in the first frame. Fading it out — 0.22 s, and even 0.08 s —
    /// drew it, the song peek's title included, into the panel growing
    /// around it: a blip of text at the top of every open from a hover peek.
    ///
    /// On close it waits for the open content's 0.1 s fade before coming
    /// in, so the two never show at once.
    private static let closedSwap = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeInOut(duration: 0.22).delay(0.08)),
        removal: .identity
    )

    /// The open panel's content comes into focus rather than just fading:
    /// NotchNook's scale-and-blur. The scale half already comes from the
    /// content growing with the box (see `content`), so this adds the blur.
    ///
    /// On close it just goes, quickly. A view being removed keeps its last
    /// layout, so the open panel's content stayed full size while the box
    /// shrank around it, and over 0.32 s of blur it lay across the closed
    /// row fading in — two titles on top of each other mid-close.
    private static let focusIn = AnyTransition.asymmetric(
        insertion: AnyTransition.modifier(
            active: Defocus(radius: 10, opacity: 0),
            identity: Defocus(radius: 0, opacity: 1)
        ).animation(.easeOut(duration: 0.32)),
        removal: .opacity.animation(.easeOut(duration: 0.1))
    )

    /// The closed pill's size, swollen by `hoverGrowth` when asked — shared
    /// with `NotchPanelController`, so the window and the click target grow
    /// with the shape.
    static func collapsedSize(model: NotchModel, grown: Bool) -> CGSize {
        let base = CGSize(
            width: model.notchSize.width
                + (model.showsCollapsedContent ? NotchMetrics.collapsedContentWidth : 0),
            height: model.notchSize.height + NotchMetrics.collapsedExtraHeight)
        guard grown else { return base }
        return CGSize(width: base.width + NotchMetrics.hoverGrowth.width,
                      height: base.height + NotchMetrics.hoverGrowth.height)
    }

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
    static let panelBlack = Color(
        nsColor: NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
    )

    private var size: CGSize {
        if !model.isExpanded, model.peeking {
            // The swell stays on through a hover peek — the pointer is still there.
            let peek = Self.peekSize(notch: notchSize)
            guard model.hovering else { return peek }
            return CGSize(width: peek.width + NotchMetrics.hoverGrowth.width,
                          height: peek.height + NotchMetrics.hoverGrowth.height)
        }
        if !model.isExpanded, model.hovering { return Self.collapsedSize(model: model, grown: true) }
        return model.isExpanded
            ? CGSize(width: model.expandedWidth, height: model.expandedHeight)
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
            .animation(settle, value: model.peeking)
            .animation(settle, value: model.tab)
            // The hover swell eases in and out without overshoot. A bouncy
            // one, on top of the song sliding out, looked like the notch
            // wobbling.
            .animation(.spring(response: 0.3, dampingFraction: 1), value: model.hovering)
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
            .transition(Self.focusIn)
        } else {
            closedRow.transition(Self.closedSwap)
        }
    }

    /// The closed pill's content, peeking or not.
    ///
    /// One row for both, never a swap. Crossfading between a "closed" view
    /// and a "peek" view drew two sets of bars for a moment — the old one
    /// re-centred in the growing pill — a ghost mid-slide. Here the artwork
    /// and bars are the same views the whole time. The artwork is pinned to
    /// the left edge, which stays put; the bars ride the right edge, so they
    /// travel out with the slide and back in with it. The title and artist
    /// fade into the slot the bars leave behind, just past the cutout.
    private var closedRow: some View {
        HStack(spacing: 0) {
            artwork(size: collapsedSlot)
            middle
                .frame(width: collapsedMiddleWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The title and artist are an overlay, not part of the row, so they
        // never push on its layout. In the row, their fixed width overflowed
        // the pill mid-slide and the overflow got centred — measured: the
        // artwork and bars both stepping 3.6pt left and back.
        .overlay(alignment: .leading) {
            // A clear box exactly as wide as the room left of the bars — a
            // flexible frame would size itself to the text instead — with the
            // text laid on it at its full width and clipped. Sliding back,
            // the bars push the text out of sight instead of running over it.
            //
            // Always there, only its opacity changing. A view being removed
            // keeps its last frame for the length of its fade, so a text that
            // came and went with `peeking` was never clipped on the way out.
            Color.clear
                .overlay(alignment: .leading) {
                    // A fixed width, not "whatever is left": a flexible one
                    // re-truncated the title on every frame of the slide back.
                    peekText
                        .frame(width: Self.peekExtraWidth - Self.peekTextGap - Self.peekTextIndent,
                               alignment: .leading)
                        // The fade is scoped to the opacity alone. An
                        // `.animation` keyed on `peeking` around the row also
                        // animated the row's *position* on the fade's curve,
                        // against the shape's spring — measured: artwork and
                        // bars drifting 8pt right mid-slide and creeping back.
                        .animation(fade) { $0.opacity(model.peeking ? 1 : 0) }
                }
                .mask {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.peekTextGap)
                    }
                }
                .padding(.leading, collapsedSlot + collapsedMiddleWidth + Self.peekTextIndent)
                .padding(.trailing, collapsedSlot + NotchMetrics.waveformNudge
                                    + Self.peekTextGap)
        }
        // The bars are laid over the row against its trailing edge, which is
        // the pill's own right edge less the inset — the same margin the
        // artwork keeps on the left, closed or peeking.
        .overlay(alignment: .trailing) { waveform }
        .padding(.horizontal, NotchMetrics.collapsedInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(model.showsCollapsedContent ? 1 : 0)
        .animation(fade, value: model.showsCollapsedContent)
    }

    // MARK: Collapsed — artwork on the left of the notch, waveform on the right

    /// What sits between the artwork and the bars when closed.
    @ViewBuilder
    private var middle: some View {
        if hasRealNotch {
            // The hardware cutout. Nothing can go in it — there are no pixels
            // there — so the title has nowhere to live on the laptop screen.
            Color.clear
        } else {
            // On an external display that same gap is ordinary black, so the
            // title goes where the cutout would have been. Same shape, same
            // positions either side — just with the middle used.
            Text(model.track?.title ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .animation(fade, value: model.track?.title)
                .padding(.horizontal, 8)
        }
    }

    /// Title over artist, left-aligned, while peeking.
    private var peekText: some View {
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
    }

    /// How far past the cutout's gap the peek text starts. Flush with the
    /// slot the bars left, it sat tight against the notch.
    private static let peekTextIndent: CGFloat = 8

    /// Room kept between the peek text and the bars to its right, and the
    /// length of the fade the text runs out through when it doesn't fit.
    private static let peekTextGap: CGFloat = 10

    /// The artwork's square and the bars' slot opposite it — the same width,
    /// so the outer margins and the gaps to the cutout both match.
    private var collapsedSlot: CGFloat { notchSize.height - 8 }

    /// The closed row between the artwork and the bars: the cutout plus a
    /// small gap either side of it.
    private var collapsedMiddleWidth: CGFloat {
        collapsedContentWidth - 2 * collapsedSlot - NotchMetrics.waveformNudge
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
            .frame(width: collapsedSlot, height: 16)
            // Trailing padding shifts only the wave inward — the artwork sits
            // on the far side of the cutout and stays put.
            .padding(.trailing, NotchMetrics.waveformNudge)
    }
}

/// Blur plus opacity, for `NotchView.focusIn`.
private struct Defocus: ViewModifier {
    var radius: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}
