import LibraryKit
import ShelfCore
import SwiftUI

/// Every highlight in a work, grouped by chapter, with export of the lot as Markdown.
@MainActor
struct HighlightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: WorkKey
    @State private var editing: Highlight?

    var body: some View {
        let record = model.record(key)
        let highlights = record?.sortedHighlights ?? []
        List {
            if highlights.isEmpty {
                ContentUnavailableView(
                    "No highlights yet", systemImage: "highlighter",
                    description: Text("Select text in a chapter and choose Highlight or Add Note."))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups(highlights), id: \.chapterID) { group in
                Section(group.title) {
                    ForEach(group.items) { highlight in
                        Button { editing = highlight } label: { HighlightRow(highlight: highlight) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    model.removeHighlight(highlight.id, from: key)
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                            .contextMenu {
                                if let record {
                                    ShareLink(item: QuoteFormatter.quote(highlight, in: record)) {
                                        Label("Share Quote", systemImage: "square.and.arrow.up")
                                    }
                                    Button {
                                        UIPasteboard.general.string = QuoteFormatter.quote(highlight, in: record)
                                    } label: { Label("Copy Quote", systemImage: "doc.on.doc") }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Highlights")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            if let record, !highlights.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: QuoteFormatter.markdown(record), subject: Text(record.title)) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(item: $editing) { highlight in
            NavigationStack { HighlightEditor(key: key, highlight: highlight) }.presentationDetents([.medium, .large])
        }
    }

    private struct ChapterGroup {
        var chapterID: String
        var title: String
        var items: [Highlight]
    }

    private func groups(_ highlights: [Highlight]) -> [ChapterGroup] {
        var out: [ChapterGroup] = []
        for highlight in highlights {
            if out.last?.chapterID == highlight.chapterID {
                out[out.count - 1].items.append(highlight)
            } else {
                out.append(ChapterGroup(chapterID: highlight.chapterID, title: highlight.chapterTitle.isEmpty ? "Chapter" : highlight.chapterTitle, items: [highlight]))
            }
        }
        return out
    }
}

@MainActor
private struct HighlightRow: View {
    let highlight: Highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(highlight.exact)
                .font(.system(.body, design: .serif))
                .lineLimit(6)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.yellow).frame(width: 3)
                }
            if !highlight.note.isEmpty {
                Text(highlight.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Shows one highlight, edits its note, shares it as a quote, or deletes it.
@MainActor
struct HighlightEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: WorkKey
    let highlight: Highlight
    @State private var note: String
    @FocusState private var noteFocused: Bool

    init(key: WorkKey, highlight: Highlight) {
        self.key = key
        self.highlight = highlight
        _note = State(initialValue: highlight.note)
    }

    var body: some View {
        Form {
            Section {
                Text(highlight.exact)
                    .font(.system(.body, design: .serif))
                    .textSelection(.enabled)
            } footer: {
                Text(highlight.chapterTitle)
            }
            Section("Note") {
                TextField("What you thought", text: $note, axis: .vertical)
                    .lineLimit(3...10)
                    .focused($noteFocused)
            }
            if let record = model.record(key) {
                Section {
                    ShareLink(item: QuoteFormatter.quote(withNote, in: record)) {
                        Label("Share Quote", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        model.removeHighlight(highlight.id, from: key)
                        dismiss()
                    } label: {
                        Label("Delete Highlight", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Highlight")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if note != highlight.note { model.setHighlightNote(highlight.id, note: note, in: key) }
                    dismiss()
                }
            }
        }
        .onAppear { if highlight.note.isEmpty { noteFocused = true } }
    }

    private var withNote: Highlight {
        var h = highlight
        h.note = note
        return h
    }
}
