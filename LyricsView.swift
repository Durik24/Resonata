import AppKit
import SwiftUI

/// The line of lyric being sung, under the artist. Slides up to the next one
/// as the song moves on.
struct LyricsView: View {
    var lines: [LyricLine]?
    /// A lookup is still running for this track.
    var pending: Bool
    var track: Track?
    /// Centred under a centred title, leading under a leading one.
    var alignment: Alignment = .center

    var body: some View {
        Group {
            if let lines {
                // Ten times a second is plenty for something that changes
                // every few seconds, and it is only built while the panel is
                // open.
                TimelineView(.animation(minimumInterval: 1 / 10,
                                        paused: track?.isPlaying != true)) { context in
                    let position = track?.position(at: context.date) ?? 0
                    let index = LyricsStore.index(in: lines, at: position)
                    let text = index.flatMap { lines.indices.contains($0) ? lines[$0].text : nil } ?? ""
                    line(text.isEmpty ? "\u{266A}" : text, opacity: 0.8)
                        // Keyed on the index, so each new line is a fresh view
                        // that slides in rather than the old text morphing.
                        .id(index)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: index)
                }
            } else if pending {
                line("\u{2026}", opacity: 0.35)
            } else {
                line("Text nenalezen", opacity: 0.35)
            }
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity, alignment: alignment)
        .clipped()
    }

    private func line(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
