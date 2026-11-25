import LibraryKit
import ShelfCore
import SwiftUI

struct WorkRoute: Hashable {
    let key: WorkKey
    let summary: WorkSummary
}

struct ReaderRequest: Identifiable, Hashable {
    let key: WorkKey
    let chapterID: String
    var id: String { key.id + "#" + chapterID }
}

/// One library for fics, manga and manhwa, grouped by fandom, with continue reading
/// and new-chapter badges.
@MainActor
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: LibraryFilter = .all
    @State private var path = NavigationPath()
    @State private var reading: ReaderRequest?
    @State private var choosingFiles = false
    @State private var deleting: WorkRecord?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 14, alignment: .top)]

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            ScrollView {
                FileImportBanner()
                if model.library.library.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Picker("Show", selection: $filter) {
                            ForEach(LibraryFilter.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.top, 4)

                        continueRail
                        updatesRow
                        sections
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Library")
            .toolbar { toolbar }
            .refreshable { await model.checkForUpdates() }
            .navigationDestination(for: WorkRoute.self) { WorkDetailView(route: $0) }
            .navigationDestination(for: LibrarySectionRoute.self) { SectionView(route: $0) }
            .navigationDestination(for: UpdatesRoute.self) { _ in UpdatesView() }
            .fullScreenCover(item: $reading) { ReaderView(request: $0) }
            .localFileImporter(isPresented: $choosingFiles, model: model)
            .modifier(DeleteLocalFileDialog(record: $deleting))
            .onChange(of: model.pendingOpen, initial: true) { _, key in
                guard let key, let record = model.record(key) else { return }
                model.pendingOpen = nil
                path.append(WorkRoute(key: key, summary: record.summary))
            }
            .onChange(of: model.pendingContinue, initial: true) { _, key in
                guard let key, let record = model.record(key) else { return }
                model.pendingContinue = nil
                if let chapter = record.continueChapter {
                    reading = ReaderRequest(key: key, chapterID: chapter.id)
                } else {
                    path.append(WorkRoute(key: key, summary: record.summary))
                }
            }
        }
    }

    // MARK: Sections

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your library is empty", systemImage: "books.vertical")
        } description: {
            Text("Import your own EPUB, PDF and CBZ files, or add a repository in Settings to find more. Books, comics, manga and manhwa all land on one shelf.")
        } actions: {
            Button { choosingFiles = true } label: {
                Label("Import files", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("library.importFiles")
        }
        .padding(.top, 80)
    }

    @ViewBuilder
    private var continueRail: some View {
        let items = LibraryLayout.continueReading(model.library.library, filter: filter)
        if !items.isEmpty {
            SectionHeader(title: "Continue reading")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { record in
                        Button {
                            if let chapter = record.continueChapter {
                                reading = ReaderRequest(key: record.key, chapterID: chapter.id)
                            }
                        } label: {
                            ContinueCard(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var updatesRow: some View {
        let count = model.library.library.filter { filter.matches($0.format) }.reduce(0) { $0 + $1.unreadNewCount }
        if count > 0 {
            NavigationLink(value: UpdatesRoute()) {
                HStack(spacing: 12) {
                    RowIcon(systemImage: "bell.fill", color: .shelfBadge)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(count == 1 ? "1 new chapter" : "\(count) new chapters").foregroundStyle(.primary)
                        Text(lastCheckText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.top, 18)
        }
    }

    private var lastCheckText: String {
        guard let last = model.library.lastUpdateCheck else { return "From your library" }
        return "Checked " + last.formatted(.relative(presentation: .named))
    }

    @ViewBuilder
    private var sections: some View {
        let sections = LibraryLayout.sections(
            model.library.library, filter: filter, grouping: model.settings.grouping, sort: model.settings.sort,
            sourceName: { model.sourceName($0) })
        ForEach(sections) { section in
            SectionHeader(title: section.title, subtitle: section.subtitle, mark: model.settings.grouping == .fandom ? section.title : nil) {
                if section.records.count > 6 {
                    NavigationLink("See all", value: LibrarySectionRoute(title: section.title, filter: filter))
                        .font(.subheadline)
                }
            }
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(section.records.prefix(section.records.count > 6 ? 6 : section.records.count)) { record in
                    NavigationLink(value: WorkRoute(key: record.key, summary: record.summary)) {
                        LibraryTile(record: record, delete: { deleting = record })
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .primaryAction) {
            Button { choosingFiles = true } label: {
                Image(systemName: "doc.badge.plus")
            }
            .accessibilityLabel("Import files")

            Menu {
                Picker("Group by", selection: $model.settings.grouping) {
                    ForEach(LibraryGrouping.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sort by", selection: $model.settings.sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Sort and group")

            Button {
                Task { await model.checkForUpdates() }
            } label: {
                if model.isCheckingUpdates {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(model.isCheckingUpdates)
            .accessibilityLabel("Check for new chapters")
        }
    }
}

struct LibrarySectionRoute: Hashable {
    let title: String
    let filter: LibraryFilter
}

struct UpdatesRoute: Hashable {}

@MainActor
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var mark: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if let mark {
                        Circle().fill(Color(hue: Hue.of(mark), saturation: 0.5, brightness: 0.62)).frame(width: 9, height: 9)
                    }
                    Text(title).font(.title3.weight(.bold))
                }
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal)
        .padding(.top, 26)
        .padding(.bottom, 10)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, mark: String? = nil) {
        self.init(title: title, subtitle: subtitle, mark: mark) { EmptyView() }
    }
}

@MainActor
struct LibraryTile: View {
    @Environment(AppModel.self) private var model
    let record: WorkRecord
    /// Asks to delete an imported file. Without it, imported files offer nothing to remove.
    var delete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BadgedCover(record: record, showBadge: model.settings.badgeNewChapters, downloaded: hasDownloads)
            Text(record.title).font(.footnote.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
            Text(meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .contextMenu {
            if LocalBooks.isLocal(record.key) {
                if let delete {
                    Button(role: .destructive, action: delete) {
                        Label("Delete from device", systemImage: "trash")
                    }
                }
            } else {
                Button(role: .destructive) { model.toggleLibrary(record.key) } label: {
                    Label("Remove from library", systemImage: "heart.slash")
                }
            }
        }
    }

    private var hasDownloads: Bool { !model.downloads.chapters(of: record.key).isEmpty }

    private var meta: String {
        if record.format.isText { return record.authors.first ?? record.format.label }
        if let line = record.progressLine { return line }
        return record.chapters.isEmpty ? record.format.label : "\(record.readingOrder.count) chapters"
    }
}

@MainActor
struct ContinueCard: View {
    let record: WorkRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BadgedCover(record: record, showBadge: false, compact: true).frame(width: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                HStack {
                    Text("\(Int((record.position?.progress ?? 0) * 100))%")
                    Spacer()
                    Text(record.format.label.lowercased())
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                ProgressBar(value: record.position?.progress ?? 0)
            }
        }
        .padding(10)
        .frame(width: 270, height: 116)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var subtitle: String {
        let next = record.continueChapter
        if let position = record.position, next?.id != position.chapterID, let next {
            return "Up next: \(next.title)"
        }
        return record.progressLine ?? record.position?.chapterTitle ?? ""
    }
}

/// Every work in one fandom (or type, or source).
@MainActor
struct SectionView: View {
    @Environment(AppModel.self) private var model
    let route: LibrarySectionRoute
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 14, alignment: .top)]

    var body: some View {
        let section = LibraryLayout.sections(
            model.library.library, filter: route.filter, grouping: model.settings.grouping, sort: model.settings.sort,
            sourceName: model.sourceName
        ).first { $0.title == route.title }
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(section?.records ?? []) { record in
                    NavigationLink(value: WorkRoute(key: record.key, summary: record.summary)) {
                        LibraryTile(record: record)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// New chapters across the library, newest checks first.
@MainActor
struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    @State private var reading: ReaderRequest?

    var body: some View {
        let records = model.library.library.filter { $0.unreadNewCount > 0 }.sorted { ($0.lastCheckedAt ?? .distantPast) > ($1.lastCheckedAt ?? .distantPast) }
        List {
            if let failures = model.lastReport?.failures, !failures.isEmpty {
                Section {
                    Text("\(failures.count) works couldn't be checked last time. Pull to try again.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(records) { record in
                Section {
                    ForEach(record.newChapterIDs.compactMap { id in record.chapters.first { $0.id == id } }) { chapter in
                        Button {
                            reading = ReaderRequest(key: record.key, chapterID: chapter.id)
                        } label: {
                            HStack {
                                Text(chapter.title).foregroundStyle(.primary)
                                Spacer()
                                if model.downloads.isDownloaded(ChapterRef(work: record.key, chapterID: chapter.id)) {
                                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.shelfAccent)
                                        .accessibilityLabel("Downloaded")
                                }
                            }
                        }
                        .swipeActions {
                            Button("Mark read") { model.markRead(chapter.id, in: record.key) }.tint(.shelfAccent)
                        }
                    }
                } header: {
                    HStack(spacing: 10) {
                        BadgedCover(record: record, showBadge: false, compact: true).frame(width: 30)
                        Text(record.title).font(.subheadline.weight(.semibold)).textCase(nil)
                    }
                }
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("You're all caught up", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("New chapters")
        .refreshable { await model.checkForUpdates() }
        .onAppear { model.markUpdatesSeen() }
        .fullScreenCover(item: $reading) { ReaderView(request: $0) }
    }
}
