import DownloadKit
import LibraryKit
import ShelfCore
import SwiftUI

/// A work's page: AO3-style tags and stats for fics, cover and reading mode for comics,
/// and the chapter list with new, read and downloaded marks.
@MainActor
struct WorkDetailView: View {
    @Environment(AppModel.self) private var model
    let route: WorkRoute

    @State private var loading = false
    @State private var error: String?
    @State private var verifying: VerificationRequest?
    @State private var migrating = false
    @State private var showingStyle = false
    @Environment(\.dismiss) private var dismiss
    @State private var reading: ReaderRequest?
    @State private var newestFirst = false
    @State private var showingGlossary = false
    @State private var showingHighlights = false

    private var key: WorkKey { route.key }
    private var record: WorkRecord? { model.record(key) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                actions
                if let record, record.unreadNewCount > 0, record.inLibrary {
                    Text(record.unreadNewCount == 1 ? "1 new chapter since you last read." : "\(record.unreadNewCount) new chapters since you last read.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.top, 8)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Color.shelfWarning)
                        .padding(.horizontal, 20).padding(.top, 10)
                }
                stats
                if let work = record?.work { series(work) }
                if let record { readingOptions(record) }
                tags
                summary
                chapterList
            }
            .padding(.bottom, 40)
        }
        .navigationTitle(record?.title ?? route.summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable { await load() }
        .task {
            model.ensureRecord(key, summary: route.summary)
            await load()
        }
        .fullScreenCover(item: $reading) { ReaderView(request: $0) }
        .browserVerification($verifying)
        .sheet(isPresented: $showingStyle) {
            ReaderStyleSheet(key: key).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $migrating) {
            if let record {
                NavigationStack {
                    MigrateView(record: record) { newKey in
                        // This page is for the old source; open the work where it lives now.
                        dismiss()
                        model.pendingOpen = newKey
                    }
                }
            }
        }
        .onChange(of: model.verifiedCount) { _, _ in
            if error != nil { Task { await load() } }
        }
        .sheet(isPresented: $showingGlossary) {
            NavigationStack { GlossaryView(key: key) }
        }
        .sheet(isPresented: $showingHighlights) {
            NavigationStack { HighlightsView(key: key) }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            try await model.refreshWork(key, summary: route.summary)
            error = nil
        } catch {
            // Offline with downloads still works from what's saved.
            self.error = record?.chapters.isEmpty == false ? "Showing saved info. \(error.readable)" : error.readable
            // Opening a work is the person's own action, so ask for the site's check right away.
            if let request = error.verification { verifying = request }
        }
    }

    // MARK: Header

