import LibraryKit
import RepoKit
import ShelfCore
import SourceKit
import SwiftUI

/// Finds a work on the other installed sources and moves it there, keeping progress.
@MainActor
struct MigrateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: WorkRecord
    let onMigrated: (WorkKey) -> Void

    struct Candidate: Identifiable {
        let source: InstalledSource
        let work: WorkSummary
        var id: String { "\(source.id)/\(work.id)" }
    }

    @State private var candidates: [Candidate] = []
    @State private var searching = false
    @State private var query = ""
    @State private var selected: Candidate?
    @State private var loaded: (work: Work, chapters: [Chapter])?
    @State private var loadingSelection = false
    @State private var error: String?

    var body: some View {
        List {
            if let selected {
                confirmation(selected)
            } else {
                Section {
                    if searching && candidates.isEmpty { HStack { Spacer(); ProgressView(); Spacer() } }
                    if !searching && candidates.isEmpty {
                        Text("No other source has this title. Try another search.").foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { candidate in
                        Button { Task { await choose(candidate) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                WorkCard(work: candidate.work, format: candidate.work.format ?? candidate.source.manifest.defaultFormat)
                                Text(candidate.source.manifest.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Read chapters, your place, reading settings and glossary move with it, matched by chapter number. Downloads from \(model.sourceName(record.key.sourceID)) are removed.")
                }
            }
            if let error { Section { Text(error).foregroundStyle(Color.shelfWarning) } }
        }
        .navigationTitle("Move to another source")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search other sources")
        .onSubmit(of: .search) { Task { await search(query) } }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task {
            query = record.title
            await search(record.title)
        }
    }

    @ViewBuilder
    private func confirmation(_ candidate: Candidate) -> some View {
        Section {
            WorkCard(work: candidate.work, format: candidate.work.format ?? candidate.source.manifest.defaultFormat)
            if let loaded {
                let preview = Migration.preview(record, onto: loaded.chapters)
                LabeledContent("Chapters", value: "\(preview.oldChapterCount) → \(preview.newChapterCount)")
                LabeledContent("Read chapters matched", value: "\(preview.matchedRead) of \(preview.totalRead)")
                if let position = preview.position {
                    LabeledContent("Continue from", value: position.title)
                }
                Button("Move to \(candidate.source.manifest.name)") {
                    let key = WorkKey(sourceID: candidate.source.id, workID: candidate.work.id)
                    model.migrate(record.key, to: key, summary: candidate.work, work: loaded.work, chapters: loaded.chapters)
                    dismiss()
                    onMigrated(key)
                }
                .bold()
            } else if loadingSelection {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } header: {
            Text("On \(candidate.source.manifest.name)")
        }
        Section {
            Button("Pick a different one") {
                selected = nil
                loaded = nil
            }
        }
    }

    private func search(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false }
        candidates = []
        error = nil
        let sources = model.searchableSources.filter { $0.id != record.key.sourceID }
        await withTaskGroup(of: [Candidate].self) { group in
            for source in sources {
                guard let runtime = try? model.runtime(for: source.id) else { continue }
                group.addTask {
                    guard let page = try? await runtime.search(query: text, page: 1) else { return [] }
                    return page.results.prefix(5).map { Candidate(source: source, work: $0) }
                }
            }
            for await found in group { candidates += found }
        }
        // Likely matches first.
        let title = record.title
        candidates.sort { TitleMatcher.similarity(title, $0.work.title) > TitleMatcher.similarity(title, $1.work.title) }
    }

    private func choose(_ candidate: Candidate) async {
        selected = candidate
        loaded = nil
        loadingSelection = true
        defer { loadingSelection = false }
        do {
            let runtime = try model.runtime(for: candidate.source.id)
            async let work = runtime.getWork(id: candidate.work.id)
            async let chapters = runtime.getChapters(workID: candidate.work.id)
            loaded = try await (work, chapters)
        } catch {
            self.error = error.readable
            selected = nil
        }
    }
}
