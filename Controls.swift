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
