import AppKit
import SwiftUI

// The expanded panel: the top bar, the player, the calendar.
// Split out of NotchView.swift; the collapsed pill and the frame live there.

extension NotchView {

    // `expanded` and `artwork(size:)` aren't private: the main
    // view in NotchView.swift uses them.

    // MARK: Expanded — artwork, metadata, scrubber, transport

    var expanded: some View {
        ZStack(alignment: .top) {
            page
                // Clear the hardware cutout. The expanded panel is centred and
                // wider than the notch, but its top strip runs *behind* the
                // notch, where there is no screen at all. Anything drawn there
                // simply doesn't exist. Start below it.
                .padding(.top, notchSize.height + 8)
                // The music page leaves the bottom strip to the wave.
                .padding(.bottom, model.shownTab == .music ? Self.waveHeight + 10 : 18)
            topBar
        }
        // Laid out at the final width from frame one — see `clipShape` above.
        .frame(width: model.expandedWidth - 40, alignment: .leading)
    }

    /// The page, sliding sideways like a phone's: the new one in from the
    /// side it was turned to — the right for a page further along the strip
    /// — as the old one slides out the other way, both clipped by the panel.
    ///
    /// Both move by the same fixed distance, a page width and a gap, so they
    /// travel side by side. `.move(edge:)` moved each by its own width, and
    /// the pages differ: the old one fell behind the new, and for a moment
    /// the timer's ring lay across the app icons.
    private var page: some View {
        let distance = model.expandedWidth - 40 + 24
        let forward = model.tabForward
        return ZStack(alignment: .top) {
            pageContent
                .id(model.shownTab)
                .transition(.asymmetric(
                    insertion: .offset(x: forward ? distance : -distance),
                    removal: .offset(x: forward ? -distance : distance)))
        }
        .animation(Self.pageTurn, value: model.shownTab)
    }

    /// Quick off the mark and settling without a crawl: a spring left the
    /// last few points creeping in for a third of a second, which read as
    /// the page not quite arriving.
    static let pageTurn = Animation.timingCurve(0.2, 0.75, 0.25, 1, duration: 0.34)

    @ViewBuilder
    private var pageContent: some View {
        switch model.shownTab {
        case .music:
            musicPage
        case .notes:
            NotesView(store: NotesStore.shared)
        case .apps:
            QuickAppsView(onLaunch: { model.close?() })
        case .timer:
            TimerView(timer: .shared, accent: ActivityLook.orange)
        case .shelf:
            ShelfView(shelf: .shared, width: model.expandedWidth - 40)
        }
    }

    /// The strip either side of the cutout — real screen at the top of the
    /// panel that nothing else used. Pages on the left, the Mac's own bits
    /// on the right.
    private var topBar: some View {
        HStack(spacing: 0) {
            pageSwitcher
                .frame(width: stripWidth, alignment: .leading)
            Spacer(minLength: 0)
            statusItems
                .frame(width: stripWidth, alignment: .trailing)
        }
        .frame(height: notchSize.height)
    }

    /// The room either side of the cutout in the top bar, kept 8 pt clear of
    /// it. Narrow without the calendar: the fourth page icon, the timer's,
    /// used to sit half under the hardware notch — out of sight, and
    /// unreachable, the pointer slipping under the cutout on the way to it.
    private var stripWidth: CGFloat {
        (model.expandedWidth - 40 - notchSize.width) / 2 - 8
    }

