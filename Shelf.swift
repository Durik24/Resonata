import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files parked on the notch: drop them on it, drag them off later.
///
/// Kept as paths — links to the files where they are, not copies — in
/// UserDefaults, so the shelf survives a restart and costs no disk space.
/// Files moved or deleted since are dropped from the shelf.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    /// Enough for an armful; more and it stops being a shelf.
    static let limit = 30

    @Published private(set) var items: [URL] = []

    private let key = "shelfItems"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }
        prune()
    }

    func add(_ urls: [URL]) {
        var list = items
        for url in urls where url.isFileURL && !list.contains(url) {
            list.append(url)
        }
        items = Array(list.suffix(Self.limit))
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// Forgets files that are no longer where they were.
    func prune() {
        let kept = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if kept != items {
            items = kept
            save()
        }
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: key)
    }
}

/// The open panel's "Police" page.
struct ShelfView: View {
    @ObservedObject var shelf: ShelfStore
    @State private var targeted = false

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 8)]

    var body: some View {
        Group {
            if shelf.items.isEmpty {
                empty
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(shelf.items, id: \.self) { tile($0) }
                        }
                    }
                    .scrollIndicators(.never)
                    HStack {
                        Text("Přetáhni soubor kamkoli — zkopíruje se. Klik ho otevře.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                        Spacer()
                        Button("Vyčistit") { shelf.clear() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { shelf.prune() }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 26, weight: .medium))
            Text("Přetáhni sem soubory")
                .font(.system(size: 13, weight: .semibold))
            Text("Odložíš si je tu a pak je odtáhneš, kam potřebuješ.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .foregroundStyle(.white.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }

    private func tile(_ url: URL) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 40, height: 40)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 72)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            Button { shelf.remove(url) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55), .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Odebrat z police")
        }
        .onTapGesture { NSWorkspace.shared.open(url) }
        // Dragging it out hands over the file itself; the place it's dropped
        // decides — Finder copies it, a mail draft attaches it.
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.path)
    }
}
