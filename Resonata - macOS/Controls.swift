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

/// A grid built all at once, row by row — in place of `LazyVGrid` on the
/// panel's pages.
///
/// A lazy grid makes its cells a moment after the page appears, outside the
/// page's transition, so on a page turn they turned up already in their
/// final places while the rest of the page was still sliding in: the
/// timer's buttons sat across the app icons, then the ring slid in beside
/// them. These grids hold a dozen or two items, so laziness bought nothing.
struct EagerGrid<Item: Hashable, Cell: View>: View {
    var items: [Item]
    var columns: Int
    var spacing: CGFloat
    var rowSpacing: CGFloat
    @ViewBuilder var cell: (Item) -> Cell

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(Self.rows(items, columns: columns), id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { cell($0) }
                }
            }
        }
    }

    /// `items` cut into rows of `columns`, the last one possibly shorter.
    nonisolated static func rows(_ items: [Item], columns: Int) -> [[Item]] {
        let n = max(columns, 1)
        return stride(from: 0, to: items.count, by: n).map { Array(items[$0..<min($0 + n, items.count)]) }
    }
}
