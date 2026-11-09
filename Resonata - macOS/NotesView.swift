import AppKit
import SwiftUI

/// The open panel's "Poznámky a úkoly" page: a free-form note on the left, a
/// to-do list on the right. Saved as you type — see `NotesStore`.
struct NotesView: View {
    @ObservedObject var store: NotesStore
    @State private var newTodo = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            note
            todos
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var note: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.06))
            TextEditor(text: $store.note)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            if store.note.isEmpty {
                Text("Poznámka…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 200)
    }

    private var todos: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                TextField("Nový úkol", text: $newTodo)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        store.add(newTodo)
                        newTodo = ""
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.06)))

            if store.todos.isEmpty {
                Text("Žádné úkoly")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 4)
                    .padding(.leading, 2)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(store.todos) { todo in row(todo) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(_ todo: NotesStore.Todo) -> some View {
        HStack(spacing: 7) {
            Button { store.toggle(todo.id) } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(todo.done ? 0.45 : 0.8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(todo.text)
                .font(.system(size: 12))
                .strikethrough(todo.done)
                .foregroundStyle(.white.opacity(todo.done ? 0.4 : 0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { store.remove(todo.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Smazat")
        }
    }
}