    private var pageSwitcher: some View {
        let count = CGFloat(PanelTab.allCases.count)
        let gap: CGFloat = 3
        // As wide as there's room for, up to the usual 28.
        let iconWidth = min(28, ((stripWidth - gap * (count - 1)) / count).rounded(.down))
        return HStack(spacing: gap) {
            ForEach(PanelTab.allCases) { tab in
                Button { model.tab = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(model.tab == tab ? 0.95 : 0.4))
                        .frame(width: iconWidth, height: 20)
                        // One highlight that glides to the page chosen,
                        // rather than one fading out as another fades in.
                        .background {
                            if model.tab == tab {
                                Capsule().fill(.white.opacity(0.14))
                                    .matchedGeometryEffect(id: "page", in: pageHighlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
            }
        }
        .animation(Self.pageTurn, value: model.tab)
    }

    private var statusItems: some View {
        // The percentage goes first when room is short — the battery symbol
        // says much the same. Widths: icon buttons 22, the battery with its
        // percentage about 66, without it 20.
        let buttons: CGFloat = (model.canSwitchScreens ? 32 : 0) + 32
        let showPercent = buttons + 66 <= stripWidth
        return HStack(spacing: 10) {
            if model.canSwitchScreens {
                iconButton("rectangle.on.rectangle",
                           help: L.t("Move the notch to the next display", "Přepnout notch na další monitor")) {
                    model.switchScreen?()
                }
            }
            iconButton("gearshape", help: L.t("Settings", "Nastavení")) {
                SettingsWindowController.shared.show()
                // The panel floats above every window, the settings' too, and
                // a click in a window of our own isn't a click "outside": left
                // open, it sat on top of the window it had just opened.
                model.close?()
            }
            // Re-read every half minute while the panel is open; closed, the
            // view doesn't exist and nothing is read at all.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let battery = Battery.read() {
                    HStack(spacing: 4) {
                        if showPercent {
                            Text("\(battery.percent) %")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        }
                        Image(systemName: battery.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(battery.isLow ? .red : .white.opacity(0.85))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    /// Player on the left, the days and their events on the right.
    private var musicPage: some View {
        HStack(spacing: 0) {
            expandedMain
                .onAppear {
                    if NotchPanel.debugClick { NSLog("click: expanded body APPEARED") }
                }
            if showCalendarSetting {
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(width: 1)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 18)
                CalendarColumn(store: CalendarStore.shared, accent: accentText ?? Self.fallbackAccent)
                    .frame(width: Self.calendarWidth)
                    .padding(.top, 2)
            }
        }
        // Measured inside the page, under everything that moves it — the
        // page turn's slide, the open's zoom — so it's the layout's answer
        // and changes only when the layout does.
        .coordinateSpace(.named(Self.musicPageSpace))
        .onPreferenceChange(CoverInPage.self) { frame in
            if let frame, frame != coverInPage { coverInPage = frame }
        }
    }

    static let musicPageSpace = "musicPage"

    /// Today's circle and the event bars when nothing is playing to take a
    /// colour from.
    static let fallbackAccent = Color(red: 0.36, green: 0.6, blue: 1)

    /// The album accent lifted to read on near-black: as bright as it can be,
    /// a touch less saturated. The raw accent is picked for the background
    /// wash and is often far too dark for text.
    var accentText: Color? {
        guard let accent, let ns = NSColor(accent).usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(s, 0.6), brightness: max(b, 0.92))
    }

    /// The cover in the open panel; the column beside it matches its height.
    static let coverSize: CGFloat = 110

    /// Where the title, artist and lyric line sit in the player column.
    private var textAlignment: Alignment { showCalendarSetting ? .center : .leading }

    private var expandedMain: some View {
        HStack(spacing: 24) {
            artwork(size: Self.coverSize)
                // Where the flying cover lands is wherever this one is.
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: CoverInPage.self,
                                               value: proxy.frame(in: .named(Self.musicPageSpace)))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    sourceBadge.offset(x: Self.badgeOverhang, y: Self.badgeOverhang)
                }
                // The flying cover is standing in, badge and all — see
                // `flyingCover`. At once, both ways: this sits under the
                // close's spring (`Recede`), which took the change for its
                // own and faded this cover out beside the flying one.
                .opacity(coverFlies ? 0 : 1)
                .animation(nil, value: coverFlies)

            Group {
                if showLyricsSetting, model.showingLyrics, let lines = model.lyrics {
                    lyricsColumn(lines)
                } else {
                    playerColumn
                }
            }
            .foregroundStyle(.white)
            // Exactly the cover's height, so the title starts at its top edge
            // and the controls end at its bottom. Filling the page instead,
            // the column ran 9 pt past the cover at both ends. The negative
            // padding takes out the space inside the frames themselves —
            // above the title's capitals, below the buttons' glyphs —
            // measured at 3 pt and 5 pt.
            .padding(.top, -3)
            .padding(.bottom, -5)
            .frame(maxWidth: .infinity)
            .frame(height: Self.coverSize)
        }
    }

    /// Title, artist, the line being sung, the bar and the buttons.
    private var playerColumn: some View {
        // Centred over the bar beside the calendar, the way the layout was
        // drawn; without the calendar the column is wide, and centred text
        // floated off on its own in the middle of the panel — so it sits
        // against the cover instead.
        VStack(alignment: textAlignment.horizontal, spacing: 0) {
            Text(model.track?.title ?? L.t("Nothing playing", "Nic nehraje"))
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(fade, value: model.track?.title)
            Text(model.track?.artist ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accentText ?? .white.opacity(0.55))
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(fade, value: model.track?.artist)
                .padding(.top, 2)
            // Only for something lyrics are looked up for: under a podcast
            // or a film, "no lyrics found" was just noise.
            if showLyricsSetting, let track = model.track, LyricsStore.shouldLookUp(track) {
                lyricLine(track)
                    .padding(.top, 3)
            }

            Spacer(minLength: 6)

            progress

            HStack(spacing: 6) {
                HStack(spacing: 22) {
                    button("backward.fill", label: L.t("Previous", "Předchozí")) { send(.previous) }
                    // Standard transport convention: the glyph shows what a
                    // click will do, so playing offers pause and vice versa.
                    button(model.track?.isPlaying == true ? "pause.fill" : "play.fill", size: 19,
                           label: model.track?.isPlaying == true ? L.t("Pause", "Pozastavit")
                                                                 : L.t("Play", "Přehrát")) {
                        send(.playPause)
                    }
                    button("forward.fill", label: L.t("Next", "Další")) { send(.next) }
                }
                Spacer(minLength: 0)
                if let player = volumePlayer {
                    PlayerVolumeControl(player: player, tint: accentText ?? .white)
                        .layoutPriority(-1)
                        // A new view for each song, so the level is read
                        // again — the player's own slider may have moved.
                        .id(model.track?.title)
                }
                if let favorite = model.isFavorite {
                    let label = favorite ? L.t("Remove from favourites", "Odebrat z oblíbených")
                                         : L.t("Add to favourites", "Přidat do oblíbených")
                    button(favorite ? "heart.fill" : "heart", label: label) {
                        MusicFavorite.toggle { value in
                            if let value { model.isFavorite = value }
                        }
                    }
                    .help(label)
                }
            }
            // The buttons' hit areas are wider than their glyphs; this
            // lines the first glyph up with the start of the bar.
            .padding(.leading, -7)
        }
    }

    /// The line being sung. With lyrics to show, a click on it brings up
    /// more of the song — see `lyricsColumn`.
    @ViewBuilder
    private func lyricLine(_ track: Track) -> some View {
        let line = LyricsView(lines: model.lyrics, pending: model.lyricsPending,
                              track: track, alignment: textAlignment)
        if model.lyrics != nil {
            Button { model.showingLyrics = true } label: { line.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(L.t("Show more of the lyrics", "Zobrazit víc textu"))
                .accessibilityLabel(L.t("Show more of the lyrics", "Zobrazit víc textu"))
        } else {
            line
        }
    }

    /// A few lines of the song at once, in the player column's place: the
    /// one being sung picked out, and a click on any line jumps the song
    /// there. The arrow in its corner goes back to the player.
    private func lyricsColumn(_ lines: [LyricLine]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(model.track?.title ?? "")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Text(model.track?.artist ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentText ?? .white.opacity(0.55))
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 4)
                Button { model.showingLyrics = false } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportButtonStyle())
                .help(L.t("Back to the player", "Zpět k přehrávači"))
                .accessibilityLabel(L.t("Back to the player", "Zpět k přehrávači"))
            }
            .frame(height: 18)
            LyricsList(lines: lines, track: model.track, accent: accentText ?? .white) { time in
                guard let track = model.track else { return }
                seek(to: time, in: track.source)
            }
        }
    }

