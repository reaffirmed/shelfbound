import RepoKit
import ShelfCore
import SwiftUI

struct SourcesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.visibleSources.isEmpty {
                    ContentUnavailableView {
                        Label("No sources yet", systemImage: "tray")
                    } description: {
                        Text("Add a repo in Settings, then install a source from it. You can also open a repo link someone shared.")
                    }
                } else {
                    List(model.visibleSources) { source in
                        NavigationLink(value: source) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(source.manifest.name)
                                    Text(source.repoURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: source.manifest.kind == .text ? "text.book.closed" : "photo.on.rectangle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Browse")
            .navigationDestination(for: InstalledSource.self) { SearchView(source: $0) }
            .navigationDestination(for: WorkRoute.self) { WorkDetailView(route: $0) }
        }
    }
}

struct WorkRoute: Hashable {
    let sourceID: String
    let summary: WorkSummary
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    let source: InstalledSource

    @State private var query = ""
    @State private var results: [WorkSummary] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(results) { work in
                NavigationLink(value: WorkRoute(sourceID: source.id, summary: work)) {
                    WorkRow(work: work)
                }
            }
            if hasMore {
                Button(loading ? "Loading..." : "Load more") { Task { await run(page: page + 1) } }
                    .disabled(loading)
            }
        }
        .overlay {
            if results.isEmpty && !loading && error == nil {
                ContentUnavailableView("Search \(source.manifest.name)", systemImage: "magnifyingglass")
            } else if loading && results.isEmpty {
                ProgressView()
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .onSubmit(of: .search) { Task { await run(page: 1) } }
        .navigationTitle(source.manifest.name)
    }

    private func run(page: Int) async {
        guard !query.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await model.runtime(for: source.id).search(query: query, page: page)
            results = page == 1 ? result.results : results + result.results
            self.page = page
            hasMore = result.hasMore
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct WorkRow: View {
    let work: WorkSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: work.coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 48, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(work.title).font(.headline).lineLimit(2)
                if !work.authors.isEmpty {
                    Text(work.authors.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                }
                if let blurb = work.blurb {
                    Text(blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}
