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

/// The lyrics page: the line being sung big, bold and white — wrapped onto
/// a second line rather than cut short — with the line just sung small and
/// faded above it and the coming lines dim below. As each line begins the
/// column glides up and the new one grows into the big line's place. The
/// edges fade out, so lines drift in and out rather than being cut off.
/// Click a line and the song jumps to it.
///
/// The bigger view of the lyrics: the one line under the artist says where
/// the song is, this says where it's going. Redrawn only as a line begins,
/// like that one.
struct LyricsList: View {
    var lines: [LyricLine]
    var track: Track?
    /// Kept for the call site; the sung line is white, the album's colour
    /// stays in the header.
    var accent: Color
    /// Called with a line's time when it is clicked.
    var onSeek: (TimeInterval) -> Void

    /// Where the sung line's top sits, from the column's top: room for
    /// one faded line above it.
    static let currentTop: CGFloat = 22
    static let sungSize: CGFloat = 16
    static let otherSize: CGFloat = 12

    var body: some View {
        TimelineView(.explicit(LyricsView.lineStarts(lines, track: track, after: Date()))) { context in
            let position = track?.position(at: context.date) ?? 0
            column(current: LyricsView.row(for: LyricsStore.index(in: lines, at: position)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.55), location: 0.16),
                .init(color: .black, location: 0.3),
                .init(color: .black, location: 0.72),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    /// Every row stacked, slid so the sung one's top is at `currentTop`.
    /// Rows differ in height (the sung one is bigger and may wrap), so the
    /// slide is an alignment guide on that row rather than a row count times
    /// a fixed height; animating `current` glides the column.
    private func column(current: Int) -> some View {
        let rows = LyricsView.rows(lines)
        let live = Self.clickable(rows: rows.count, current: current)
        // The overlay is as big as the space it's given, whatever the
        // column's height: a ZStack took the whole column's height as its
        // own and pushed the header out of the panel.
        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .alignmentGuide(.sungLine) { _ in Self.currentTop }
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .sungLine)) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(rows.indices, id: \.self) { i in
                        row(rows[i], at: i, current: current)
                            // Only the sung row names the guide: a stack
                            // takes it from the first row that does, so a
                            // value on every row sent the column far away.
                            .modifier(SungLineGuide(on: i == current))
                            // Clipping hides the far rows but doesn't stop
                            // them taking clicks: one above would lie over
                            // the header.
                            .allowsHitTesting(live.contains(i))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: current)
    }

    private func row(_ text: String, at i: Int, current: Int) -> some View {
        let sung = i == current
        let past = i < current
        return Button {
            // Row 0 is the intro note before the first line.
            onSeek(i == 0 ? 0 : lines[i - 1].time)
        } label: {
            Text(text)
                .font(.system(size: sung ? Self.sungSize : Self.otherSize,
                              weight: sung ? .bold : .semibold))
                .foregroundStyle(.white.opacity(sung ? 1 : past ? 0.22 : 0.42))
                .lineLimit(sung ? 2 : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L.t("Jump to this line", "Skočit na tenhle řádek"))
    }

    /// The rows that take clicks: the faded one above the sung line, it,
    /// and the three under it — what can be seen.
    nonisolated static func clickable(rows: Int, current: Int) -> Range<Int> {
        let lower = min(max(current - 1, 0), rows)
        return lower..<min(max(current + 4, lower), rows)
    }

    /// The song's name without what follows it in brackets — "(feat. …)",
    /// "[From …]", "- Remastered 2011" — so the artist fits beside it in the
    /// lyrics page's header. The whole title when nothing would be left.
    nonisolated static func shortTitle(_ title: String) -> String {
        var t = title
        if let dash = t.range(of: " - ") { t = String(t[..<dash.lowerBound]) }
        while let open = t.lastIndex(where: { $0 == "(" || $0 == "[" }), open != t.startIndex {
            t = String(t[..<open])
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? title : t
    }
}

/// Puts the lyrics page's alignment guide on a row's top — only on the
/// row being sung.
private struct SungLineGuide: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on {
            content.alignmentGuide(.sungLine) { d in d[.top] }
        } else {
            content
        }
    }
}

private extension VerticalAlignment {
    /// The top of the line being sung, in the lyrics page.
    enum SungLine: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.top] }
    }
    static let sungLine = VerticalAlignment(SungLine.self)
}
