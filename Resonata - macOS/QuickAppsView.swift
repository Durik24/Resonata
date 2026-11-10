import AppKit
import SwiftUI

/// The open panel's "Aplikace" page: a grid of app shortcuts. Click to open
/// the app (the notch closes behind it); the last tile adds another. Removing
/// and reordering live in the settings window.
struct QuickAppsView: View {
    @AppStorage(Preferences.Key.quickApps) private var stored = ""

    /// Called after an app is opened.
    var onLaunch: () -> Void

    /// One place in the grid: an app, or the tile that adds one.
    enum Tile: Hashable { case app(URL), add }

    private func tiles(_ apps: [URL]) -> [Tile] {
        apps.map(Tile.app) + (apps.count < QuickApps.limit ? [.add] : [])
    }

    var body: some View {
        let apps = QuickApps.urls(from: stored)
        EagerGrid(items: tiles(apps), columns: 6, spacing: 6, rowSpacing: 8) { item in
            switch item {
            case .app(let url):
                Button {
                    QuickApps.launch(url)
                    onLaunch()
                } label: {
                    tile(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable(),
                         title: QuickApps.name(of: url))
                }
                .buttonStyle(TransportButtonStyle())
                .help(QuickApps.name(of: url))
            case .add:
                Button { QuickApps.chooseAndAdd() } label: {
                    tile(icon: Image(systemName: "plus")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6)),
                         title: L.t("Add", "Přidat"),
                         dashed: true)
                }
                .buttonStyle(TransportButtonStyle())
                .help(L.t("Add an app", "Přidat aplikaci"))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        // Centred: the panel is wider than six tiles when the calendar is on.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func tile(icon: some View, title: String, dashed: Bool = false) -> some View {
        VStack(spacing: 4) {
            icon
                .frame(width: 40, height: 40)
                .background {
                    if dashed {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 62)
        .contentShape(Rectangle())
    }
}
