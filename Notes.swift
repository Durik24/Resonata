import Foundation

/// The open panel's note and to-do list, saved as one small JSON file in
/// Application Support. Stays on this Mac; nothing is synced anywhere.
@MainActor
final class NotesStore: ObservableObject {

    static let shared = NotesStore()

    struct Todo: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var done = false
    }

    private struct Saved: Codable {
        var note: String
        var todos: [Todo]
    }

    @Published var note = "" { didSet { scheduleSave() } }
    @Published private(set) var todos: [Todo] = [] { didSet { scheduleSave() } }

    let url: URL
    private var loading = false
    private var pendingSave: DispatchWorkItem?

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Resonata", isDirectory: true)
            .appendingPathComponent("notes.json")
    }

    init(url: URL = NotesStore.defaultURL) {
        self.url = url
        load()
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todos.append(Todo(text: trimmed))
    }

    func toggle(_ id: Todo.ID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].done.toggle()
    }

    func remove(_ id: Todo.ID) {
        todos.removeAll { $0.id == id }
    }

    /// Clears every ticked-off item at once.
    func removeDone() {
        todos.removeAll(where: \.done)
    }

    private func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        note = saved.note
        todos = saved.todos
    }

    /// Typing changes the note on every keystroke; writing the file each time
    /// would be pointless. Half a second after the last change is soon enough
    /// that quitting straight after typing still keeps it.
    private func scheduleSave() {
        guard !loading else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Saved(note: note, todos: todos))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Resonata: could not save notes: \(error)")
        }
    }
}
