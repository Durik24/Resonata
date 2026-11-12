import AppKit
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

    /// Set by `NotchPanelController`. Opens the panel — for a file dragged
    /// onto the closed notch.
    var open: (() -> Void)?

    /// Set by `NotchPanelController`. Closes the panel — after opening an app
    /// from the "Aplikace" page, say.
    var close: (() -> Void)?

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
    /// The music page shows a few lines of the lyrics at once, in the
    /// player's place — see `NotchView.lyricsColumn`. Kept from song to song
    /// until it's switched back; a song without lyrics shows the player.
    @Published var showingLyrics = false

    /// Apple Music's heart for this track; nil hides it (any other player).
    @Published var isFavorite: Bool?

    /// The open panel's size. Lives on the model so the panel controller
    /// and the view size from one number. Narrower without the calendar.
    /// How much the closed pill's sizes scale for this cutout — see
    /// `NotchMetrics.referenceNotchHeight`.
    var pillScale: CGFloat { NotchMetrics.scale(notchHeight: notchSize.height, real: hasRealNotch) }

    var expandedWidth: CGFloat {
        Preferences.showCalendar ? NotchView.expandedWidth : NotchView.expandedWidthWithoutCalendar
    }
    var expandedHeight: CGFloat { NotchView.expandedHeight }

    /// The closed pill is slid out to the right — for the song (`songPeeking`)
    /// or for an `activity` such as the charger. Each keeps its own flag and
    /// its own timer: with one shared flag, the song peek's timer ended the
    /// charging peek half-way and the other way round.
    @Published private(set) var peeking = false

    /// A new song just started, or the pointer rests on the notch: the song
    /// slides out with its title — see `SongPeek`.
    @Published var songPeeking = false { didSet { updatePeeking() } }

    /// The activity is slid out. Separate from `activity` itself, which
    /// stays set while the pill slides back in, so the text going out of
    /// sight is still the activity's — cleared together, the song's title
    /// flashed up in its place mid-slide.
    @Published var activityShown = false { didSet { updatePeeking() } }

    private func updatePeeking() {
        let slidOut = songPeeking || activityShown
        if peeking != slidOut { peeking = slidOut }
    }

    /// Something other than the song, shown in the closed notch for a
    /// moment — see `NotchActivity`.
    @Published var activity: NotchActivity?

    /// The pointer is on the closed pill, which swells a little under it.
    @Published var hovering = false

    /// Which page the open panel shows.
    @Published var tab: PanelTab = .music {
        willSet {
            let forward = newValue.index >= tab.index
            if forward != tabForward { tabForward = forward }
        }
        didSet {
            guard tab != oldValue else { return }
            // The page follows a run-loop pass later — see `shownTab`.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.shownTab != self.tab else { return }
                    self.shownTab = self.tab
                }
            }
        }
    }
    /// The last page change went right along the strip: the new page slides
    /// in from the right and the old one out to the left.
    @Published private(set) var tabForward = true
    /// The page drawn, a pass behind `tab`. The old page leaves by the
    /// transition it had at its last render, so the direction has to be in
    /// place a render *before* the page changes — otherwise turning back the
    /// other way slid the old page out on the wrong side.
    @Published private(set) var shownTab: PanelTab = .music

    /// The collapsed pill carries artwork and waveform only while playback is
    /// live. Idle, it shrinks back to the bare cutout — but `track` is still
    /// there, so a click brings up the last song and its play button.
    var showsCollapsedContent: Bool {
        musicLive || activity != nil || timerRunning || claude?.showsInPill == true
            || vibe?.showsInPill == true
    }

    /// Something is playing, or was until a moment ago: the cover and the
    /// bars are in the pill. Otherwise Claude Code's rings may have it.
    var musicLive: Bool { track != nil && !isIdle }

    /// Claude Code's limit and what its sessions are doing; nil while that
    /// is switched off — see `ClaudeMonitor`. While a session works or waits,
    /// its ring is in the closed notch, music or no music.
    @Published var claude: ClaudeStatus?

    /// Mistral Vibe's allowance and what its sessions are doing; nil while
    /// that is switched off — see `VibeMonitor`.
    @Published var vibe: VibeStatus?

    /// Set by the app. Asks Claude Code and Vibe for their limits now — a
    /// click on the rings.
    var refreshClaude: (() -> Void)?

    /// The rings of the closed notch, as things stand.
    var pillRings: (cover: PillRing?, bars: PillRing?) {
        PillRing.placed(claude: claude, vibe: vibe, musicLive: musicLive)
    }

    /// The timer is running or paused: the closed notch shows the time left.
    @Published var timerRunning = false

    /// `RESONATA_DEBUG_FORCE_LIVE=1`: animate the pill as if music were
    /// playing, so the cost of playback can be measured on a silent machine.
    static let debugForceLive =
        ProcessInfo.processInfo.environment["RESONATA_DEBUG_FORCE_LIVE"] == "1"
}

