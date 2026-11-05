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

    /// Counts up once as each new line of synced lyrics begins — see
    /// `LyricPulse`. Each change flashes the colour wash.
    @Published var pulse = 0

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

    /// Apple Music's heart for this track; nil hides it (any other player).
    @Published var isFavorite: Bool?

    /// The open panel's size. Lives on the model so the panel controller
    /// and the view size from one number. Narrower without the calendar.
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
        willSet { tabForward = newValue.index >= tab.index }
    }
    /// The last page change went right along the strip — the new page
    /// slides in from that side.
    @Published private(set) var tabForward = true

    /// The collapsed pill carries artwork and waveform only while playback is
    /// live. Idle, it shrinks back to the bare cutout — but `track` is still
    /// there, so a click brings up the last song and its play button.
    var showsCollapsedContent: Bool {
        (track != nil && !isIdle) || volumeLevel != nil || activity != nil || timerRunning
    }

    /// The timer is running or paused: the closed notch shows the time left.
    @Published var timerRunning = false

    /// Set for a moment after the volume is scrolled, so the notch can show
    /// the new level. Nil the rest of the time.
    @Published var volumeLevel: Float?

    /// `RESONATA_DEBUG_FORCE_LIVE=1`: animate the pill as if music were
    /// playing, so the cost of playback can be measured on a silent machine.
    static let debugForceLive =
        ProcessInfo.processInfo.environment["RESONATA_DEBUG_FORCE_LIVE"] == "1"
}

/// The open panel's pages, switched from the icons beside the notch.
enum PanelTab: String, CaseIterable, Identifiable {
    case music, notes, apps, timer, shelf

    var id: String { rawValue }

    /// Its place in the strip, from 0.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// The page `step` places along the strip — one to the right for 1, to
    /// the left for -1 — or nil past either end. No wrapping round: swiping
    /// on past the last page stopping there says where you are.
    func neighbour(_ step: Int) -> PanelTab? {
        let all = Self.allCases
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
        }
    }

    var title: String {
        switch self {
        case .music: "Hudba"
        case .notes: "Poznámky a úkoly"
        case .apps: "Aplikace"
        case .timer: "Časovač"
        case .shelf: "Police"
        }
    }
}
