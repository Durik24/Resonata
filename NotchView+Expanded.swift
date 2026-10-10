import AppKit
import SwiftUI

// The expanded panel: the top bar, the player, the calendar.
// Split out of NotchView.swift; the collapsed pill and the frame live there.

extension NotchView {

    // `expanded`, `artwork(size:)` and `loadArtwork` aren't private: the main
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
                .padding(.bottom, model.tab == .music ? Self.waveHeight + 10 : 18)
            topBar
        }
        // Laid out at the final width from frame one — see `clipShape` above.
        .frame(width: model.expandedWidth - 40, alignment: .leading)
    }

    @ViewBuilder
    private var page: some View {
        switch model.tab {
        case .music:
            musicPage
        case .notes:
            NotesView(store: NotesStore.shared)
        case .apps:
            QuickAppsView(onLaunch: { model.close?() })
        }
    }

    /// The strip either side of the cutout — real screen at the top of the
    /// panel that nothing else used. Pages on the left, the Mac's own bits
    /// on the right.
    private var topBar: some View {
        HStack(spacing: 0) {
            pageSwitcher
            Spacer(minLength: notchSize.width)
            statusItems
        }
        .frame(height: notchSize.height)
    }

    private var pageSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases) { tab in
                Button { model.tab = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(model.tab == tab ? 0.95 : 0.4))
                        .frame(width: 28, height: 20)
                        .background(Capsule().fill(.white.opacity(model.tab == tab ? 0.14 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
    }

    private var statusItems: some View {
        HStack(spacing: 10) {
            if model.canSwitchScreens {
                iconButton("rectangle.on.rectangle", help: "Přepnout notch na další monitor") {
                    model.switchScreen?()
                }
            }
            iconButton("gearshape", help: "Nastavení") {
                SettingsWindowController.shared.show()
            }
            // Re-read every half minute while the panel is open; closed, the
            // view doesn't exist and nothing is read at all.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let battery = Battery.read() {
                    HStack(spacing: 4) {
                        Text("\(battery.percent) %")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
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
    }

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

    /// Where the title, artist and lyric line sit in the player column.
    private var textAlignment: Alignment { showCalendarSetting ? .center : .leading }

    private var expandedMain: some View {
        HStack(spacing: 24) {
            artwork(size: 110)
                .overlay(alignment: .bottomTrailing) {
                    sourceBadge.offset(x: 7, y: 7)
                }

            // Centred over the bar beside the calendar, the way the layout was
            // drawn; without the calendar the column is wide, and centred text
            // floated off on its own in the middle of the panel — so it sits
            // against the cover instead.
            VStack(alignment: textAlignment.horizontal, spacing: 0) {
                Text(model.track?.title ?? "Nic nehraje")
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
                if showLyricsSetting && model.track != nil {
                    LyricsView(lines: model.lyrics, pending: model.lyricsPending,
                               track: model.track, alignment: textAlignment)
                        .padding(.top, 3)
                }

                Spacer(minLength: 6)

                progress

                HStack(spacing: 22) {
                    button("backward.fill") { send(.previous) }
                    // Standard transport convention: the glyph shows what a
                    // click will do, so playing offers pause and vice versa.
                    button(model.track?.isPlaying == true ? "pause.fill" : "play.fill", size: 19) {
                        send(.playPause)
                    }
                    button("forward.fill") { send(.next) }
                    Spacer(minLength: 0)
                    if let level = model.volumeLevel {
                        VolumeMeter(level: level, compact: false)
                            .transition(.opacity)
                    }
                    if let favorite = model.isFavorite {
                        button(favorite ? "heart.fill" : "heart") {
                            MusicFavorite.toggle { value in
                                if let value { model.isFavorite = value }
                            }
                        }
                        .help(favorite ? "Odebrat z oblíbených" : "Přidat do oblíbených")
                    }
                }
                .animation(fade, value: model.volumeLevel == nil)
                // The buttons' hit areas are wider than their glyphs; this
                // lines the first glyph up with the start of the bar.
                .padding(.leading, -7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Image(nsImage: Self.icon(for: app))
                    .resizable()
                    .frame(width: 24, height: 24)
                    .padding(2)
                    .background(Circle().fill(Self.panelBlack))
                    .contentShape(Circle())
            }
            .buttonStyle(TransportButtonStyle())
            .help("Otevřít \(model.track?.source ?? "")")
        }
    }

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

    /// Fetches and decodes the artwork off the main thread.
    static func loadArtwork(_ url: URL?) async -> NSImage? {
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

    private func button(_ symbol: String, size: CGFloat = 15,
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
    }
}
