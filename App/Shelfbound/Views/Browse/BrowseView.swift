import LibraryKit
import RepoKit
import ShelfCore
import SourceKit
import SwiftUI

/// Sources and repos, with search across every installed source.
@MainActor
struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [(source: InstalledSource, page: SearchPage?, error: String?, verify: VerificationRequest?)] = []
    @State private var searching = false
    @State private var addingRepo = false
    @State private var path = NavigationPath()
    @AppStorage("browse.mergeResults") private var mergeResults = true
    /// The first lists from each source that has them, for the Discover rows.
    @State private var discover: [DiscoverItem] = []
    @State private var discoverToken = 0

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !results.isEmpty || searching {
                    searchResults
                } else {
                    ForEach(discover) { item in
                        ListingSection(source: item.source, listing: item.listing, showSourceName: true, refreshToken: discoverToken)
                    }
                    sources
                    repositories
                }
            }
            .navigationTitle("Browse")
            .searchable(text: $query, prompt: "Search all sources")
            .onSubmit(of: .search) { Task { await searchAll() } }
            .onChange(of: query) { _, value in if value.isEmpty { results = [] } }
            .onChange(of: model.verifiedCount) { _, _ in
                if results.contains(where: { $0.verify != nil }) { Task { await searchAll() } }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { addingRepo = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add repository")
                }
            }
            .sheet(isPresented: $addingRepo) { NavigationStack { AddRepoView() } }
            .refreshable {
                await model.refreshRepos()
                discoverToken += 1
            }
            .task { await model.refreshRepos() }
            .task(id: model.searchableSources.map(\.id)) { await loadDiscover() }
            .navigationDestination(for: InstalledSource.self) { SourceSearchView(source: $0) }
            .navigationDestination(for: SavedRepo.self) { RepoDetailView(repo: $0) }
            .navigationDestination(for: WorkRoute.self) { WorkDetailView(route: $0) }
            .navigationDestination(for: ListingRoute.self) { ListingView(route: $0) }
        }
    }

    /// Two lists from each source that has them, in the order the sources are listed.
    private func loadDiscover() async {
        var items: [DiscoverItem] = []
        for source in model.searchableSources where source.manifest.has(.listings) {
            guard let runtime = try? model.runtime(for: source.id),
                  let listings = try? await runtime.getListings() else { continue }
            items += listings.prefix(2).map { DiscoverItem(source: source, listing: $0) }
        }
        guard !Task.isCancelled else { return }
        discover = items
    }

    @ViewBuilder
    private var sources: some View {
        Section {
            if model.searchableSources.isEmpty {
                Text("No sources yet. Add a repository, then install a source from it. You can also open a repo link someone shared.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(model.searchableSources) { source in
                NavigationLink(value: source) {
                    HStack(spacing: 12) {
                        SourceIcon(name: source.manifest.name)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.manifest.name)
                            Text(sourceLine(source.manifest)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.sourceUpdates[source.id] != nil {
                            Button("Update") { Task { await model.updateSource(source.id) } }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                }
                .accessibilityIdentifier("browse.source")
            }
        } header: {
            Text("Sources")
        } footer: {
            Text("Fics, manga and manhwa all show up in one library, whichever source they come from.")
        }
    }

    private func sourceLine(_ m: SourceManifest) -> String {
        let language = m.languages.first.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? m.languages.first ?? ""
        let update = model.sourceUpdates[m.id].map { "Update to v\($0.entry.version)" } ?? "v\(m.version)"
        return [m.defaultFormat.label + (m.defaultFormat == .fic || m.defaultFormat == .novel ? "s" : ""), language, update]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var repositories: some View {
        Section {
            ForEach(model.repos) { repo in
                NavigationLink(value: repo) {
                    HStack(spacing: 12) {
                        RowIcon(systemImage: "shippingbox", color: .shelfAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.name)
                            Text(repoLine(repo)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("browse.repo")
            }
            .onDelete { offsets in offsets.map { model.repos[$0] }.forEach { model.removeRepo($0) } }
            Button { addingRepo = true } label: {
                HStack(spacing: 12) {
                    RowIcon(systemImage: "plus", color: Color(.systemGray3))
                    Text("Add Repository…")
                }
            }
        } header: {
            Text("Repositories")
        } footer: {
            Text("Repositories are lists of sources made by other people. Shelfbound doesn't host or check any content.")
        }
    }

    private func repoLine(_ repo: SavedRepo) -> String {
        var parts: [String] = []
        if let count = repo.sourceCount { parts.append(count == 1 ? "1 source" : "\(count) sources") }
        if let checked = repo.checkedAt { parts.append("checked " + checked.formatted(.relative(presentation: .named))) }
        return parts.isEmpty ? (repo.url.host ?? "") : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var searchResults: some View {
        if searching && results.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }
        }
        if results.count > 1 {
            Picker("Show", selection: $mergeResults) {
                Text("Merged").tag(true)
                Text("By source").tag(false)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        if mergeResults && results.count > 1 {
            mergedResults
        } else {
            resultsBySource
        }
    }

    private func route(_ hit: MergedResult.Hit) -> WorkRoute { WorkRoute(key: hit.key, summary: hit.work) }

    /// One list across sources, the same work shown once. Long-press to open it on another source.
    @ViewBuilder
    private var mergedResults: some View {
        let merged = SearchMerger.merge(
            results.compactMap { result in result.page.map { (sourceID: result.source.id, results: $0.results) } },
            preferred: preferredSources)
        Section {
            if merged.isEmpty && !searching {
                Text("No results").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(merged) { result in
                NavigationLink(value: route(result.primary)) {
                    VStack(alignment: .leading, spacing: 6) {
                        WorkCard(work: result.primary.work, format: result.primary.work.format ?? format(of: result.primary.sourceID))
                        Text(result.others.isEmpty
                             ? model.sourceName(result.primary.sourceID)
                             : "\(model.sourceName(result.primary.sourceID)), also on \(result.others.map { model.sourceName($0.sourceID) }.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("work.result")
                .contextMenu {
                    ForEach(result.all, id: \.key) { hit in
                        Button("Open on \(model.sourceName(hit.sourceID))") { path.append(route(hit)) }
                    }
                }
            }
            if searching { HStack { Spacer(); ProgressView(); Spacer() } }
        } footer: {
            if merged.contains(where: { !$0.others.isEmpty }) {
                Text("Works on several sources show once. Touch and hold one to open it on another source.")
            }
        }
        let failed = results.filter { $0.error != nil }
        if !failed.isEmpty {
            Section("Couldn't search") {
                ForEach(failed, id: \.source.id) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.source.manifest.name).font(.subheadline.weight(.semibold))
                        Text(result.error ?? "").font(.footnote).foregroundStyle(.secondary)
                        if let verify = result.verify { VerifyInBrowserButton(request: verify) }
                    }
                }
            }
        }
    }

    /// Sources the person reads most from open merged results first.
    private var preferredSources: [String] {
        var counts: [String: Int] = [:]
        for record in model.library.library { counts[record.key.sourceID, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    private func format(of sourceID: String) -> WorkFormat {
        model.manifest(for: sourceID)?.defaultFormat ?? .fic
    }

    @ViewBuilder
    private var resultsBySource: some View {
        ForEach(results, id: \.source.id) { result in
            Section {
                if let error = result.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    if let verify = result.verify { VerifyInBrowserButton(request: verify) }
                } else if let page = result.page, page.results.isEmpty {
                    Text("No results").font(.footnote).foregroundStyle(.secondary)
                } else if let page = result.page {
                    ForEach(page.results.prefix(8)) { work in
                        NavigationLink(value: WorkRoute(key: WorkKey(sourceID: result.source.id, workID: work.id), summary: work)) {
                            WorkCard(work: work, format: work.format ?? result.source.manifest.defaultFormat)
                        }
                        .accessibilityIdentifier("work.result")
                    }
                    if page.results.count > 8 || page.hasMore {
                        NavigationLink("More from \(result.source.manifest.name)", value: result.source)
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text(result.source.manifest.name)
            }
        }
    }

    private func searchAll() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false }
        let sources = model.searchableSources
        results = sources.map { (source: $0, page: nil, error: nil, verify: nil) }
        await withTaskGroup(of: (String, SearchPage?, String?, URL?).self) { group in
            for source in sources {
                guard let runtime = try? model.runtime(for: source.id) else { continue }
                group.addTask {
                    do {
                        return (source.id, try await runtime.search(query: text, page: 1), nil, nil)
                    } catch {
                        return (source.id, nil, error.readable, (error as? BrowserVerificationNeeded)?.url)
                    }
                }
            }
            for await (id, page, error, verifyURL) in group {
                if let i = results.firstIndex(where: { $0.source.id == id }) {
                    results[i].page = page
                    results[i].error = error ?? (page == nil ? "Search failed" : nil)
                    results[i].verify = verifyURL.map { VerificationRequest(url: $0) }
                }
            }
        }
    }
}

/// A search result card: AO3-style details when the source gives them.
@MainActor
struct WorkCard: View {
    let work: WorkSummary
    let format: WorkFormat

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !format.isText || work.coverURL != nil {
                CoverView(title: work.title, format: format, url: work.coverURL, compact: true).frame(width: 52)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(work.title).font(.headline).lineLimit(2)
                let byline = [work.authors.joined(separator: ", "), work.fandoms?.first ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !byline.isEmpty { Text(byline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                if work.rating != nil || work.tags?.isEmpty == false {
                    FlowLayout(spacing: 4) {
                        if let rating = work.rating { Chip(text: rating, style: .rating) }
                        ForEach((work.tags ?? []).prefix(4), id: \.self) { Chip(text: $0, style: .free) }
                    }
                }
                if let blurb = work.blurb, work.tags == nil {
                    Text(blurb.strippingHTML).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                let stats = [
                    work.wordCount.map { "\($0.grouped) words" },
                    work.chapterCount.map { "\($0) ch" },
                    work.kudos.map { "♥ \($0.grouped)" },
                ].compactMap { $0 }
                if !stats.isEmpty {
                    Text(stats.joined(separator: "   ")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DiscoverItem: Identifiable {
    let source: InstalledSource
    let listing: SourceListing
    var id: String { source.id + "/" + listing.id }
}

/// Search one source, with its filters as chips. Before you search, it shows the
/// source's browse lists ("Freshly updated", "Trending"...) when it has them.
@MainActor
struct SourceSearchView: View {
    @Environment(AppModel.self) private var model
    let source: InstalledSource

    @State private var query = ""
    @State private var results: [WorkSummary] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    @State private var verifying: VerificationRequest?
    @State private var filters: [SearchFilter] = []
    @State private var values: [String: [String]] = [:]
    @State private var listings: [SourceListing] = []
    @State private var loadedSetup = false
    /// Bumped by every search, so an older search that finishes late can't replace newer results.
    @State private var generation = 0

    /// Browse lists show until there's something typed or searched.
    private var showingListings: Bool {
        !listings.isEmpty && query.isEmpty && results.isEmpty && error == nil && !loading
    }

    /// A new search (a filter changed) while the old results are still on screen.
    private var reloading: Bool { loading && !results.isEmpty && page == 1 }

    var body: some View {
        List {
            if showingListings {
                ForEach(listings) { listing in
                    ListingSection(source: source, listing: listing)
                }
            } else {
                if let error { Text(error).foregroundStyle(Color.shelfWarning) }
                Group {
                    ForEach(results) { work in
                        NavigationLink(value: WorkRoute(key: WorkKey(sourceID: source.id, workID: work.id), summary: work)) {
                            WorkCard(work: work, format: work.format ?? source.manifest.defaultFormat)
                        }
                        .accessibilityIdentifier("work.result")
                    }
                    if hasMore {
                        Button(loading ? "Loading..." : "Load more") { Task { await run(page: page + 1) } }
                            .disabled(loading)
                    }
                }
                .opacity(reloading ? 0.35 : 1)
                .allowsHitTesting(!reloading)
            }
        }
        // One background for the list and the chip bar, so they match when the list is empty.
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            if !filters.isEmpty && !showingListings { filterBar }
        }
        .overlay {
            if !loadedSetup {
                EmptyView()
            } else if loading && (results.isEmpty || reloading) {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if results.isEmpty && error == nil && !showingListings {
                ContentUnavailableView(
                    "Search \(source.manifest.name)", systemImage: "magnifyingglass",
                    description: listings.isEmpty ? nil : Text("Clear the search to see what's new."))
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .onSubmit(of: .search) { Task { await run(page: 1) } }
        .onChange(of: query) { _, value in
            if value.isEmpty {
                generation += 1
                results = []
                error = nil
                hasMore = false
                loading = false
            }
        }
        .onChange(of: values) { _, _ in if !query.isEmpty { Task { await run(page: 1) } } }
        .navigationTitle(source.manifest.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await setUp() }
        .browserVerification($verifying)
        .onChange(of: model.verifiedCount) { _, _ in
            if error != nil, !query.isEmpty { Task { await run(page: 1) } }
        }
    }

    /// The chips sit under the search field and stay put while results scroll.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters) { filter in FilterChip(filter: filter, values: $values) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func setUp() async {
        defer { loadedSetup = true }
        guard !loadedSetup, let runtime = try? model.runtime(for: source.id) else { return }
        filters = (try? await runtime.getFilters()) ?? []
        for filter in filters where values[filter.id] == nil {
            values[filter.id] = filter.defaultValue ?? []
        }
        listings = (try? await runtime.getListings()) ?? []
    }

    private func run(page: Int) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        generation += 1
        let mine = generation
        if page == 1 { self.page = 1 }
        loading = true
        defer { if mine == generation { loading = false } }
        do {
            let result = try await model.runtime(for: source.id).search(query: text, page: page, filters: values)
            guard mine == generation else { return }
            results = page == 1 ? result.results : results + result.results
            self.page = page
            hasMore = result.hasMore
            error = nil
        } catch {
            guard mine == generation else { return }
            self.error = error.readable
            if let request = error.verification { verifying = request }
        }
    }
}

@MainActor
struct FilterChip: View {
    let filter: SearchFilter
    @Binding var values: [String: [String]]

    private var selected: [String] { values[filter.id] ?? [] }

    var body: some View {
        control.accessibilityIdentifier("filter.chip")
    }

    @ViewBuilder
    private var control: some View {
        switch filter.type {
        case .toggle:
            Button { values[filter.id] = selected.isEmpty ? ["true"] : [] } label: { chip(filter.label, on: !selected.isEmpty) }
                .buttonStyle(.plain)
        case .select:
            Menu {
                Picker(filter.label, selection: Binding(
                    get: { selected.first ?? "" },
                    set: { values[filter.id] = $0.isEmpty ? [] : [$0] }
                )) {
                    ForEach(filter.options ?? []) { Text($0.label).tag($0.id) }
                }
            } label: {
                chip(label(for: selected.first), on: !selected.isEmpty && selected != (filter.defaultValue ?? []))
            }
            .animation(nil, value: selected)
        case .multi:
            Menu {
                ForEach(filter.options ?? []) { option in
                    Button {
                        var next = selected
                        if let i = next.firstIndex(of: option.id) { next.remove(at: i) } else { next.append(option.id) }
                        values[filter.id] = next
                    } label: {
                        if selected.contains(option.id) { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                    }
                    // Pick several without the menu closing after each one.
                    .menuActionDismissBehavior(.disabled)
                }
                if !selected.isEmpty {
                    Divider()
                    Button("Clear", role: .destructive) { values[filter.id] = [] }
                }
            } label: {
                chip(selected.isEmpty ? filter.label : "\(filter.label) · \(selected.count)", on: !selected.isEmpty)
            }
            .animation(nil, value: selected)
        }
    }

    private func label(for id: String?) -> String {
        guard let id, let option = filter.options?.first(where: { $0.id == id }) else { return filter.label }
        return "\(filter.label): \(option.label)"
    }

    /// The same weight on and off, and no animation when the text changes: a new value
    /// replaces the old one at once instead of the chip sliding to its new width.
    private func chip(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.identity)
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(on ? Color.shelfAccent : Color(.tertiarySystemFill)))
            .transaction { $0.animation = nil }
    }
}