    /// The playing app's icon, tucked on the artwork's corner like a badge.
    /// Click it to bring the player forward.
    @ViewBuilder
    private var sourceBadge: some View {
        if let app = sourceApp {
            Button {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
                model.close?()
            } label: {
                sourceBadgePicture
                    .contentShape(Circle())
            }
            .buttonStyle(TransportButtonStyle())
            .help(L.t("Open \(model.track?.source ?? "")", "Otevřít \(model.track?.source ?? "")"))
            .accessibilityLabel(L.t("Open \(model.track?.source ?? "")", "Otevřít \(model.track?.source ?? "")"))
        }
    }

    /// How far the badge hangs off the cover's bottom right corner.
    static let badgeOverhang: CGFloat = 7

    /// The badge as a picture: the button's face, and what the flying cover
    /// carries in its corner.
    @ViewBuilder
    var sourceBadgePicture: some View {
        if let app = sourceApp {
            Image(nsImage: Self.icon(for: app))
                .resizable()
                .frame(width: 24, height: 24)
                .padding(2)
                .background(Circle().fill(Self.panelBlack))
        }
    }

    /// The player, when it has a volume of its own to set — Spotify or
    /// Apple Music. Then the slider shows.
    private var volumePlayer: PlayerVolume.Player? { PlayerVolume.player(for: model.track) }

