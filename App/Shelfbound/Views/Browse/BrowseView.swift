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
    /// Sources still being asked for their lists, so Discover shows rows on the way.
    @State private var discoverLoading = false
    @State private var renaming: SavedSearch?
    @State private var renameText = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                switch mode {
                case .search:
                    if !results.isEmpty || searching {
                        searchResults
                    } else {
                        savedSearches
                        sources
                    }
                case .discover:
                    // The browse rows first, like a storefront; sources and repos follow.
                    // Grouped by source: its name heads its first row, then each list's title.
                    ForEach(Array(discover.enumerated()), id: \.element.id) { index, item in
                        ListingSection(
                            source: item.source, listing: item.listing,
                            sourceHeading: index == 0 || discover[index - 1].source.id != item.source.id,
                            refreshToken: discoverToken)
                    }
                    if discoverLoading { DiscoverPlaceholder() }
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
                if mode == .search {
                    await model.refreshSavedSearches(force: true)
                } else {
                    await model.refreshRepos()
                    discoverToken += 1
                }
            }
            .task {
                if mode == .discover { await model.refreshRepos() } else { await model.refreshSavedSearches() }
            }
            .alert("Rename saved search", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let renaming { model.renameSavedSearch(renaming.id, to: renameText) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .task(id: model.searchableSources.map(\.id)) { if mode == .discover { await loadDiscover() } }
            .navigationDestination(for: InstalledSource.self) { SourceSearchView(source: $0) }
            .navigationDestination(for: SavedRepo.self) { RepoDetailView(repo: $0) }
            .navigationDestination(for: WorkRoute.self) { WorkDetailView(route: $0) }
            .navigationDestination(for: ListingRoute.self) { ListingView(route: $0) }
            .navigationDestination(for: SavedSearchRoute.self) {
                SourceSearchView(source: $0.source, initialValues: $0.filters, title: $0.name, initialQuery: $0.query, savedID: $0.id)
            }
        }
    }

    /// Searches the person kept, each with how many results are new since they last looked.
    @ViewBuilder
    private var savedSearches: some View {
        let sources = model.searchableSources
        let saved = model.savedSearches.compactMap { search -> SavedSearchRoute? in
            guard let source = sources.first(where: { $0.id == search.sourceID }) else { return nil }
            return SavedSearchRoute(source: source, id: search.id, name: search.name, query: search.query,
                                    filters: search.filters, newCount: search.newCount)
        }
        if !saved.isEmpty {
            Section {
                ForEach(saved, id: \.id) { item in
                    NavigationLink(value: item) {
                        HStack(spacing: 12) {
                            RowIcon(systemImage: "bookmark.fill", color: .shelfAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                Text(item.source.manifest.name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.newCount > 0 {
                                Text("\(item.newCount) new")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.shelfBadge))
                            }
                        }
                    }
                    .accessibilityIdentifier("search.saved")
                    .contextMenu {
                        Button {
                            renameText = item.name
                            renaming = model.savedSearches.first { $0.id == item.id }
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) { model.removeSavedSearch(item.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in offsets.map { saved[$0].id }.forEach { model.removeSavedSearch($0) } }
            } header: {
                Text("Saved searches")
            } footer: {
                Text("Pull down to check for new results.")
            }
        }
    }

    /// Two lists from each source that has them, in the order the sources are listed.
    /// Sources are asked side by side and each one's rows show as soon as it answers, so a
    /// slow source doesn't hold up the others.
    private func loadDiscover() async {
        let sources = model.searchableSources.filter { $0.manifest.has(.listings) }
        // Rows for sources that are gone leave right away; the rest stay until refreshed.
        discover.removeAll { item in !sources.contains { $0.id == item.source.id } }
        guard !sources.isEmpty else { return }
        discoverLoading = true
        await withTaskGroup(of: (String, [SourceListing]?).self) { group in
            var found: [String: [SourceListing]] = [:]
            for source in sources {
                guard let runtime = try? model.runtime(for: source.id) else { continue }
                group.addTask { (source.id, try? await runtime.getListings()) }
            }
            for await (id, listings) in group {
                guard !Task.isCancelled else { continue }
                guard let listings else { continue }
                found[id] = listings
                // Sources that haven't answered yet keep the rows they already had.
                let kept = Dictionary(grouping: discover, by: { $0.source.id })
                discover = sources.flatMap { source -> [DiscoverItem] in
                    if let lists = found[source.id] {
                        return lists.prefix(2).map { DiscoverItem(source: source, listing: $0) }
                    }
                    return kept[source.id] ?? []
                }
            }
        }
        guard !Task.isCancelled else { return }
        discoverLoading = false
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

/// Stand-in rows while the sources answer, so what's below doesn't jump when they arrive.
@MainActor
struct DiscoverPlaceholder: View {
    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in ListingTile.placeholder }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .scrollDisabled(true)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .accessibilityLabel("Loading lists")
        }
    }
}

/// A saved search opened from the Search tab.
struct SavedSearchRoute: Hashable {
    let source: InstalledSource
    let id: UUID
    let name: String
    let query: String
    let filters: [String: [String]]
    let newCount: Int
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
    /// Text to start with, as when a saved search or an author's name opens this search.
    var initialQuery: String? = nil
    /// The saved search this screen was opened from. Its first results count as looked at
    /// even if the source's filters have changed since it was saved.
    var savedID: UUID? = nil

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
            case .text, .range, .tags, .date: filter.isActive(in: values)
            }
        }
    }

    /// A new search (a filter changed) while the old results are still on screen.
    private var reloading: Bool { loading && !results.isEmpty && loadingPage == 1 }
    /// The page being fetched, so loading the next page doesn't dim what's already shown.
    @State private var loadingPage = 1
    /// The filters the results on screen were searched with, for fetching their next pages.
    @State private var pagedValues: [String: [String]]?
    /// Pages in a row that brought only works already shown.
    @State private var repeatPages = 0
    /// A new search (not a next page) failed while older results are still on screen.
    @State private var firstPageFailed = false
    /// Results that weren't there the last time the person looked at this saved search.
    @State private var newIDs: Set<String> = []
    @State private var namingSaved = false
    @State private var usedSavedID = false
    @State private var savedName = ""

    /// The saved search that the results on screen belong to, if they were saved.
    private var currentSaved: SavedSearch? {
        guard let text = searchedText, let used = pagedValues else { return nil }
        return model.savedSearch(sourceID: source.id, query: text, filters: used)
    }

    /// A finished search with something to it can be saved.
    private var canSave: Bool {
        guard let text = searchedText, let used = pagedValues else { return false }
        if currentSaved != nil { return true }
        return !results.isEmpty && (!text.isEmpty || filters.contains { $0.isActive(in: used) })
    }

    /// Search results as covers get a scroll view of their own instead of the List (see
    /// PagedCoverGrid). The genre grid, browse lists and list layout stay in the List.
    private var coverResults: Bool { layout == .covers && !results.isEmpty && !showingListings }

    var body: some View {
        // A ZStack rather than a Group, so the modifiers below attach once to a container
        // that stays put, not separately to each branch (which would reset the search
        // field when the results swap the List for the grid).
        ZStack {
            if coverResults {
                PagedCoverGrid(
                    items: results.map { work in
                        CoverGrid.Item(
                            route: WorkRoute(key: WorkKey(sourceID: source.id, workID: work.id), summary: work),
                            format: work.format ?? source.manifest.defaultFormat,
                            caption: newIDs.contains(work.id) ? "New" : nil)
                    },
                    page: page,
                    hasMore: hasMore,
                    failed: error != nil,
                    loadMore: { loadNextPage(retry: $0) },
                    open: { opened = $0 }
                ) {
                    if firstPageFailed { searchFailedBanner.padding(.horizontal, 16).padding(.top, 8) }
                }
                .opacity(reloading ? 0.35 : 1)
                .allowsHitTesting(!reloading)
            } else {
                resultsList
            }
        }
        // One background for the list and the chip bar, so they match when the list is empty.
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            if !filters.isEmpty || canSave { filterBar }
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
                firstPageFailed = false
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
        .alert("Save this search", isPresented: $namingSaved) {
            TextField("Name", text: $savedName)
            Button("Save") {
                guard let text = searchedText, let used = pagedValues else { return }
                model.saveSearch(sourceID: source.id, name: savedName, query: text, filters: used, seen: results.map(\.id))
                Haptics.light()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's kept on the Search tab, with a count of the results that are new since you last looked.")
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
            if error != nil, !query.isEmpty || firstPageFailed { Task { await run(page: 1) } }
        }
    }

    /// The genre grid and browse lists before searching, and results in the list layout.
    private var resultsList: some View {
        // Fetch the next page while this many rows are still below, not at the last one.
        let trigger = Set(results.suffix(10).map(\.id))
        return List {
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
                if firstPageFailed && !results.isEmpty {
                    searchFailedBanner
                } else if let error, results.isEmpty || !hasMore {
                    Text(error).foregroundStyle(Color.shelfWarning)
                }
                // No modifiers on a Group of rows here: SwiftUI copies them onto every row,
                // and an .id() there once gave every row the same identity, which made the
                // list leave big gaps and jump when a page was added.
                ForEach(results) { work in
                    NavigationLink(value: WorkRoute(key: WorkKey(sourceID: source.id, workID: work.id), summary: work)) {
                        WorkCard(work: work, format: work.format ?? source.manifest.defaultFormat,
                                 sourceLine: newIDs.contains(work.id) ? "New since you last looked" : nil)
                    }
                    .accessibilityIdentifier("work.result")
                    .onAppear { if hasMore, trigger.contains(work.id) { loadNextPage(retry: false) } }
                }
                if hasMore && !results.isEmpty {
                    PageFooter(hasMore: true, failed: error != nil, page: page) { loadNextPage(retry: $0) }
                        .listRowBackground(Color.clear)
                }
            }
        }
        .opacity(reloading ? 0.35 : 1)
        .allowsHitTesting(!reloading)
    }

    /// A new search failed and the results below are from the one before it.
    private var searchFailedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(error ?? "Search failed").foregroundStyle(Color.shelfWarning)
            Text("These results are from your last search.").font(.footnote).foregroundStyle(.secondary)
            Button("Try again") { Task { await run(page: 1) } }
                .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The chips sit under the search field and stay put while results scroll.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !filters.isEmpty {
                    Button { showingFilters = true } label: {
                        FilterChipLabel(
                            text: activeCount == 0 ? "Filters" : "Filters · \(activeCount)", on: false,
                            systemImage: "line.3.horizontal.decrease")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("filters.all")
                }
                SearchLayoutToggle(layout: $layout)
                if canSave {
                    let saved = currentSaved
                    Button { toggleSaved(saved) } label: {
                        FilterChipLabel(text: saved == nil ? "Save" : "Saved", on: saved != nil,
                                        systemImage: saved == nil ? "bookmark" : "bookmark.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(saved == nil ? "Save this search" : "Remove this saved search")
                    .accessibilityIdentifier("search.save")
                }
                ForEach(chipFilters) { filter in
                    switch filter.type {
                    case .select, .multi, .toggle: FilterChip(filter: filter, values: $values)
                    case .text, .range, .tags, .date: FilterSummaryChip(filter: filter, values: values) { showingFilters = true }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Saves the search on screen (after asking for a name), or forgets it if it was saved.
    private func toggleSaved(_ saved: SavedSearch?) {
        if let saved {
            model.removeSavedSearch(saved.id)
            newIDs = []
            return
        }
        guard let text = searchedText, let used = pagedValues else { return }
        let defaults = Dictionary(filters.map { ($0.id, $0.defaultValue ?? []) }, uniquingKeysWith: { first, _ in first })
        savedName = SavedSearch.suggestedName(query: text, filters: used, defaults: defaults)
        namingSaved = true
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
        if let initialQuery { query = initialQuery }
        if initialValues != nil || initialQuery != nil {
            searchedText = ""
            await run(page: 1, typed: initialQuery)
        }
    }

    /// `typed` stands in for the search field on the first search of a screen opened with
    /// its text already chosen.
    private func run(page: Int, typed: String? = nil) async {
        // Later pages continue the search on screen, not whatever is typed in the field now.
        let text = page == 1 ? (typed ?? query).trimmingCharacters(in: .whitespaces) : (searchedText ?? "")
        let filters = page == 1 ? values : (pagedValues ?? values)
        guard page > 1 || !text.isEmpty || activeFilters || searchedText != nil else { return }
        generation += 1
        let mine = generation
        if page == 1 { self.page = 1 }
        loadingPage = page
        loading = true
        defer { if mine == generation { loading = false } }
        do {
            let result = try await model.runtime(for: source.id).search(query: text, page: page, filters: filters)
            guard mine == generation else { return }
            // Append only works not already shown. Sites repeat works across pages, and a
            // repeated ID made the list drop rows and could crash switching layouts.
            var seen = page == 1 ? Set<String>() : Set(results.map(\.id))
            let fresh = result.results.filter { seen.insert($0.id).inserted }
            results = page == 1 ? fresh : results + fresh
            searchedText = text
            pagedValues = filters
            // A saved search: note which of these are new, and count them all as seen now.
            let opened = page == 1 && !usedSavedID ? model.savedSearches.first(where: { $0.id == savedID }) : nil
            if page == 1 { usedSavedID = true }
            if let saved = opened ?? model.savedSearch(sourceID: source.id, query: text, filters: filters) {
                let unseen = model.viewedSavedSearch(saved.id, resultIDs: fresh.map(\.id))
                // Only the first page's are marked: further down, "not seen" just means never scrolled to.
                if page == 1 { newIDs = unseen }
            } else if page == 1 {
                newIDs = []
            }
            self.page = page
            // Follow the site. A page of nothing but repeats doesn't end the list, but
            // three in a row does, so a site that never says it's done can't loop forever.
            repeatPages = fresh.isEmpty && page > 1 ? repeatPages + 1 : 0
            hasMore = result.hasMore && repeatPages < 3
            error = nil
            firstPageFailed = false
        } catch {
            guard mine == generation else { return }
            // A cancelled request isn't a failure to show; the next scroll asks again.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            self.error = error.readable
            firstPageFailed = page == 1
            if let request = error.verification { verifying = request }
        }
    }

    private func loadNextPage(retry: Bool) {
        // After a failed new search, "Try again" means that search, not more of the old one.
        if firstPageFailed {
            if retry, !loading { Task { await run(page: 1) } }
            return
        }
        guard hasMore, !loading, retry || error == nil else { return }
        if retry { error = nil }
        let next = page + 1
        Task { await run(page: next) }
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
        case .text, .range, .tags, .date:
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
    @State private var typed = ""

    private var included: [String] { values[filter.id] ?? [] }
    private var excluded: [String] { values[filter.excludeKey] ?? [] }

    private var query: String { typed.trimmingCharacters(in: .whitespaces) }

    /// The site's genres, plus any typed ones already picked, narrowed by what's typed.
    /// Picked ones always stay, so they can be tapped off.
    private var shown: [SearchFilter.Option] {
        let options = filter.options ?? []
        let extra = (included + excluded)
            .filter { id in !options.contains { $0.id == id } }
            .map { SearchFilter.Option(id: $0, label: $0) }
        let all = options + extra
        guard !query.isEmpty else { return all }
        return all.filter { included.contains($0.id) || excluded.contains($0.id) || GenreMatch.matches(query, $0.label) }
    }

    /// Typed text that names no listed genre can still be sent, where the source takes names.
    private var canAddTyped: Bool {
        filter.type == .tags && !query.isEmpty
            && !(filter.options ?? []).contains { GenreMatch.fold($0.label) == GenreMatch.fold(query) }
            && !included.contains(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a \(filter.label.lowercased().hasSuffix("s") ? String(filter.label.lowercased().dropLast()) : filter.label.lowercased())", text: $typed)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(pickBest)
                if !typed.isEmpty {
                    Button { typed = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.tertiarySystemFill)))
            .accessibilityIdentifier("genre.find")

            FlowLayout(spacing: 8) {
                ForEach(shown) { option in
                    Button { cycle(option.id) } label: { chip(option) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("genre.chip")
                }
                if canAddTyped {
                    Button { add(query) } label: {
                        FilterChipLabel(text: "Add “\(query)”", on: false, systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                }
            }
            if shown.isEmpty && !canAddTyped {
                Text("No genre like “\(query)”.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    /// Return in the field picks the closest genre, or adds the typed name.
    private func pickBest() {
        guard !query.isEmpty else { return }
        let options = filter.options ?? []
        if let best = options.first(where: { GenreMatch.fold($0.label) == GenreMatch.fold(query) })
            ?? options.first(where: { GenreMatch.matches(query, $0.label) }) {
            if !included.contains(best.id) { values[filter.id] = included + [best.id] }
        } else if canAddTyped {
            add(query)
            return
        }
        typed = ""
    }

    private func add(_ name: String) {
        values[filter.id] = included + [name]
        typed = ""
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

/// Forgiving genre matching for the find field: case and accents don't matter, any part
/// of a name matches, and a letter or two off still finds it ("romanse" finds Romance).
enum GenreMatch {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func matches(_ query: String, _ name: String) -> Bool {
        let q = fold(query), n = fold(name)
        guard !q.isEmpty else { return true }
        if n.contains(q) { return true }
        let allowed = q.count >= 7 ? 2 : q.count >= 4 ? 1 : 0
        guard allowed > 0 else { return false }
        // Against the whole name and against its start, so a typo in a short prefix counts.
        return distance(q, n) <= allowed || distance(q, String(n.prefix(q.count))) <= allowed
    }

    /// Edit distance between two short strings.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}
