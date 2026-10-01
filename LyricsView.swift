import AppKit
import SwiftUI

/// Three lines of lyric: the one being sung, bright, with its neighbours dimmed
/// either side. Slides up a line as the song moves on.
struct LyricsView: View {
    var lines: [LyricLine]
    var track: Track?

    var body: some View {
        // Ten times a second is plenty for something that changes every few
        // seconds, and it is only built while the panel is open.
        TimelineView(.animation(minimumInterval: 1 / 10,
                                paused: track?.isPlaying != true)) { context in
            let position = track?.position(at: context.date) ?? 0
            let index = LyricsStore.index(in: lines, at: position)
            rows(around: index)
                // Keyed on the index, so each new line is a fresh view that
                // slides in rather than the old text morphing into the new.
                .id(index)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: index)
        }
        .clipped()
    }

    private func rows(around index: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            row(at: (index ?? 0) - 1, dim: true)
            row(at: index, dim: false)
            row(at: (index ?? -1) + 1, dim: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(at index: Int?, dim: Bool) -> some View {
        let text = index.flatMap { lines.indices.contains($0) ? lines[$0].text : nil } ?? ""
        Text(text.isEmpty ? "\u{2026}" : text)
            .font(.system(size: dim ? 11 : 13, weight: dim ? .regular : .semibold))
            .foregroundStyle(.white.opacity(dim ? 0.38 : 0.95))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: 15)
    }
}
