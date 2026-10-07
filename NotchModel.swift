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

    /// A new song just started: the closed pill slides out to the right to
    /// show its title for a moment — see `SongPeek`.
    @Published var peeking = false

    /// The pointer is on the closed pill, which swells a little under it.
    @Published var hovering = false

    /// Which page the open panel shows.
    @Published var tab: PanelTab = .music

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

/// The open panel's pages, switched from the icons beside the notch.
enum PanelTab: String, CaseIterable, Identifiable {
    case music, notes, apps

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .notes: "checklist"
        case .apps: "square.grid.2x2"
        }
    }

    var title: String {
        switch self {
        case .music: "Hudba"
        case .notes: "Poznámky a úkoly"
        case .apps: "Aplikace"
        }
    }
}
