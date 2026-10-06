import AppKit
import SwiftUI

/// The open panel's "Aplikace" page: a grid of app shortcuts. Click to open
/// the app (the notch closes behind it); the last tile adds another. Removing
/// and reordering live in the settings window.
struct QuickAppsView: View {
    @AppStorage(Preferences.Key.quickApps) private var stored = ""

    /// Called after an app is opened.
    var onLaunch: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(62), spacing: 6), count: 6)

    var body: some View {
        let apps = QuickApps.urls(from: stored)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(apps, id: \.self) { url in
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
            }
            if apps.count < QuickApps.limit {
                Button { QuickApps.chooseAndAdd() } label: {
                    tile(icon: Image(systemName: "plus")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6)),
                         title: "Přidat",
                         dashed: true)
                }
                .buttonStyle(TransportButtonStyle())
                .help("Přidat aplikaci")
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
