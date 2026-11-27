import LibraryKit
import ShelfCore
import SwiftUI

/// A series a work belongs to, listed in the app by its source.
struct SeriesRoute: Hashable {
    let sourceID: String
    let id: String
    let title: String
    let url: URL?
}

/// Everything by one author: what's in the library, and what the work's source has.
struct AuthorRoute: Hashable {
    let sourceID: String
    let name: String
}

/// A list of works from one source that loads more as you scroll. The works are kept by
/// the screen that shows it, so that screen can act on them (add them all to the library).
@MainActor
struct PagedWorkList<Header: View>: View {
    @Environment(AppModel.self) private var model
    let sourceID: String
    @Binding var results: [WorkSummary]
    /// A heading over the works, when something else sits above them.
    var resultsTitle: String? = nil
    var emptyText = "Nothing here right now"
    let fetch: (Int) async throws -> SearchPage
    /// Rows above the works. It's handed the way to open a work's page.
    @ViewBuilder var header: (@escaping (WorkRoute) -> Void) -> Header

    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var verifying: VerificationRequest?
    @State private var opened: WorkRoute?
    /// Pages in a row that brought only works already shown.
    @State private var repeatPages = 0

    private var format: WorkFormat { model.manifest(for: sourceID)?.defaultFormat ?? .fic }

    var body: some View {
        List {
            header { opened = $0 }
            Section {
                if let error, results.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error).font(.footnote).foregroundStyle(Color.shelfWarning)
                        Button("Try again") { loadNext(retry: true) }.buttonStyle(.borderless)
                    }
                } else if results.isEmpty && loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if results.isEmpty {
                    Text(emptyText).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(results) { work in
                    let key = WorkKey(sourceID: sourceID, workID: work.id)
                    Button { opened = WorkRoute(key: key, summary: work) } label: {
                        WorkCard(work: work, format: work.format ?? format,
                                 sourceLine: model.record(key)?.inLibrary == true ? "In your library" : nil)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("work.result")
                }
                if hasMore && !results.isEmpty {
                    PageFooter(hasMore: true, failed: error != nil, page: page) { loadNext(retry: $0) }
                        .listRowBackground(Color.clear)
                }
            } header: {
                if let resultsTitle { Text(resultsTitle) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { WorkDetailView(route: $0) }
        .refreshable { await load(1) }
        .browserVerification($verifying)
        .onChange(of: model.verifiedCount) { _, _ in
            if error != nil { loadNext(retry: true) }
        }
        .task { if results.isEmpty { await load(1) } }
    }

    /// Runs in a Task of its own, so the footer scrolling away can't cancel a page halfway.
    private func loadNext(retry: Bool) {
        guard !loading, hasMore, retry || error == nil else { return }
        if retry { error = nil }
        let next = results.isEmpty ? 1 : page + 1
        Task { await load(next) }
    }

    private func load(_ next: Int) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await fetch(next)
            var seen = next == 1 ? Set<String>() : Set(results.map(\.id))
            let fresh = result.results.filter { seen.insert($0.id).inserted }
            results = next == 1 ? fresh : results + fresh
            // A site that repeats the same works for every page never says it's done.
            repeatPages = fresh.isEmpty && next > 1 ? repeatPages + 1 : 0
            page = next
            hasMore = result.hasMore && !result.results.isEmpty && repeatPages < 3
            error = nil
        } catch is CancellationError {
            return
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            self.error = error.readable
            if let request = error.verification { verifying = request }
        }
    }
}

/// The works in a series, in the series' order, from the work's source.
@MainActor
struct SeriesView: View {
    @Environment(AppModel.self) private var model
    let route: SeriesRoute
    @State private var results: [WorkSummary] = []
    @State private var added: Int?

    var body: some View {
        PagedWorkList(
            sourceID: route.sourceID, results: $results, emptyText: "This series has no works to show.",
            fetch: { page in try await model.runtime(for: route.sourceID).getSeries(id: route.id, page: page) }
        ) { _ in
            if let added {
                Section {
                    Text(added == 0 ? "They're all in your library already."
                         : added == 1 ? "Added 1 work to your library." : "Added \(added) works to your library.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(route.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { addAll() } label: {
                        Label(results.count == 1 ? "Add it to the library" : "Add all \(results.count) to the library", systemImage: "plus.circle")
                    }
                    .disabled(results.isEmpty)
                    if let url = route.url {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                        Link(destination: url) { Label("Open in browser", systemImage: "safari") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
    }

    /// Adds the works listed so far. Their chapters arrive with the next check for new chapters.
    private func addAll() {
        var count = 0
        for work in results where model.addToLibrary(WorkKey(sourceID: route.sourceID, workID: work.id), summary: work) {
            count += 1
        }
        added = count
        if count > 0 { Haptics.success() }
    }
}

/// An author's works: the ones in the library (from any source), then what the work's
/// source finds for the name.
@MainActor
struct AuthorView: View {
    @Environment(AppModel.self) private var model
    let route: AuthorRoute
    @State private var results: [WorkSummary] = []
    /// How the source is asked: by its author filter when it has one, else by searching the name.
    @State private var plan: SearchPlan?

    private struct SearchPlan {
        var query: String
        var filters: [String: [String]]
        /// A plain text search also finds works that only mention the name.
        var checkAuthors: Bool
    }

    /// "Pseud (username)" is searched by the pseud.
    private var plainName: String {
        route.name.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
    }

    private var inLibrary: [WorkRecord] {
        let names = Set([route.name.lowercased(), plainName.lowercased()])
        return model.library.library
            .filter { record in record.authors.contains { names.contains($0.lowercased()) } }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        let mine = inLibrary
        PagedWorkList(
            sourceID: route.sourceID, results: $results,
            resultsTitle: "On \(model.sourceName(route.sourceID))",
            emptyText: "\(model.sourceName(route.sourceID)) found nothing else by this author.",
            fetch: { page in try await fetch(page) }
        ) { open in
            if !mine.isEmpty {
                Section("In your library") {
                    ForEach(mine) { record in
                        Button { open(WorkRoute(key: record.key, summary: record.summary)) } label: {
                            HStack(spacing: 12) {
                                BadgedCover(record: record, showBadge: false, compact: true).frame(width: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(record.progressLine ?? model.sourceName(record.key.sourceID))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(route.name)
    }

    private func fetch(_ page: Int) async throws -> SearchPage {
        let runtime = try model.runtime(for: route.sourceID)
        let plan = try await currentPlan()
        let found = try await runtime.search(query: plan.query, page: page, filters: plan.filters)
        guard plan.checkAuthors, found.results.contains(where: { !$0.authors.isEmpty }) else { return found }
        let wanted = plainName.lowercased()
        return SearchPage(
            results: found.results.filter { work in work.authors.contains { $0.lowercased().contains(wanted) } },
            hasMore: found.hasMore)
    }

    private func currentPlan() async throws -> SearchPlan {
        if let plan { return plan }
        let filters = (try? await model.runtime(for: route.sourceID).getFilters()) ?? []
        let made: SearchPlan
        if let values = TagSearch.values(for: plainName, field: "authors", in: filters) {
            made = SearchPlan(query: "", filters: values, checkAuthors: false)
        } else {
            var defaults: [String: [String]] = [:]
            for filter in filters { defaults[filter.id] = filter.defaultValue ?? [] }
            made = SearchPlan(query: plainName, filters: defaults, checkAuthors: true)
        }
        plan = made
        return made
    }
}
