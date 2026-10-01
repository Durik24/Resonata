import AppKit
import SwiftUI

/// Press feedback for the transport controls. `.plain` gives none at all, so
/// clicks felt like they hadn't registered even when they had.
struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The volume level, shown for a moment after scrolling on the notch.
struct VolumeMeter: View {
    var level: Float
    /// Sized for the collapsed pill's wing rather than the expanded panel.
    var compact: Bool

    var body: some View {
        HStack(spacing: compact ? 3 : 6) {
            Image(systemName: level <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: compact ? 8 : 11, weight: .medium))
                .frame(width: compact ? 10 : 18)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white)
                    .frame(width: max(compact ? 2 : 3, (compact ? 16 : 64) * CGFloat(level)))
            }
            .frame(width: compact ? 16 : 64, height: compact ? 3 : 4)
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}