    private var sourceApp: URL? {
        guard let track = model.track else { return nil }
        let id = track.bundleID ?? [
            "Spotify": "com.spotify.client",
            "Music": "com.apple.Music",
        ][track.source]
        return id.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Icons are looked up once per app — the panel redraws every second.
    private static var icons: [URL: NSImage] = [:]

    private static func icon(for app: URL) -> NSImage {
        if let cached = icons[app] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icons[app] = icon
        return icon
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

    @ViewBuilder
    private var progress: some View {
        if isLiveStream {
            liveRow
        } else {
            timedProgress
        }
    }

    /// Playing something with no length, even after a moment to be told it:
    /// a radio station, a live stream. There is nowhere to scrub to, and a
    /// bar stuck at the start over "0:00 / 0:00" read as broken.
    private var isLiveStream: Bool {
        guard let track = model.track else { return false }
        return Self.isLive(duration: track.duration, settled: liveSettled)
    }

    nonisolated static func isLive(duration: TimeInterval, settled: Bool) -> Bool {
        settled && duration <= 0
    }

    /// In the bar's place for a live stream: the same height, so nothing
    /// around it moves.
    private var liveRow: some View {
        VStack(spacing: 5) {
            Capsule().fill(.white.opacity(0.22))
                .frame(height: 4)
                .frame(height: 12)
            HStack(spacing: 5) {
                Circle().fill(ActivityLook.red).frame(width: 5, height: 5)
                Text(L.t("LIVE", "ŽIVĚ"))
                Spacer(minLength: 0)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
    }

    private var timedProgress: some View {
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
        //
        // As often as the bar moves a device pixel, not thirty times a second:
        // across ~600 pixels a four-minute song advances a pixel every 0.4 s,
        // and each redraw is a SwiftUI layout pass — measured as most of the
        // open panel's CPU. Never slower than twice a second, for the time
        // labels; never faster than 30 fps, for very short tracks.
        TimelineView(
            .animation(minimumInterval: Self.progressInterval(duration: model.track?.duration ?? 0),
                       paused: model.track?.isPlaying != true || isScrubbing)
        ) { context in
            progressBody(at: context.date)
        }
    }

    /// Seconds per device pixel of progress bar, within 1/30 s and 1/2 s.
    nonisolated static func progressInterval(duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 0.5 }
        return min(max(duration / 600, 1.0 / 30), 0.5)
    }

    private func progressBody(at date: Date) -> some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let shown = scrubFraction ?? playbackFraction(at: date)
                let active = isHoveringBar || isScrubbing
                let barHeight: CGFloat = active ? 6 : 4

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(accentText ?? .white)
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


    func artwork(size: CGFloat) -> some View {
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
        .animation(fade, value: model.artwork == nil)
        .animation(fade, value: model.track?.artworkURL)
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

    /// `label` is what VoiceOver reads: the glyph says nothing by itself.
    private func button(_ symbol: String, size: CGFloat = 15, label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                // play ⇄ pause morphs rather than snapping.
                .contentTransition(.symbolEffect(.replace))
                .animation(fade, value: symbol)
                // A 15pt glyph is a tiny target; pad the hit area out to
                // something you can actually hit without aiming.
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .accessibilityLabel(label)
    }
}

/// The big cover's frame in the music page, for the flying cover to land on.
struct CoverInPage: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