    private var header: some View {
        let format = record?.format ?? model.format(for: route.summary, sourceID: key.sourceID)
        let fandom = record.map { LibraryLayout.fandom(of: $0) } ?? route.summary.fandoms?.first
        return HStack(alignment: .top, spacing: 16) {
            if !format.isText {
                CoverView(title: record?.title ?? route.summary.title, format: format, url: record?.coverURL ?? route.summary.coverURL)
                    .frame(width: 110)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text([format.label, fandom].compactMap { $0 }.joined(separator: " · ").uppercased())
                    .font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(Color.shelfAccent)
                Text(record?.title ?? route.summary.title)
                    .font(.system(.title, design: format.isText ? .serif : .default).weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                let authors = record?.authors ?? route.summary.authors
                if !authors.isEmpty {
                    Text("by " + authors.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                }
                statusChips
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var statusChips: some View {
        let work = record?.work
        FlowLayout(spacing: 6) {
            if let rating = work?.rating ?? route.summary.rating { Chip(text: shortRating(rating), style: .rating) }
            if let warnings = work?.warnings, let first = warnings.first {
                Chip(text: warnings.count > 1 ? "\(first) +\(warnings.count - 1)" : first, style: .warning, systemImage: "exclamationmark.triangle.fill")
            }
            if let categories = work?.categories, !categories.isEmpty { Chip(text: categories.joined(separator: ", "), style: .category) }
            if let status = statusText { Chip(text: status, style: .outline) }
            if let language = work?.originalLanguage { Chip(text: "From " + language, style: .outline) }
        }
        .padding(.top, 4)
    }

    private var statusText: String? {
        let work = record?.work
        let count = work?.chapterCount ?? route.summary.chapterCount
        switch (work?.status, count) {
        case let (status?, count?): return "\(status) · \(count)"
        case let (status?, nil): return status
        case let (nil, count?): return count.hasSuffix("?") ? "In progress · \(count)" : count
        default: return nil
        }
    }

    private func shortRating(_ rating: String) -> String {
        switch rating {
        case "General Audiences": "General"
        case "Teen And Up Audiences": "Teen"
        default: rating
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if let record {
            HStack(spacing: 10) {
                Button {
                    if let chapter = record.continueChapter { reading = ReaderRequest(key: key, chapterID: chapter.id) }
                } label: {
                    Label(readLabel(record), systemImage: "book")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(record.chapters.isEmpty)

                DownloadMenu(record: record)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.top, 18)
        }
    }

    private func readLabel(_ record: WorkRecord) -> String {
        guard let next = record.continueChapter else { return loading ? "Loading..." : "No chapters" }
        let index = (record.readingOrder.firstIndex { $0.id == next.id } ?? 0) + 1
        if record.position == nil { return "Start reading" }
        return record.format.isText ? "Read ch. \(index)" : "Read ch. \(index)"
    }

    // MARK: Stats, series, tags

    @ViewBuilder
    private var stats: some View {
        let work = record?.work
        let raw: [(String, String)?] = [
            (work?.wordCount ?? route.summary.wordCount).map { ($0.grouped, "Words") },
            (work?.chapterCount ?? route.summary.chapterCount).map { ($0, "Chapters") },
            (work?.kudos ?? route.summary.kudos).map { ($0.grouped, "Kudos") },
            work?.bookmarks.map { ($0.grouped, "Bookmarks") },
            work?.hits.map { ($0.grouped, "Hits") },
            (work?.updatedAt ?? route.summary.updatedAt).map { ($0.formatted(.dateTime.month(.abbreviated).day()), "Updated") },
        ]
        let items = raw.compactMap { $0 }
        if !items.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 3), spacing: 1) {
                ForEach(items, id: \.1) { item in
                    VStack(spacing: 2) {
                        Text(item.0).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                        Text(item.1).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 18)
        }
    }

    @ViewBuilder
    private func series(_ work: Work) -> some View {
        if let parts = work.series, !parts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(parts, id: \.title) { part in
                    HStack {
                        Image(systemName: "square.stack.3d.up").foregroundStyle(Color.shelfAccent)
                        if let n = part.part {
                            Text("Part \(n) of ").foregroundColor(.secondary) + Text(part.title).bold()
                        } else {
                            Text(part.title).bold()
                        }
                        Spacer()
                        if let url = part.url {
                            Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                                .accessibilityLabel("Open series in browser")
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
    }

    @ViewBuilder
    private func readingOptions(_ record: WorkRecord) -> some View {
        let groups = ChapterOrder.groups(record.chapters)
        Group {
            SectionHeader(title: record.format.isText ? "Reading" : "Reading mode")
            VStack(spacing: 12) {
                if !record.format.isText {
                    Picker("Reading mode", selection: Binding(
                        get: { model.readingMode(record) },
                        set: { mode in model.updateRecord(key) { $0.settings.readingMode = mode } }
                    )) {
                        ForEach([ReadingMode.pagedRightToLeft, .pagedLeftToRight, .vertical]) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if groups.count > 1 {
                    Picker("Translation group", selection: Binding(
                        get: { record.settings.preferredGroup ?? groups[0] },
                        set: { group in model.updateRecord(key) { $0.settings.preferredGroup = group } }
                    )) {
                        ForEach(groups, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if record.format.isText {
                    Button {
                        showingStyle = true
                    } label: {
                        HStack {
                            Label("Text style", systemImage: "textformat")
                            Spacer()
                            Text(record.settings.readerStyle == nil ? "Same as other works" : "Its own")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let translators = record.work?.translators, !translators.isEmpty {
                        LabeledContent("Translated by", value: translators.joined(separator: ", ")).font(.subheadline)
                    }
                    Toggle("Skip translator notes", isOn: Binding(
                        get: { record.settings.skipNotes },
                        set: { value in model.updateRecord(key) { $0.settings.skipNotes = value } }
                    ))
                    Button {
                        showingGlossary = true
                    } label: {
                        HStack {
                            Label("Glossary", systemImage: "character.book.closed")
                            Spacer()
                            Text("\(record.glossary.count) terms").foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        showingHighlights = true
                    } label: {
                        HStack {
                            Label("Highlights and notes", systemImage: "highlighter")
                            Spacer()
                            Text("\(record.highlights?.count ?? 0)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var tags: some View {
        if let work = record?.work {
            let allRows: [(String, [String], ChipStyle)] = [
                ("Rating", work.rating.map { [$0] } ?? [], .rating),
                ("Warnings", work.warnings ?? [], .warning),
                ("Category", work.categories ?? [], .category),
                ("Fandom", work.fandoms ?? [], .plain),
                ("Relationships", work.relationships ?? [], .ship),
                ("Characters", work.characters ?? [], .plain),
                ("Additional", work.tags ?? [], .free),
                ("Language", work.language.map { [$0] } ?? [], .outline),
            ]
            let rows = allRows.filter { !$0.1.isEmpty }
            if !rows.isEmpty {
                SectionHeader(title: "Tags")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows, id: \.0) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            FlowLayout(spacing: 6) {
                                ForEach(row.1, id: \.self) { Chip(text: $0, style: row.2) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        let text = (record?.work?.summaryHTML ?? route.summary.blurb)?.strippingHTML
        if let text, !text.isEmpty {
            SectionHeader(title: "Summary")
            Text(text)
                .font(.system(.body, design: .serif))
                .padding(.horizontal, 20)
                .textSelection(.enabled)
        }
    }

    // MARK: Chapters

    @ViewBuilder
    private var chapterList: some View {
        SectionHeader(title: "Chapters", subtitle: record.map { "\($0.readingOrder.count) chapters" }) {
            Button(newestFirst ? "Newest" : "Oldest") { newestFirst.toggle() }
                .font(.subheadline)
        }
        if let record {
            let order = record.readingOrder
            let chapters = newestFirst ? Array(order.reversed()) : order
            let groups = ChapterOrder.groups(record.chapters)
            LazyVStack(spacing: 0) {
                if chapters.isEmpty && loading { ProgressView().padding() }
                ForEach(chapters) { chapter in
                    ChapterRow(record: record, chapter: chapter, number: (order.firstIndex(of: chapter) ?? 0) + 1, showGroup: groups.count > 1) {
                        reading = ReaderRequest(key: key, chapterID: chapter.id)
                    }
                    Divider().padding(.leading, 56)
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 20)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let record {
                Button {
                    model.toggleLibrary(key)
                } label: {
                    Image(systemName: record.inLibrary ? "heart.fill" : "heart")
                }
                .accessibilityLabel(record.inLibrary ? "Remove from library" : "Add to library")

                Menu {
                    if let url = record.work?.url {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                        Link(destination: url) { Label("Open in browser", systemImage: "safari") }
                    }
                    if record.inLibrary {
                        Toggle(isOn: Binding(
                            get: { record.settings.autoDownload ?? model.settings.downloads.autoDownload },
                            set: { value in model.updateRecord(key) { $0.settings.autoDownload = value } }
                        )) {
                            Label("Download new chapters", systemImage: "arrow.down.circle")
                        }
                    }
                    Button {
                        if let last = record.readingOrder.last { model.markReadThrough(last.id, in: key) }
                    } label: {
                        Label("Mark all as read", systemImage: "checkmark.circle")
                    }
                    Button { migrating = true } label: {
                        Label("Move to another source", systemImage: "arrow.triangle.swap")
                    }
                    if let downloads = record.work?.downloads, !downloads.isEmpty {
                        Section("Download from the site") {
                            ForEach(downloads.keys.sorted(), id: \.self) { format in
                                if let url = downloads[format] {
                                    Link(destination: url) { Label(format.uppercased(), systemImage: "doc") }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
    }
}

@MainActor
struct ChapterRow: View {
    @Environment(AppModel.self) private var model
    let record: WorkRecord
    let chapter: Chapter
    let number: Int
    var showGroup = false
    let open: () -> Void

    private var ref: ChapterRef { ChapterRef(work: record.key, chapterID: chapter.id) }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title).lineLimit(2)
                        .foregroundStyle(record.isRead(chapter.id) ? Color.secondary : Color.primary)
                    let details = [showGroup ? chapter.group : nil, chapter.publishedAt?.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if record.newChapterIDs.contains(chapter.id) && !record.isRead(chapter.id) {
                    Text("NEW").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.shelfBadge))
                }
                if record.position?.chapterID == chapter.id {
                    Image(systemName: "bookmark.fill").foregroundStyle(Color.shelfAccent).accessibilityLabel("Current chapter")
                }
                downloadState
            }
            .padding(.vertical, 11)
            .padding(.trailing, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if record.isRead(chapter.id) {
                Button { model.markRead(chapter.id, in: record.key, false) } label: { Label("Mark unread", systemImage: "circle") }
            } else {
                Button { model.markRead(chapter.id, in: record.key) } label: { Label("Mark read", systemImage: "checkmark.circle") }
            }
            Button { model.markReadThrough(chapter.id, in: record.key) } label: {
                Label("Mark read up to here", systemImage: "checkmark.circle.badge.questionmark")
            }
            if model.downloads.isDownloaded(ref) {
                Button(role: .destructive) { Task { await model.downloadManager.delete(ref) } } label: {
                    Label("Remove download", systemImage: "trash")
                }
            } else if model.downloads.job(for: ref) == nil {
                Button { model.download([chapter], of: record) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            if let link = chapter.link {
                Link(destination: link) { Label("Open in browser", systemImage: "safari") }
            }
        }
    }

    @ViewBuilder
    private var downloadState: some View {
        if model.downloads.isDownloaded(ref) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tertiary).accessibilityLabel("Downloaded")
        } else if let job = model.downloads.job(for: ref) {
            if job.isFailed {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Color.shelfWarning).accessibilityLabel("Download failed")
            } else {
                ProgressView(value: job.progress).progressViewStyle(.circular).controlSize(.mini)
                    .accessibilityLabel("Downloading")
            }
        }
    }
}

/// "Download" button with choices, showing progress while chapters save.
@MainActor
struct DownloadMenu: View {
    @Environment(AppModel.self) private var model
    let record: WorkRecord

    var body: some View {
        let order = record.readingOrder
        let downloadedCount = model.downloads.chapters(of: record.key).count
        let queued = model.downloads.jobs.filter { $0.ref.work == record.key }
        Menu {
            Button { model.download(order, of: record) } label: { Label("All \(order.count) chapters", systemImage: "square.and.arrow.down.on.square") }
            let unread = order.filter { !record.isRead($0.id) }
            if !unread.isEmpty && unread.count != order.count {
                Button { model.download(unread, of: record) } label: { Label("Unread (\(unread.count))", systemImage: "circle") }
            }
            let next = record.upcomingUnread(5)
            if !next.isEmpty {
                Button { model.download(next, of: record) } label: { Label("Next \(next.count)", systemImage: "forward") }
            }
            if !queued.isEmpty {
                Button(role: .destructive) {
                    Task { for job in queued { await model.downloadManager.cancel(job.ref) } }
                } label: { Label("Cancel \(queued.count) queued", systemImage: "xmark.circle") }
            }
            if downloadedCount > 0 {
                Button(role: .destructive) { model.deleteDownloads(of: record.key) } label: {
                    Label("Remove downloads", systemImage: "trash")
                }
            }
        } label: {
            Group {
                if !queued.isEmpty {
                    Label("Saving \(queued.count)", systemImage: "arrow.down.circle.dotted")
                } else if downloadedCount > 0 && downloadedCount >= order.count {
                    Label("Downloaded", systemImage: "checkmark")
                } else {
                    Label("Download", systemImage: "arrow.down.to.line")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(order.isEmpty)
    }
}
