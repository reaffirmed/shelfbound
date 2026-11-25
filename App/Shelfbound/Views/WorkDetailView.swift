import ShelfCore
import SwiftUI

struct WorkDetailView: View {
    @Environment(AppModel.self) private var model
    let route: WorkRoute

    @State private var work: Work?
    @State private var chapters: [Chapter] = []
    @State private var error: String?
    @State private var reading: ReaderRoute?

    var body: some View {
        List {
            Section {
                WorkRow(work: route.summary)
                if let work { metadata(work) }
            }

            if let summary = work?.summaryHTML {
                Section("Summary") { Text(summary.strippingHTML) }
            }

            if let downloads = work?.downloads, !downloads.isEmpty {
                Section("Download from the site") {
                    ForEach(downloads.keys.sorted(), id: \.self) { format in
                        if let url = downloads[format] {
                            Link(format.uppercased(), destination: url)
                        }
                    }
                }
            }

            Section("Chapters") {
                if let error { Text(error).foregroundStyle(.red) }
                if chapters.isEmpty && error == nil { ProgressView() }
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        reading = ReaderRoute(index: index)
                    } label: {
                        HStack {
                            Text(chapter.title).foregroundStyle(.primary)
                            Spacer()
                            if position?.chapterID == chapter.id {
                                Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(route.summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleLibrary(sourceID: route.sourceID, work: route.summary)
                } label: {
                    Image(systemName: inLibrary ? "heart.fill" : "heart")
                }
                .accessibilityLabel(inLibrary ? "Remove from library" : "Add to library")
            }
            ToolbarItem(placement: .bottomBar) {
                if !chapters.isEmpty {
                    Button(position == nil ? "Start reading" : "Continue: \(position!.chapterTitle)") {
                        let start = chapters.firstIndex { $0.id == position?.chapterID } ?? 0
                        reading = ReaderRoute(index: start)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .fullScreenCover(item: $reading) { route in
            ReaderContainer(sourceID: self.route.sourceID, workID: self.route.summary.id, chapters: chapters, startIndex: route.index)
        }
        .task { await load() }
    }

    private var inLibrary: Bool { model.isInLibrary(sourceID: route.sourceID, workID: route.summary.id) }
    private var position: ReadingPosition? { model.position(sourceID: route.sourceID, workID: route.summary.id) }

    @ViewBuilder
    private func metadata(_ work: Work) -> some View {
        if let rating = work.rating { LabeledContent("Rating", value: rating) }
        tagLine("Warnings", work.warnings)
        tagLine("Fandoms", work.fandoms)
        tagLine("Relationships", work.relationships)
        tagLine("Tags", work.tags)
        if let words = work.wordCount { LabeledContent("Words", value: words.formatted()) }
        if let status = work.status { LabeledContent("Status", value: status) }
    }

    @ViewBuilder
    private func tagLine(_ label: String, _ values: [String]?) -> some View {
        if let values, !values.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(values.joined(separator: " · ")).font(.subheadline)
            }
        }
    }

    private func load() async {
        do {
            let runtime = try model.runtime(for: route.sourceID)
            async let w = runtime.getWork(id: route.summary.id)
            async let c = runtime.getChapters(workID: route.summary.id)
            let (loadedWork, loadedChapters) = try await (w, c)
            work = loadedWork
            chapters = loadedChapters
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct ReaderRoute: Identifiable {
    let index: Int
    var id: Int { index }
}

extension String {
    var strippingHTML: String {
        replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
