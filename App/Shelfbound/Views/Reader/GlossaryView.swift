import LibraryKit
import ShelfCore
import SwiftUI

/// A work's glossary: names, places and terms that recur in a web novel. Terms are
/// underlined in the reader; tapping one shows its note.
@MainActor
struct GlossaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: WorkKey
    @State private var editing: GlossaryEntry?
    @State private var query = ""

    var body: some View {
        let entries = (model.record(key)?.glossary ?? [])
            .filter { query.isEmpty || $0.term.localizedCaseInsensitiveContains(query) || $0.note.localizedCaseInsensitiveContains(query) }
            .sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        List {
            ForEach(entries) { entry in
                Button { editing = entry } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.term).font(.headline).foregroundStyle(.primary)
                        if !entry.note.isEmpty { Text(entry.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                    }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { entries[$0].id }
                model.updateRecord(key) { $0.glossary.removeAll { ids.contains($0.id) } }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No terms yet", systemImage: "character.book.closed")
                } description: {
                    Text("Add names and terms you want to remember. They're underlined while you read, and a tap shows your note.")
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Glossary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { editing = GlossaryEntry(term: "", note: "") } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add term")
            }
        }
        .sheet(item: $editing) { entry in
            NavigationStack { GlossaryEditor(key: key, entry: entry) }.presentationDetents([.medium])
        }
    }
}

@MainActor
struct GlossaryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: WorkKey
    let entry: GlossaryEntry
    @State private var term: String
    @State private var note: String

    init(key: WorkKey, entry: GlossaryEntry) {
        self.key = key
        self.entry = entry
        _term = State(initialValue: entry.term)
        _note = State(initialValue: entry.note)
    }

    var body: some View {
        Form {
            TextField("Term, like Lin Feng or Qi Condensation", text: $term)
                .font(.headline)
            TextField("Note", text: $note, axis: .vertical)
                .lineLimit(3...8)
        }
        .navigationTitle(entry.term.isEmpty ? "New term" : entry.term)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.updateRecord(key) { record in
                        record.glossary.removeAll { $0.id == entry.id }
                        record.glossary.append(GlossaryEntry(id: entry.id, term: trimmed, note: note))
                    }
                    dismiss()
                }
                .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
