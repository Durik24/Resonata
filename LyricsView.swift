import AppKit
import SwiftUI

/// The lyric being sung under the artist, with the next line waiting dimly
/// below it. As the song moves on the whole column scrolls up a line: the
/// sung line slides off the top as it fades, the waiting one brightens into
/// its place, and the one after rises in from below — the text moves on to
/// the next line rather than being swapped for it.
struct LyricsView: View {
    var lines: [LyricLine]?
    /// A lookup is still running for this track.
    var pending: Bool
    var track: Track?
    /// Centred under a centred title, leading under a leading one.
    var alignment: Alignment = .center

    /// One line's height; the view shows two.
    static let lineHeight: CGFloat = 15

    var body: some View {
        Group {
            if let lines {
                // Redrawn exactly when a line begins, not ten times a second:
                // the line only changes every few seconds, and each redraw is
                // a layout pass. Paused, there's nothing to schedule at all.
                TimelineView(.explicit(Self.lineStarts(lines, track: track, after: Date()))) { context in
                    let position = track?.position(at: context.date) ?? 0
                    let current = Self.row(for: LyricsStore.index(in: lines, at: position))
                    column(Self.rows(lines), current: current)
                }
            } else if pending {
                line("\u{2026}", opacity: 0.35)
            } else {
                line("Text nenalezen", opacity: 0.35)
            }
        }
        .frame(height: Self.lineHeight * 2, alignment: .top)
        .frame(maxWidth: .infinity, alignment: alignment)
        .clipped()
    }

    /// Every line, stacked, slid up so `current` is at the top. Only the
    /// current line and the next are visible; the rest are transparent, so
    /// a line fades as it scrolls out and appears as it scrolls in.
    private func column(_ rows: [String], current: Int) -> some View {
        VStack(alignment: alignment.horizontal, spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                line(rows[i], opacity: i == current ? 0.85 : i == current + 1 ? 0.3 : 0)
                    .frame(height: Self.lineHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .offset(y: -CGFloat(current) * Self.lineHeight)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: current)
    }

    /// The rows shown: a note before the first line — the intro — then the
    /// lines, with a note for the empty ones the instrumental breaks leave.
    nonisolated static func rows(_ lines: [LyricLine]) -> [String] {
        ["\u{266A}"] + lines.map { $0.text.isEmpty ? "\u{266A}" : $0.text }
    }

    /// The row of `rows` for a line index: the intro note while no line has
    /// begun yet.
    nonisolated static func row(for index: Int?) -> Int { (index ?? -1) + 1 }

    /// The moments the coming lines begin, from the track's playhead — and
    /// now, for the first draw.
    nonisolated static func lineStarts(_ lines: [LyricLine], track: Track?,
                                       after now: Date) -> [Date] {
        guard let track, track.isPlaying else { return [now] }
        let position = track.position(at: now)
        return [now] + lines.lazy
            .filter { $0.time > position }
            .map { now.addingTimeInterval($0.time - position) }
    }

    private func line(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
