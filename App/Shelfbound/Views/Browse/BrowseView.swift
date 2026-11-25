import LibraryKit
import RepoKit
import ShelfCore
import SourceKit
import SwiftUI

/// The Discover and Search tabs. Discover shows each source's browse lists, the
/// installed sources and the repositories they come from. Search looks through every
/// installed source at once, or one source with its filters.
@MainActor
struct BrowseView: View {
    enum Mode { case discover, search }

    @Environment(AppModel.self) private var model
    var mode: Mode = .discover
    @State private var query = ""
    @State private var results: [(source: InstalledSource, page: SearchPage?, error: String?, verify: VerificationRequest?)] = []
    @State private var searching = false
    /// Bumped by each search and by clearing the field, so a slow source (AO3 waits three
    /// seconds between requests) can't hold the spinner up after the search is gone.
    @State private var searchGeneration = 0
    @State private var addingRepo = false
    @State private var path = NavigationPath()
    @AppStorage("browse.mergeResults") private var mergeResults = true
    @AppStorage(SearchLayout.key) private var layout: SearchLayout = .list
    /// The first lists from each source that has them, for the Discover rows.
    @State private var discover: [DiscoverItem] = []
    @State private var discoverToken = 0

    var body: some View {
        NavigationStack(path: $path) {
            List {
                switch mode {
                case .search:
                    if !results.isEmpty || searching { searchResults } else { sources }
                case .discover:
                    // The browse rows first, like a storefront; sources and repos follow.
                    // Grouped by source: its name heads its first row, then each list's title.
                    ForEach(Array(discover.enumerated()), id: \.element.id) { index, item in
                        ListingSection(
                            source: item.source, listing: item.listing,
                            sourceHeading: index == 0 || discover[index - 1].source.id != item.source.id,
                            refreshToken: discoverToken)
                    }
                    sources
                    repositories
                }
            }
            .navigationTitle(mode == .search ? "Search" : "Discover")
            .listSectionSpacing(mode == .search ? .compact : .default)
            .contentMargins(.top, mode == .search ? 4 : nil, for: .scrollContent)
            .modifier(SearchAllField(enabled: mode == .search, query: $query))
            .onSubmit(of: .search) { Task { await searchAll() } }
            .onChange(of: query) { _, value in
                if value.isEmpty {
                    searchGeneration += 1
                    searching = false
                    results = []
                }
            }
            .onChange(of: model.verifiedCount) { _, _ in
                if results.contains(where: { $0.verify != nil }) { Task { await searchAll() } }
            }
            .toolbar {
                if mode == .discover {
                    ToolbarItem(placement: .primaryAction) {
                        Button { addingRepo = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Add repository")
                    }
                }
            }
            .sheet(isPresented: $addingRepo) { NavigationStack { AddRepoView() } }
            .refreshable {
                await model.refreshRepos()
                discoverToken += 1
            }
            .task { if mode == .discover { await model.refreshRepos() } }
            .task(id: model.searchableSources.map(\.id)) { if mode == .discover { await loadDiscover() } }
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
            Text(mode == .search ? "Search one source" : "Sources")
        } footer: {
            Text(mode == .search
                 ? "Type above to search every source at once, or pick one to search it with all of its filters."
                 : "Fics, manga and manhwa all show up in one library, whichever source they come from.")
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
        if mergeResults && results.count > 1 {
            mergedResults
        } else {
            resultsBySource
        }
    }

    /// Merged / By source and the layout switch. They sit in the first section's header,
    /// not a row of their own, so there's no empty band between them and the search field.
    private var resultControls: some View {
        HStack(spacing: 10) {
            if results.count > 1 {
                Picker("Show", selection: $mergeResults) {
                    Text("Merged").tag(true)
                    Text("By source").tag(false)
                }
                .pickerStyle(.segmented)
            } else {
                Spacer()
            }
            SearchLayoutToggle(layout: $layout)
        }
        .textCase(nil)
        .padding(.bottom, 8)
    }

    private func route(_ hit: MergedResult.Hit) -> WorkRoute { WorkRoute(key: hit.key, summary: hit.work) }

    /// One list across sources, the same work shown once. Long-press to open it on another source.
    @ViewBuilder
    private var mergedResults: some View {
        let merged = SearchMerger.merge(
            results.compactMap { result in result.page.map { (sourceID: result.source.id, results: $0.results.uniqued()) } },
            preferred: preferredSources)
        Section {
            if merged.isEmpty && !searching {
                Text("No results").font(.footnote).foregroundStyle(.secondary)
            }
            if layout == .covers {
                CoverGrid(items: merged.map { result in
                    CoverGrid.Item(
                        route: route(result.primary),
                        format: result.primary.work.format ?? format(of: result.primary.sourceID),
                        caption: model.sourceName(result.primary.sourceID),
                        alternatives: result.others.map { (model.sourceName($0.sourceID), route($0)) })
                }) { path.append($0) }
            } else {
                ForEach(merged) { result in
                    NavigationLink(value: route(result.primary)) {
                        WorkCard(
                            work: result.primary.work, format: result.primary.work.format ?? format(of: result.primary.sourceID),
                            sourceLine: result.others.isEmpty
                                ? model.sourceName(result.primary.sourceID)
                                : "\(model.sourceName(result.primary.sourceID)), also on \(result.others.map { model.sourceName($0.sourceID) }.joined(separator: ", "))")
                    }
                    .accessibilityIdentifier("work.result")
                    .contextMenu {
                        ForEach(result.all, id: \.key) { hit in
                            Button("Open on \(model.sourceName(hit.sourceID))") { path.append(route(hit)) }
                        }
                    }
                }
            }
            if searching { HStack { Spacer(); ProgressView(); Spacer() } }
        } header: {
            resultControls
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
        ForEach(Array(results.enumerated()), id: \.element.source.id) { index, result in
            Section {
                if let error = result.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    if let verify = result.verify { VerifyInBrowserButton(request: verify) }
                } else if let page = result.page, page.results.isEmpty {
                    Text("No results").font(.footnote).foregroundStyle(.secondary)
                } else if let page = result.page {
                    if layout == .covers {
                        CoverGrid(items: page.results.uniqued().prefix(9).map { work in
                            CoverGrid.Item(
                                route: WorkRoute(key: WorkKey(sourceID: result.source.id, workID: work.id), summary: work),
                                format: work.format ?? result.source.manifest.defaultFormat)
                        }) { path.append($0) }
                    } else {
                        ForEach(page.results.uniqued().prefix(8)) { work in
                            NavigationLink(value: WorkRoute(key: WorkKey(sourceID: result.source.id, workID: work.id), summary: work)) {
                                WorkCard(work: work, format: work.format ?? result.source.manifest.defaultFormat)
                            }
                            .accessibilityIdentifier("work.result")
                        }
                    }
                    if page.results.count > 8 || page.hasMore {
                        NavigationLink("More from \(result.source.manifest.name)", value: result.source)
                    }
                } else {
                    ProgressView()
                }
            } header: {
                VStack(alignment: .leading, spacing: 0) {
                    if index == 0 { resultControls }
                    Text(result.source.manifest.name)
                }
            }
        }
    }

    private func searchAll() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searchGeneration += 1
        let generation = searchGeneration
        searching = true
        defer { if generation == searchGeneration { searching = false } }
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
                guard generation == searchGeneration else { continue }
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
    /// Cover width in the list. Tall enough to sit beside the title, byline, tags and
    /// source line without leaving a gap under it.
    static let coverWidth: CGFloat = 84

    let work: WorkSummary
    let format: WorkFormat
    /// Which source it's from, shown under the details, as in merged search results.
    var sourceLine: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !format.isText || work.coverURL != nil {
                CoverView(title: work.title, format: format, url: work.coverURL, compact: true).frame(width: Self.coverWidth)
            } else {
                // No cover (most fics): a small tile with the fandom's initials keeps the
                // text in line with the rows that have one.
                InitialsTile(text: work.fandoms?.first ?? work.title).frame(width: Self.coverWidth)
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
                if let sourceLine {
                    Text(sourceLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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

/// The search field, only on the Search tab.
private struct SearchAllField: ViewModifier {
    let enabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search all sources")
        } else {
            content
        }
    }
}

/// Search one source, with its filters as chips. Before you search, it shows the
/// source's browse lists ("Freshly updated", "Trending"...) when it has them.
@MainActor
struct SourceSearchView: View {
    @Environment(AppModel.self) private var model
    let source: InstalledSource
    /// Filters to start with, as when a tag on a work's page opens this search.
    var initialValues: [String: [String]]? = nil
    var title: String? = nil

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
    /// The text of the last search that came back, to tell "nothing found" from "not searched yet".
    @State private var searchedText: String?
    @State private var showingFilters = false
    @AppStorage(SearchLayout.key) private var layout: SearchLayout = .list
    /// A work tapped in the cover grid.
    @State private var opened: WorkRoute?
    /// Genres picked in the grid before searching. They apply together on Search, so
    /// you can pick several before the results replace the grid.
    @State private var staged: [String: [String]] = [:]

    /// Nothing typed or searched yet: the genre grid and the browse lists show.
    private var idle: Bool {
        query.isEmpty && results.isEmpty && error == nil && !loading && searchedText == nil
    }

    /// Filters with a fixed list of names, shown as a grid of chips before searching.
    private var chipGrids: [SearchFilter] {
        filters.filter { filter in
            guard let options = filter.options, !options.isEmpty else { return false }
            return filter.type == .tags || (filter.type == .multi && options.count >= 6)
        }
    }

    private var stagedCount: Int {
        chipGrids.reduce(0) { $0 + (staged[$1.id] ?? []).count + (staged[$1.excludeKey] ?? []).count }
    }

    /// Browse lists show until there's something typed or searched.
    private var showingListings: Bool {
        !listings.isEmpty && query.isEmpty && results.isEmpty && error == nil && !loading && searchedText == nil
    }

    /// Filters that aren't at their default, which make a search worth running even
    /// with nothing typed.
    private var activeFilters: Bool { filters.contains { $0.isActive(in: values) } }

    private var activeCount: Int { filters.filter { $0.isActive(in: values) }.count }

    /// Chips for the simple kinds, and for the others only once they're set.
    private var chipFilters: [SearchFilter] {
        filters.filter { filter in
            switch filter.type {
            case .select, .multi, .toggle: true
            case .text, .range, .tags: filter.isActive(in: values)
            }
        }
    }

    /// A new search (a filter changed) while the old results are still on screen.
    private var reloading: Bool { loading && !results.isEmpty && loadingPage == 1 }
    /// The page being fetched, so loading the next page doesn't dim what's already shown.
    @State private var loadingPage = 1

    var body: some View {
        List {
            if idle && !chipGrids.isEmpty {
                ForEach(chipGrids) { filter in
                    Section {
                        GenreGrid(filter: filter, values: $staged)
                    } header: {
                        Text(filter.label)
                    }
                }
            }
            if showingListings {
                ForEach(listings) { listing in
                    ListingSection(source: source, listing: listing)
                }
            } else {
                if let error { Text(error).foregroundStyle(Color.shelfWarning) }
                Group {
                    if layout == .covers {
                        CoverGrid(items: results.map { work in
                            CoverGrid.Item(
                                route: WorkRoute(key: WorkKey(sourceID: source.id, workID: work.id), summary: work),
                                format: work.format ?? source.manifest.defaultFormat)
                        }) { opened = $0 }
                    } else {
                        ForEach(results) { work in
                            NavigationLink(value: WorkRoute(key: WorkKey(sourceID: source.id, workID: work.id), summary: work)) {
                                WorkCard(work: work, format: work.format ?? source.manifest.defaultFormat)
                            }
                            .accessibilityIdentifier("work.result")
                        }
                    }
                    if hasMore {
                        // Scrolling to the end loads the next page. The task restarts when the
                        // page changes, so it keeps going while this row stays on screen.
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowBackground(Color.clear)
                            .task(id: page) {
                                if !loading && error == nil { await run(page: page + 1) }
                            }
                    }
                }
                // A fresh view per layout, so switching mid-search never diffs a list
                // against a grid.
                .id(layout)
                .opacity(reloading ? 0.35 : 1)
                .allowsHitTesting(!reloading)
            }
        }
        // One background for the list and the chip bar, so they match when the list is empty.
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            if !filters.isEmpty { filterBar }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if idle && stagedCount > 0 {
                HStack(spacing: 12) {
                    Button("Clear") { staged = [:] }
                        .buttonStyle(.bordered)
                    Button { applyStaged() } label: {
                        Text(stagedCount == 1 ? "Search 1 genre" : "Search \(stagedCount) genres").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.shelfAccent)
                }
                .controlSize(.large)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
            }
        }
        .overlay {
            if !loadedSetup {
                EmptyView()
            } else if loading && (results.isEmpty || reloading) {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if results.isEmpty && error == nil && !showingListings, let searchedText, !searchedText.isEmpty {
                ContentUnavailableView.search(text: searchedText)
            } else if results.isEmpty && error == nil && !showingListings && searchedText != nil {
                ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Try fewer filters."))
            } else if results.isEmpty && error == nil && !showingListings {
                ContentUnavailableView(
                    "Search \(source.manifest.name)", systemImage: "magnifyingglass",
                    description: listings.isEmpty ? nil : Text("Clear the search to see what's new."))
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .onSubmit(of: .search) {
            if stagedCount > 0 { applyStaged() } else { Task { await run(page: 1) } }
        }
        .onChange(of: query) { _, value in
            if value.isEmpty && !activeFilters {
                generation += 1
                results = []
                searchedText = nil
                error = nil
                hasMore = false
                loading = false
            }
        }
        .onChange(of: values) { _, _ in
            guard loadedSetup else { return }
            if !query.isEmpty || activeFilters || searchedText != nil { Task { await run(page: 1) } }
        }
        .sheet(isPresented: $showingFilters) {
            FilterSheet(sourceID: source.id, filters: filters, values: values) { values = $0 }
        }
        .navigationTitle(title ?? source.manifest.name)
        .navigationDestination(item: $opened) { WorkDetailView(route: $0) }
        .toolbar {
            if filters.isEmpty { ToolbarItem(placement: .primaryAction) { SearchLayoutMenu(layout: $layout) } }
        }
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
                Button { showingFilters = true } label: {
                    FilterChipLabel(
                        text: activeCount == 0 ? "Filters" : "Filters · \(activeCount)", on: false,
                        systemImage: "line.3.horizontal.decrease")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filters.all")
                SearchLayoutToggle(layout: $layout)
                ForEach(chipFilters) { filter in
                    switch filter.type {
                    case .select, .multi, .toggle: FilterChip(filter: filter, values: $values)
                    case .text, .range, .tags: FilterSummaryChip(filter: filter, values: values) { showingFilters = true }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Puts the genres picked in the grid into the filters, which runs the search.
    private func applyStaged() {
        var next = values
        for filter in chipGrids {
            next[filter.id] = staged[filter.id] ?? []
            if filter.type == .tags { next[filter.excludeKey] = staged[filter.excludeKey] ?? [] }
        }
        staged = [:]
        searchedText = searchedText ?? ""
        let changed = next != values
        values = next
        // Unchanged filters don't trigger the search on their own.
        if !changed { Task { await run(page: 1) } }
    }

    private func setUp() async {
        defer { loadedSetup = true }
        guard !loadedSetup, let runtime = try? model.runtime(for: source.id) else { return }
        filters = (try? await runtime.getFilters()) ?? []
        var start = values
        for filter in filters where start[filter.id] == nil {
            start[filter.id] = filter.defaultValue ?? []
        }
        if let initialValues {
            start.merge(initialValues) { _, new in new }
        } else {
            listings = (try? await runtime.getListings()) ?? []
        }
        values = start
        if initialValues != nil {
            searchedText = ""
            await run(page: 1)
        }
    }

    private func run(page: Int) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty || activeFilters || searchedText != nil else { return }
        generation += 1
        let mine = generation
        if page == 1 { self.page = 1 }
        loadingPage = page
        loading = true
        defer { if mine == generation { loading = false } }
        do {
            let result = try await model.runtime(for: source.id).search(query: text, page: page, filters: values)
            guard mine == generation else { return }
            // Append only works not already shown. Sites repeat works across pages, and a
            // repeated ID made the list drop rows and could crash switching layouts.
            var seen = page == 1 ? Set<String>() : Set(results.map(\.id))
            let fresh = result.results.filter { seen.insert($0.id).inserted }
            results = page == 1 ? fresh : results + fresh
            searchedText = text
            self.page = page
            hasMore = result.hasMore && !fresh.isEmpty
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
        case .text, .range, .tags:
            EmptyView()
        }
    }

    private func label(for id: String?) -> String {
        guard let id, let option = filter.options?.first(where: { $0.id == id }) else { return filter.label }
        return "\(filter.label): \(option.label)"
    }

    /// The same weight on and off, and no animation when the text changes: a new value
    /// replaces the old one at once instead of the chip sliding to its new width.
    private func chip(_ text: String, on: Bool) -> some View {
        FilterChipLabel(text: text, on: on)
    }
}

/// A colored square with a fandom's (or title's) initials, for results with no cover.
struct InitialsTile: View {
    let text: String

    /// "Harry Potter - J. K. Rowling" names the fandom by its first part.
    private var name: String {
        let cut = text.components(separatedBy: " - ").first ?? text
        return (cut.components(separatedBy: " (").first ?? cut).trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        let hue = Hue.of(name)
        Text(name.monogram)
            .font(.system(.title2, design: .rounded, weight: .bold))
            .foregroundStyle(Color(hue: hue, saturation: 0.55, brightness: 0.32))
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hue: hue, saturation: 0.3, brightness: 0.92)))
            .accessibilityHidden(true)
    }
}

/// A grid of a filter's names, tapped to pick them before searching. Where the source
/// can leave names out, a second tap excludes it and a third clears it.
@MainActor
struct GenreGrid: View {
    let filter: SearchFilter
    @Binding var values: [String: [String]]

    private var included: [String] { values[filter.id] ?? [] }
    private var excluded: [String] { values[filter.excludeKey] ?? [] }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(filter.options ?? []) { option in
                Button { cycle(option.id) } label: { chip(option) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("genre.chip")
            }
        }
        .padding(.vertical, 6)
    }

    private func chip(_ option: SearchFilter.Option) -> some View {
        let on = included.contains(option.id)
        let off = excluded.contains(option.id)
        return HStack(spacing: 4) {
            if on { Image(systemName: "checkmark") }
            if off { Image(systemName: "minus") }
            Text(option.label).strikethrough(off)
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(on || off ? Color.white : Color.primary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(on ? Color.shelfAccent : off ? Color.red.opacity(0.8) : Color(.tertiarySystemFill)))
        .accessibilityLabel(on ? "\(option.label), included" : off ? "\(option.label), excluded" : option.label)
    }

    private func cycle(_ id: String) {
        var inc = included
        var exc = excluded
        if let i = inc.firstIndex(of: id) {
            inc.remove(at: i)
            if filter.type == .tags && filter.excludable == true { exc.append(id) }
        } else if let i = exc.firstIndex(of: id) {
            exc.remove(at: i)
        } else {
            inc.append(id)
        }
        values[filter.id] = inc
        values[filter.excludeKey] = exc.isEmpty ? nil : exc
    }
}

extension Array where Element == WorkSummary {
    /// The first of each ID. A list or grid with a repeated ID drops rows or crashes.
    func uniqued() -> [WorkSummary] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}
