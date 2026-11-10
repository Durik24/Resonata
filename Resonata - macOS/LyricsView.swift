import AppKit
import SwiftUI

/// The lyric being sung, one line under the artist. As the song moves on
/// the column of lines scrolls up by one: the sung line slides off the top
/// as it fades and the next rises into its place from below — the text
/// moves on to the next line rather than being swapped for it.
struct LyricsView: View {
    var lines: [LyricLine]?
    /// A lookup is still running for this track.
    var pending: Bool
    var track: Track?
    /// Centred under a centred title, leading under a leading one.
    var alignment: Alignment = .center

    /// One line's height, and the view's.
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
                line(L.t("No lyrics found", "Text nenalezen"), opacity: 0.35)
            }
        }
        .frame(height: Self.lineHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: alignment)
        .clipped()
    }

    /// Every line, stacked, slid up so `current` is in view. Only the
    /// current line is opaque, so a line fades as it scrolls out and appears
    /// as it scrolls in.
    private func column(_ rows: [String], current: Int) -> some View {
        VStack(alignment: alignment.horizontal, spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                line(rows[i], opacity: i == current ? 0.85 : 0)
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

/// A few lines of the song at once, the one being sung picked out and kept
/// in the middle; the column slides up a line as each new one begins. Click
/// a line and the song jumps to it.
///
/// The bigger view of the lyrics: the one line under the artist says where
/// the song is, this says where it's going. Redrawn only as a line begins,
/// like that one.
struct LyricsList: View {
    var lines: [LyricLine]
    var track: Track?
    /// The line being sung is drawn in this.
    var accent: Color
    /// Called with a line's time when it is clicked.
    var onSeek: (TimeInterval) -> Void

    static let rowHeight: CGFloat = 18
    /// Lines in view. An odd number, so the sung one has a middle to sit in.
    static let visible = 5

    var body: some View {
        TimelineView(.explicit(LyricsView.lineStarts(lines, track: track, after: Date()))) { context in
            let position = track?.position(at: context.date) ?? 0
            rows(current: LyricsStore.index(in: lines, at: position))
        }
        .frame(height: Self.rowHeight * CGFloat(Self.visible), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func rows(current: Int?) -> some View {
        let window = Self.window(count: lines.count, current: current, visible: Self.visible)
        // One more line above and below, out of sight past the clip: a line
        // then arrives and leaves by sliding, already drawn, rather than
        // fading in on the spot while its neighbours move over it.
        let drawn = max(window.lowerBound - 1, 0)..<min(window.upperBound + 1, lines.count)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(drawn), id: \.self) { index in
                row(index, sung: index == current)
                    // Clipping hides the spare lines but doesn't stop them
                    // taking clicks: the one above lies over the title row.
                    .allowsHitTesting(window.contains(index))
            }
        }
        .offset(y: -CGFloat(window.lowerBound - drawn.lowerBound) * Self.rowHeight)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: window.lowerBound)
    }

    private func row(_ index: Int, sung: Bool) -> some View {
        let text = lines[index].text.isEmpty ? "\u{266A}" : lines[index].text
        return Button { onSeek(lines[index].time) } label: {
            Text(text)
                .font(.system(size: 12, weight: sung ? .semibold : .medium))
                .foregroundStyle(sung ? accent : Color.white.opacity(0.4))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L.t("Jump to this line", "Skočit na tenhle řádek"))
        .animation(.easeOut(duration: 0.25), value: sung)
    }

    /// The lines in view around `current`: it in the middle where there are
    /// enough either side of it, the first or the last few at the ends of
    /// the song. All of them when the song has no more than fit.
    nonisolated static func window(count: Int, current: Int?, visible: Int) -> Range<Int> {
        guard count > visible else { return 0..<max(count, 0) }
        let start = min(max((current ?? 0) - visible / 2, 0), count - visible)
        return start..<(start + visible)
    }
}
