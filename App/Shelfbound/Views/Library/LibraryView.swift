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
    @State private var query = ""
    @State private var show: LibraryShow = .everything
    /// The shelf picked in the row of shelves, as its ID. Empty shows every work.
    @AppStorage("library.shelf") private var shelfID = ""
    /// Picking several works at once, to shelve, mark read, download or remove them together.
    @State private var selecting = false
    @State private var selection: Set<WorkKey> = []
    @State private var namingShelf = false
    @State private var shelfName = ""
    /// Works that go on the shelf being named.
    @State private var shelfKeys: [WorkKey] = []
    @State private var renamingShelf: CustomShelf?
    @State private var confirmingRemove = false

    private var activeShelf: CustomShelf? { model.shelves.first { $0.id.uuidString == shelfID } }

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 14, alignment: .top)]

    /// The library narrowed by the search field, the "Show" choice and the shelf picked.
    private var shelf: [WorkRecord] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let onShelf = activeShelf.map { Set($0.workIDs) }
        return model.library.library.filter { record in
            if let onShelf, !onShelf.contains(record.id) { return false }
            switch show {
            case .everything: break
            case .unread: if record.readChapterIDs.count >= record.readingOrder.count { return false }
            case .downloaded: if model.downloads.chapters(of: record.key).isEmpty { return false }
            }
            guard !text.isEmpty else { return true }
            return record.title.lowercased().contains(text)
                || record.authors.contains { $0.lowercased().contains(text) }
                || LibraryLayout.fandom(of: record).lowercased().contains(text)
        }
    }

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

                        shelfBar
                        if shelf.isEmpty {
                            nothingToShow
                        } else {
                            if !selecting {
                                continueRail
                                updatesRow
                            }
                            sections
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(title)
            .searchable(text: $query, prompt: "Search library")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { if selecting { selectionBar } }
            .alert(renamingShelf == nil ? "New shelf" : "Rename shelf", isPresented: $namingShelf) {
                TextField("Name", text: $shelfName)
                Button(renamingShelf == nil ? "Create" : "Save") { commitShelfName() }
                Button("Cancel", role: .cancel) { renamingShelf = nil }
            } message: {
                Text(shelfMessage)
            }
            .confirmationDialog(removeTitle, isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove from library", role: .destructive) { removeSelected() }
            } message: {
                Text(removeMessage)
            }
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

    private var title: String {
        guard selecting else { return "Library" }
        return selection.isEmpty ? "Select works" : "\(selection.count) selected"
    }

    private var shelfMessage: String {
        if renamingShelf != nil { return "" }
        if shelfKeys.isEmpty { return "A shelf holds any works you choose. A work can sit on several." }
        return shelfKeys.count == 1 ? "The work goes on it." : "The \(shelfKeys.count) works go on it."
    }

    private var removeTitle: String {
        selection.count == 1 ? "Remove this work from your library?" : "Remove \(selection.count) works from your library?"
    }

    private var removeMessage: String {
        selection.contains(where: { LocalBooks.isLocal($0) })
            ? "Your place in each is kept. Imported files stay; delete those one at a time."
            : "Your place in each is kept, in case you add it back."
    }

    /// The shelf, search or "Show" choice leaves nothing to list.
    @ViewBuilder
    private var nothingToShow: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: query).padding(.top, 60)
        } else if show == .everything, let activeShelf {
            ContentUnavailableView {
                Label("Nothing on \(activeShelf.name) yet", systemImage: "books.vertical")
            } description: {
                Text("Touch and hold a work and choose Shelves, or choose Select from the menu to add several at once.")
            } actions: {
                Button("Show all works") { shelfID = "" }
            }
            .padding(.top, 60)
        } else {
            ContentUnavailableView {
                Label("Nothing \(show.label.lowercased()) here", systemImage: "line.3.horizontal.decrease.circle")
            } actions: {
                Button("Show everything") { show = .everything }
            }
            .padding(.top, 60)
        }
    }

    /// The person's own shelves, as a row of chips. Hidden until there is one.
    @ViewBuilder
    private var shelfBar: some View {
        let shelves = model.shelves
        if !shelves.isEmpty {
            let inLibrary = Set(model.library.library.map(\.id))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { shelfID = "" } label: { FilterChipLabel(text: "All works", on: activeShelf == nil) }
                        .buttonStyle(.plain)
                    ForEach(shelves) { item in
                        let count = item.workIDs.filter { inLibrary.contains($0) }.count
                        Button { shelfID = item.id.uuidString } label: {
                            FilterChipLabel(text: "\(item.name) · \(count)", on: activeShelf?.id == item.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.shelf")
                        .contextMenu {
                            Button {
                                renamingShelf = item
                                shelfName = item.name
                                namingShelf = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                if activeShelf?.id == item.id { shelfID = "" }
                                model.deleteShelf(item.id)
                            } label: {
                                Label("Delete shelf", systemImage: "trash")
                            }
                        }
                    }
                    Button { nameNewShelf(for: []) } label: {
                        FilterChipLabel(text: "New shelf", on: false, systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }
        }
    }

    private func nameNewShelf(for keys: [WorkKey]) {
        renamingShelf = nil
        shelfKeys = keys
        shelfName = ""
        namingShelf = true
    }

    private func commitShelfName() {
        if let renamingShelf {
            model.renameShelf(renamingShelf.id, to: shelfName)
        } else if let id = model.createShelf(named: shelfName, adding: shelfKeys) {
            // A shelf made empty is opened, ready to be filled.
            if shelfKeys.isEmpty { shelfID = id.uuidString }
            Haptics.light()
        }
        renamingShelf = nil
        shelfKeys = []
    }

    // MARK: Selecting several

    private var selectedRecords: [WorkRecord] { selection.compactMap { model.record($0) } }

    private func endSelecting() {
        selecting = false
        selection = []
    }

    private func removeSelected() {
        for record in selectedRecords where record.inLibrary && !LocalBooks.isLocal(record.key) {
            model.toggleLibrary(record.key)
        }
        endSelecting()
    }

    /// What can be done to the works picked, along the bottom while selecting.
    private var selectionBar: some View {
        HStack(alignment: .top) {
            ShelfMenu(model: model, keys: Array(selection), stacked: true) { nameNewShelf(for: Array(selection)) }
                .frame(maxWidth: .infinity)
            Button {
                for record in selectedRecords {
                    if let last = record.readingOrder.last { model.markReadThrough(last.id, in: record.key) }
                }
                Haptics.success()
                endSelecting()
            } label: {
                StackedLabel(title: "Mark read", systemImage: "checkmark.circle")
            }
            .frame(maxWidth: .infinity)
            Button {
                for record in selectedRecords {
                    let unread = record.readingOrder.filter { !record.isRead($0.id) }
                    if !unread.isEmpty { model.download(unread, of: record) }
                }
                endSelecting()
            } label: {
                StackedLabel(title: "Download", systemImage: "arrow.down.circle")
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Download unread chapters")
            Button(role: .destructive) { confirmingRemove = true } label: {
                StackedLabel(title: "Remove", systemImage: "minus.circle")
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(selection.isEmpty)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var continueRail: some View {
        let items = LibraryLayout.continueReading(shelf, filter: filter)
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
            shelf, filter: filter, grouping: model.settings.grouping, sort: model.settings.sort,
            sourceName: { model.sourceName($0) })
        ForEach(sections) { section in
            SectionHeader(title: section.title, subtitle: section.subtitle, mark: model.settings.grouping == .fandom ? section.title : nil) {
                if section.records.count > 6, !selecting {
                    NavigationLink("See all", value: LibrarySectionRoute(title: section.title, filter: filter, shelf: activeShelf?.id))
                        .font(.subheadline)
                }
            }
            LazyVGrid(columns: columns, spacing: 18) {
                // While selecting, every work shows, so none is out of reach behind "See all".
                ForEach(selecting ? section.records : Array(section.records.prefix(6))) { record in
                    if selecting {
                        Button {
                            if selection.remove(record.key) == nil { selection.insert(record.key) }
                        } label: {
                            LibraryTile(record: record, selected: selection.contains(record.key))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection.contains(record.key) ? .isSelected : [])
                    } else {
                        NavigationLink(value: WorkRoute(key: record.key, summary: record.summary)) {
                            LibraryTile(record: record, delete: { deleting = record }, newShelf: { nameNewShelf(for: [$0]) })
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        // One menu instead of three buttons: pulling down already checks for new chapters,
        // and importing is an occasional job.
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                let all = Set(shelf.filter { filter.matches($0.format) }.map(\.key))
                Button(selection == all && !all.isEmpty ? "Deselect all" : "Select all") {
                    selection = selection == all ? [] : all
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { endSelecting() }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isCheckingUpdates {
                ProgressView().accessibilityLabel("Checking for new chapters")
            }
            Menu {
                Picker("Show", selection: $show) {
                    ForEach(LibraryShow.allCases) { Text($0.label).tag($0) }
                }
                Picker("Group by", selection: $model.settings.grouping) {
                    ForEach(LibraryGrouping.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sort by", selection: $model.settings.sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
                Section {
                    Button { selecting = true } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    Button { nameNewShelf(for: []) } label: {
                        Label("New shelf", systemImage: "books.vertical")
                    }
                }
                Section {
                    Button {
                        Task { await model.checkForUpdates() }
                    } label: {
                        Label("Check for new chapters", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isCheckingUpdates)
                    Button { choosingFiles = true } label: {
                        Label("Import files", systemImage: "doc.badge.plus")
                    }
                }
            } label: {
                Image(systemName: show == .everything ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityLabel("Show, sort and more")
        }
    }
}

/// Which works the library shows, from its menu.
enum LibraryShow: String, CaseIterable, Identifiable {
    case everything, unread, downloaded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .everything: "Everything"
        case .unread: "Unread"
        case .downloaded: "Downloaded"
        }
    }
}

struct LibrarySectionRoute: Hashable {
    let title: String
    let filter: LibraryFilter
    /// The shelf the library was showing, so "See all" lists the same works.
    var shelf: UUID? = nil
}

/// "Shelves", with each shelf ticked when every one of `keys` is on it. Tapping a shelf
/// puts the works on it or takes them off.
@MainActor
struct ShelfMenu: View {
    let model: AppModel
    let keys: [WorkKey]
    /// Icon over title, for the bar shown while selecting.
    var stacked = false
    /// Asks for a name for a new shelf that these works go on.
    var newShelf: (() -> Void)? = nil

    var body: some View {
        Menu {
            ForEach(model.shelves) { shelf in
                let all = !keys.isEmpty && keys.allSatisfy { shelf.contains($0) }
                Button { model.setShelf(shelf.id, contains: !all, keys) } label: {
                    if all { Label(shelf.name, systemImage: "checkmark") } else { Text(shelf.name) }
                }
            }
            if let newShelf {
                Button(action: newShelf) { Label("New shelf", systemImage: "plus") }
            }
        } label: {
            if stacked {
                StackedLabel(title: "Shelves", systemImage: "books.vertical")
            } else {
                Label("Shelves", systemImage: "books.vertical")
            }
        }
    }
}

/// An icon with its title under it, for a bar of a few actions.
struct StackedLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 20))
            Text(title).font(.caption2)
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
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
    /// Asks for a name for a new shelf that this work goes on.
    var newShelf: ((WorkKey) -> Void)? = nil
    /// While several works are being picked: whether this one is. Nil otherwise.
    var selected: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BadgedCover(record: record, showBadge: model.settings.badgeNewChapters, downloaded: hasDownloads)
                .overlay(alignment: .topLeading) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selected ? Color.shelfAccent : Color.black.opacity(0.35))
                            .shadow(radius: 1)
                            .padding(5)
                    }
                }
                .opacity(selected == false ? 0.75 : 1)
            Text(record.title).font(.footnote.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
            Text(meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .contextMenu {
            if selected == nil, record.inLibrary, newShelf != nil || !model.shelves.isEmpty {
                ShelfMenu(model: model, keys: [record.key], newShelf: newShelf == nil ? nil : { newShelf?(record.key) })
            }
            if LocalBooks.isLocal(record.key) {
                if let delete {
                    Button(role: .destructive, action: delete) {
                        Label("Delete from device", systemImage: "trash")
                    }
                }
            } else {
                Button(role: .destructive) { model.toggleLibrary(record.key) } label: {
                    Label("Remove from library", systemImage: "minus.circle")
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
    @State private var deleting: WorkRecord?
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 14, alignment: .top)]

    var body: some View {
        let onShelf = route.shelf.flatMap { id in model.shelves.first { $0.id == id } }.map { Set($0.workIDs) }
        let section = LibraryLayout.sections(
            model.library.library.filter { onShelf?.contains($0.id) ?? true }, filter: route.filter, grouping: model.settings.grouping, sort: model.settings.sort,
            sourceName: model.sourceName
        ).first { $0.title == route.title }
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(section?.records ?? []) { record in
                    NavigationLink(value: WorkRoute(key: record.key, summary: record.summary)) {
                        LibraryTile(record: record, delete: { deleting = record })
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .modifier(DeleteLocalFileDialog(record: $deleting))
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
