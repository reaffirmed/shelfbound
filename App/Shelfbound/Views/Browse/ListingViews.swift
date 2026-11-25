import RepoKit
import ShelfCore
import SwiftUI

/// "See all" for one of a source's browse lists.
struct ListingRoute: Hashable {
    let source: InstalledSource
    let listing: SourceListing
}

/// One browse list as a List section: the title and "See all" in the header, and the
/// first page as a row of covers that scrolls sideways.
@MainActor
struct ListingSection: View {
    @Environment(AppModel.self) private var model
    let source: InstalledSource
    let listing: SourceListing
    /// On Discover, the first row of each source carries the source's name above it, so
    /// the rows read as one group per source.
    var sourceHeading = false
    /// Bumped by pull to refresh, which refetches instead of using the cached page.
    var refreshToken = 0

    @State private var page: SearchPage?
    @State private var error: String?
    @State private var verify: VerificationRequest?
    @State private var loadedToken: Int?

    private var shown: SearchPage? { page ?? model.cachedListing(sourceID: source.id, listingID: listing.id) }

    var body: some View {
        Section {
            row
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .task(id: refreshToken) { await load() }
        } header: {
            header
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sourceHeading {
                HStack(spacing: 8) {
                    SourceIcon(name: source.manifest.name, size: 26)
                    Text(source.manifest.name).font(.title2.weight(.bold)).foregroundStyle(Color(.label))
                }
                .padding(.top, 12)
            }
            listingTitle
        }
        .textCase(nil)
    }

    private var listingTitle: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.title)
                    .font(.title3.weight(.semibold))
                    // Section headers default to grey; the list's title should read like one.
                    .foregroundStyle(Color(.label))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            NavigationLink(value: ListingRoute(source: source, listing: listing)) {
                Text("See all").font(.subheadline.weight(.medium)).foregroundStyle(Color.shelfAccent)
            }
            .buttonStyle(.plain)
        }
        .textCase(nil)
        .padding(.top, 8)
    }

    private var subtitle: String? { listing.subtitle }

    @ViewBuilder
    private var row: some View {
        if let shown, !shown.results.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(shown.results) { work in
                        NavigationLink(value: WorkRoute(key: WorkKey(sourceID: source.id, workID: work.id), summary: work)) {
                            ListingTile(work: work, format: work.format ?? source.manifest.defaultFormat)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
        } else if let error {
            VStack(alignment: .leading, spacing: 6) {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                if let verify { VerifyInBrowserButton(request: verify) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        } else if shown != nil {
            Text("Nothing here right now.")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 8)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in ListingTile.placeholder }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .scrollDisabled(true)
            .accessibilityLabel("Loading \(listing.title)")
        }
    }

    private func load() async {
        guard loadedToken != refreshToken else { return }
        let refresh = loadedToken != nil
        do {
            page = try await model.listing(sourceID: source.id, listingID: listing.id, refresh: refresh)
            error = nil
            verify = nil
            loadedToken = refreshToken
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.readable
            verify = error.verification
        }
    }
}

/// A cover with the title under it, for browse rows.
@MainActor
struct ListingTile: View {
    static let width: CGFloat = 108

    let work: WorkSummary
    let format: WorkFormat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverView(
                title: work.title, author: work.authors.first ?? "", format: format, url: work.coverURL,
                words: work.wordCount, chapters: work.chapterCount)
            TileText(title: work.title, caption: meta)
        }
        .frame(width: Self.width, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private var meta: String {
        if format.isText, let kudos = work.kudos { return "♥ \(kudos.grouped)" }
        return work.authors.first ?? work.fandoms?.first ?? format.label
    }

    static var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
            RoundedRectangle(cornerRadius: 3).fill(Color(.tertiarySystemFill)).frame(height: 10)
            RoundedRectangle(cornerRadius: 3).fill(Color(.tertiarySystemFill)).frame(width: 60, height: 8)
        }
        .frame(width: width, alignment: .topLeading)
    }
}

/// The whole of one browse list, loading more as you scroll.
@MainActor
struct ListingView: View {
    @Environment(AppModel.self) private var model
    let route: ListingRoute

    @State private var results: [WorkSummary] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var verifying: VerificationRequest?

    var body: some View {
        List {
            ForEach(results) { work in
                NavigationLink(value: WorkRoute(key: WorkKey(sourceID: route.source.id, workID: work.id), summary: work)) {
                    WorkCard(work: work, format: work.format ?? route.source.manifest.defaultFormat)
                }
                .onAppear { if work.id == results.last?.id { Task { await load(page + 1) } } }
            }
            if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { Task { await load(page + 1) } }
                }
            } else if loading && !results.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .overlay {
            if results.isEmpty && loading {
                ProgressView()
            } else if results.isEmpty && !hasMore && error == nil {
                ContentUnavailableView("Nothing here right now", systemImage: "tray")
            }
        }
        .navigationTitle(route.listing.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(1, refresh: true) }
        .browserVerification($verifying)
        .task { if results.isEmpty { await load(1) } }
    }

    private func load(_ next: Int, refresh: Bool = false) async {
        guard !loading, refresh || hasMore || next == 1 else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await model.listing(sourceID: route.source.id, listingID: route.listing.id, page: next, refresh: refresh)
            if next == 1 {
                results = result.results
            } else {
                let seen = Set(results.map(\.id))
                results += result.results.filter { !seen.contains($0.id) }
            }
            page = next
            hasMore = result.hasMore && !result.results.isEmpty
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.readable
            if let request = error.verification { verifying = request }
        }
    }
}

/// A tile's title with its caption right under it. The space for a second title line is
/// kept below the caption, not between them, so tiles in a row still line up.
struct TileText: View {
    let title: String
    let caption: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            lines(Text("X\nX"), Text("X")).hidden()
            lines(Text(title), Text(caption))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func lines(_ title: Text, _ caption: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            caption
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