/// One of Claude Code's or Vibe's rings in the closed notch.
struct PillRing: Equatable {
    enum Tool: Equatable { case claude, claudeWeek, vibe }

    var tool: Tool
    var fraction: Double?
    var state: ClaudeStatus.State = .idle

    /// Which ring goes where the cover is and which where the bars are.
    ///
    /// Nothing playing, the pill is theirs: Claude Code's session on the
    /// left and Vibe's month on the right — or, with only one of the two
    /// switched on, that one on the left, and Claude Code's week opposite
    /// its session. While music plays the cover stays, and a session that is
    /// working or waiting takes the bars' place until it is done; one
    /// waiting for you comes before one still working.
    nonisolated static func placed(claude: ClaudeStatus?, vibe: VibeStatus?, musicLive: Bool)
        -> (cover: PillRing?, bars: PillRing?) {
        let session = claude.map { PillRing(tool: .claude, fraction: $0.fraction, state: $0.state) }
        let month = vibe.map { PillRing(tool: .vibe, fraction: $0.fraction, state: $0.state) }
        if musicLive {
            let active = [session, month].compactMap { $0 }.filter { $0.state != .idle }
            return (nil, active.first { $0.state == .waiting } ?? active.first)
        }
        let claudeShows = claude?.showsInPill == true, vibeShows = vibe?.showsInPill == true
        switch (claudeShows, vibeShows) {
        case (true, true): return (session, month)
        case (true, false):
            return (session, claude?.weekFraction.map { PillRing(tool: .claudeWeek, fraction: $0) })
        case (false, true): return (month, nil)
        case (false, false): return (nil, nil)
        }
    }

    /// The rings in the open panel's top bar, for as many as `room` allows
    /// and never fewer than one: each tool's own first, then Claude Code's
    /// week beside its session. With room for one and both tools switched
    /// on, the one with a session waiting or working has it — Claude Code's
    /// otherwise; the hover card says the rest either way.
    nonisolated static func inTopBar(claude: ClaudeStatus?, vibe: VibeStatus?, room: Int) -> [PillRing] {
        var rings: [PillRing] = []
        if let claude, claude.showsInPill {
            rings.append(PillRing(tool: .claude, fraction: claude.fraction, state: claude.state))
        }
        if let vibe, vibe.showsInPill {
            rings.append(PillRing(tool: .vibe, fraction: vibe.fraction, state: vibe.state))
        }
        if rings.count > max(room, 1) {
            let one = rings.first { $0.state == .waiting } ?? rings.first { $0.state == .working } ?? rings[0]
            return [one]
        }
        if rings.count < room, rings.first?.tool == .claude, let week = claude?.weekFraction {
            rings.insert(PillRing(tool: .claudeWeek, fraction: week), at: 1)
        }
        return rings
    }
}

/// The open panel's pages, switched from the icons beside the notch.
enum PanelTab: String, CaseIterable, Identifiable {
    case music, notes, apps, timer, shelf, usage

    /// The pages there are right now: the usage page only while Claude
    /// Code or Mistral Vibe is switched on in Settings.
    static var shown: [PanelTab] {
        allCases.filter { $0 != .usage || Preferences.showClaude || Preferences.showVibe }
    }

    var id: String { rawValue }

    /// Its place in the strip, from 0.
    var index: Int { Self.shown.firstIndex(of: self) ?? 0 }

    /// The page `step` places along the strip — one to the right for 1, to
    /// the left for -1 — or nil past either end. No wrapping round: swiping
    /// on past the last page stopping there says where you are.
    func neighbour(_ step: Int) -> PanelTab? {
        let all = Self.shown
        let i = index + step
        return all.indices.contains(i) ? all[i] : nil
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .notes: "checklist"
        case .apps: "square.grid.2x2"
        case .timer: "timer"
        case .shelf: "tray"
        case .usage: "gauge.with.needle"
        }
    }

    var title: String {
        switch self {
        case .music: L.t("Music", "Hudba")
        case .notes: L.t("Notes and to-dos", "Poznámky a úkoly")
        case .apps: L.t("Apps", "Aplikace")
        case .timer: L.t("Timer", "Časovač")
        case .shelf: L.t("Shelf", "Police")
        case .usage:
            switch (Preferences.showClaude, Preferences.showVibe) {
            case (true, true): L.t("Claude Code and Vibe limits", "Limity Claude Code a Vibe")
            case (false, true): L.t("Mistral Vibe limits", "Limity Mistral Vibe")
            default: L.t("Claude Code limits", "Limity Claude Code")
            }
        }
    }
}
