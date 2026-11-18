import DownloadKit
import Foundation
import LibraryKit
import Observation
import RepoKit
import ShelfCore
import SourceKit
import UIKit

struct RepoLink: Identifiable {
    let url: String
    var id: String { url }
}

struct SavedRepo: Codable, Hashable, Identifiable {
    var url: URL
    var name: String
    var maintainer: String?
    var publicKey: String
    var sourceCount: Int?
    var checkedAt: Date?
    var id: URL { url }
}

/// A chapter link that no installed source can read.
struct UnhandledLink: Error, LocalizedError {
    let url: URL
    var errorDescription: String? { "No installed source reads \(url.host ?? "this site"). Open it in the browser or use reader mode." }
}

/// The app's state: repos and sources, the library, settings and downloads.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    nonisolated static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"

    private(set) var repos: [SavedRepo] = []
    private(set) var installed: [InstalledSource] = []
    /// Updates available for installed sources, by source ID, from the last repo check.
    private(set) var sourceUpdates: [String: (entry: RepoEntry, index: RepoIndex, repo: URL)] = [:]
    private(set) var library = LibraryState()
    var settings = AppSettings() {
        didSet { settingsChanged(from: oldValue) }
    }
    private(set) var downloads = DownloadSnapshot()
    private(set) var isCheckingUpdates = false
    private(set) var lastReport: UpdateReport?
    /// Goes up each time the person passes a site's bot check, so screens showing that
    /// error can try again.
    private(set) var verifiedCount = 0

    var lastError: String?
    var showingError = false
    var pendingRepoLink: RepoLink?
    /// Set by a notification tap; the library opens this work.
    var pendingOpen: WorkKey?
    /// A tapped "downloads paused" notification: show the Downloads screen.
    var pendingShowDownloads = false

    @ObservationIgnored let network = URLSessionNetwork(clearances: .shared)
    @ObservationIgnored let networkMonitor: NetworkMonitor
    @ObservationIgnored let transfer: BackgroundTransfer
    @ObservationIgnored let downloadManager: DownloadManager
    @ObservationIgnored private let store: SourceStore?
    @ObservationIgnored private let client = RepoClient(appVersion: AppModel.appVersion)
    @ObservationIgnored private var runtimes: [String: SourceRuntime] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let libraryFile: LibraryFile?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let resolverBox: ResolverBox
    @ObservationIgnored private let widgets = WidgetBridge()

    private enum Keys {
        static let repos = "repos"
        static let settings = "settings"
    }

    private init() {
        store = try? SourceStore()
        libraryFile = try? LibraryFile.default()
        let layout = (try? DownloadLayout.default())
            ?? DownloadLayout(root: FileManager.default.temporaryDirectory.appendingPathComponent("Downloads"))
        let transfer = BackgroundTransfer(staging: layout.staging)
        let monitor = NetworkMonitor()
        let box = ResolverBox()
        let loadedSettings = Self.load(AppSettings.self, Keys.settings, from: .standard) ?? AppSettings()
        self.transfer = transfer
        self.networkMonitor = monitor
        self.resolverBox = box
        downloadManager = DownloadManager(
            layout: layout, resolver: box, transfer: transfer, network: monitor,
            settings: loadedSettings.downloads)

        settings = loadedSettings
        repos = Self.load([SavedRepo].self, Keys.repos, from: .standard) ?? []
        installed = store?.installed() ?? []
        library = libraryFile?.load() ?? LibraryState()
        resolverBox.model = self
        ImageLoader.shared.screenScale = UIScreen.main.scale

        let manager = downloadManager
        networkMonitor.onChange = { _ in Task { await manager.networkChanged() } }
        Task {
            _ = await manager.observe { snapshot in
                Task { @MainActor in AppModel.shared.downloadsChanged(snapshot) }
            }
            await manager.start()
        }
        configureRateLimits()
    }

    // MARK: - Repos

    func handle(url: URL) {
        // shelfbound://add-repo?url=https://example.github.io/repo
        // shelfbound://open?source=…&work=… from a widget
        if let key = WidgetSnapshot.workKey(from: url) {
            pendingOpen = key
            return
        }
        guard url.scheme == "shelfbound", url.host == "add-repo",
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value
        else { return }
        pendingRepoLink = RepoLink(url: target)
    }

    func fetchIndex(for input: String) async throws -> (URL, RepoIndex) {
        guard let url = RepoClient.indexURL(for: input) else { throw URLError(.badURL) }
        return (url, try await client.fetchIndex(url))
    }

    func addRepo(url: URL, index: RepoIndex) {
        repos.removeAll { $0.url == url }
        repos.append(SavedRepo(url: url, name: index.name, maintainer: index.maintainer, publicKey: index.publicKey,
                               sourceCount: index.sources.count, checkedAt: Date()))
        save(repos, as: Keys.repos)
    }

    func removeRepo(_ repo: SavedRepo) {
        repos.removeAll { $0.url == repo.url }
        client.pins.removePin(for: repo.url)
        save(repos, as: Keys.repos)
    }

    /// Refreshes every repo's index and notes which installed sources have updates.
    func refreshRepos() async {
        for repo in repos {
            guard let index = try? await client.fetchIndex(repo.url) else { continue }
            if let i = repos.firstIndex(where: { $0.url == repo.url }) {
                repos[i].sourceCount = index.sources.count
                repos[i].checkedAt = Date()
            }
            for entry in store?.updates(in: index, repo: repo.url) ?? [] {
                sourceUpdates[entry.id] = (entry, index, repo.url)
            }
        }
        save(repos, as: Keys.repos)
    }

    // MARK: - Sources

    func install(_ entry: RepoEntry, index: RepoIndex, repo: URL) async {
        do {
            let (package, data) = try await client.downloadPackage(entry, index: index, indexURL: repo)
            try store?.install(package, data: data, from: repo)
            runtimes[entry.id]?.close()
            runtimes[entry.id] = nil
            sourceUpdates[entry.id] = nil
            installed = store?.installed() ?? []
            configureRateLimits()
        } catch {
            report(error)
        }
    }

    func updateSource(_ id: String) async {
        guard let update = sourceUpdates[id] else { return }
        await install(update.entry, index: update.index, repo: update.repo)
    }

    func uninstall(_ id: String) {
        runtimes[id]?.close()
        runtimes[id] = nil
        try? store?.remove(id)
        installed = store?.installed() ?? []
    }

    func isInstalled(_ entry: RepoEntry) -> InstalledSource? {
        installed.first { $0.id == entry.id }
    }

    func manifest(for sourceID: String) -> SourceManifest? {
        installed.first { $0.id == sourceID }?.manifest
    }

    func sourceName(_ sourceID: String) -> String { manifest(for: sourceID)?.name ?? sourceID }

    func runtime(for sourceID: String) throws -> SourceRuntime {
        if let runtime = runtimes[sourceID] { return runtime }
        guard let store else { throw SourceError.unavailable }
        let runtime = try SourceRuntime(
            package: try store.package(for: sourceID), network: network,
            settings: ["maxRating": settings.maxRating.rawValue])
        runtimes[sourceID] = runtime
        return runtime
    }

    /// Installed sources the content filter allows, without link-only helpers.
    var visibleSources: [InstalledSource] {
        installed.filter { $0.manifest.contentRating <= settings.maxRating }
    }

    var searchableSources: [InstalledSource] {
        visibleSources.filter { !($0.manifest.has(.links) && $0.manifest.capabilities?.count == 1) }
    }

    private func configureRateLimits() {
        let pairs = installed.compactMap { source -> (String, Int)? in
            guard let ms = source.manifest.rateLimit?.minIntervalMs else { return nil }
            return (source.id, ms)
        }
        let network = self.network
        Task {
            for (id, ms) in pairs { await network.setMinimumInterval(.milliseconds(ms), for: id) }
        }
    }

    // MARK: - Library

    func record(_ key: WorkKey) -> WorkRecord? { library[key] }

    /// The work's own choice, else the app default for its format (Settings > Manga direction).
    func readingMode(_ record: WorkRecord) -> ReadingMode {
        if record.format.isText { return .text }
        if let mode = record.settings.readingMode { return mode }
        return record.format == .manga ? settings.pagedDirection : record.format.defaultReadingMode
    }

    func format(for summary: WorkSummary, sourceID: String) -> WorkFormat {
        summary.format ?? manifest(for: sourceID)?.defaultFormat ?? .fic
    }

    /// Makes sure a record exists for a work the user is looking at.
    @discardableResult
    func ensureRecord(_ key: WorkKey, summary: WorkSummary) -> WorkRecord {
        if let existing = library[key] { return existing }
        let record = library.upsert(key: key, summary: summary, format: format(for: summary, sourceID: key.sourceID))
        return record
    }

    /// Fetches the work page and chapter list and merges them into the library.
    func refreshWork(_ key: WorkKey, summary: WorkSummary) async throws {
        ensureRecord(key, summary: summary)
        let runtime = try runtime(for: key.sourceID)
        async let w = runtime.getWork(id: key.workID)
        async let c = runtime.getChapters(workID: key.workID)
        let (work, chapters) = try await (w, c)
        let existing = library[key]
        library.upsert(
            key: key, summary: existing?.summary ?? summary, work: work,
            format: existing?.format ?? format(for: summary, sourceID: key.sourceID))
        library.update(key) { record in _ = UpdateChecker.apply(chapters, to: &record) }
        scheduleSave()
    }

    func toggleLibrary(_ key: WorkKey) {
        guard let record = library[key] else { return }
        library.setInLibrary(key, !record.inLibrary)
        if !record.inLibrary { Notifications.requestPermissionIfNeeded() }
        scheduleSave()
        refreshBadge()
    }

    func updateRecord(_ key: WorkKey, _ change: (inout WorkRecord) -> Void) {
        library.update(key, change)
        scheduleSave()
    }

    func savePosition(_ position: ReadingPosition, for key: WorkKey) {
        library.savePosition(position, for: key)
        scheduleSave()
    }

    func markRead(_ chapterID: String, in key: WorkKey, _ read: Bool = true) {
        let changed = library.markRead(chapterID, in: key, read)
        scheduleSave()
        refreshBadge()
        guard read, changed else { return }
        let ref = ChapterRef(work: key, chapterID: chapterID)
        Task { await downloadManager.markRead(ref) }
        if let record = library[key] { downloadAhead(record) }
    }

    func markReadThrough(_ chapterID: String, in key: WorkKey) {
        library.markReadThrough(chapterID, in: key)
        scheduleSave()
        refreshBadge()
    }

    /// The text style for a work: its own, if it has one, else the app's.
    func readerStyle(for key: WorkKey?) -> ReaderStyle {
        key.flatMap { library[$0]?.settings.readerStyle } ?? settings.readerStyle
    }

    /// Changes the style the work uses: its own when it has one, else the app's.
    func setReaderStyle(_ style: ReaderStyle, for key: WorkKey?) {
        if let key, library[key]?.settings.readerStyle != nil {
            updateRecord(key) { $0.settings.readerStyle = style }
        } else {
            settings.readerStyle = style
        }
    }

    func autoScrollSpeed(for key: WorkKey) -> Double {
        library[key]?.settings.autoScrollSpeed ?? settings.autoScrollSpeed
    }

    // MARK: - Highlights

    func addHighlight(_ highlight: Highlight, to key: WorkKey) {
        library.addHighlight(highlight, to: key)
        scheduleSave()
    }

    func removeHighlight(_ id: UUID, from key: WorkKey) {
        library.removeHighlight(id, from: key)
        scheduleSave()
    }

    func setHighlightNote(_ id: UUID, note: String, in key: WorkKey) {
        library.setHighlightNote(id, note: note, in: key)
        scheduleSave()
    }

    /// Moves a work to another source, keeping read chapters, place, settings, glossary and highlights.
    /// Downloads from the old source are deleted, since nothing can open them any more.
    func migrate(_ old: WorkKey, to key: WorkKey, summary: WorkSummary, work: Work?, chapters: [Chapter]) {
        guard let record = library[old], old != key else { return }
        let next = Migration.migrate(
            record, to: key, summary: summary, work: work, chapters: chapters,
            format: format(for: summary, sourceID: key.sourceID))
        library.replace(old, with: next)
        scheduleSave()
        refreshBadge()
        Task { await downloadManager.deleteWork(old) }
        if next.inLibrary { downloadAhead(next) }
    }

    func removeFromHistory(_ key: WorkKey) {
        library.update(key) { $0.lastReadAt = nil; $0.position = nil }
        scheduleSave()
    }

    func markUpdatesSeen() {
        library.lastViewedUpdatesAt = Date()
        scheduleSave()
    }

    // MARK: - Chapter content

    /// Content for one chapter: the downloaded copy if there is one, else from the source.
    /// Chapter links are handed to whichever installed source reads that site.
    func content(for ref: ChapterRef, chapter: Chapter?) async throws -> ChapterContent {
        if let local = await downloadManager.localContent(for: ref) { return local }
        // A chapter that already points at a site some source reads goes straight there.
        // Otherwise the work's own source answers, and may hand back a link (a discovery
        // source turns its redirect into the translator's chapter URL).
        if let link = chapter?.link, linkHandler(for: link) != nil {
            return try await resolve(link: link)
        }
        let content = try await runtime(for: ref.work.sourceID).getChapterContent(workID: ref.work.workID, chapterID: ref.chapterID)
        if case let .link(url) = content { return try await resolve(link: url) }
        return content
    }

    func linkHandler(for url: URL) -> InstalledSource? {
        visibleSources.first { $0.manifest.has(.links) && DomainPolicy(patterns: $0.manifest.domains).allows(url) }
    }

    func resolve(link url: URL) async throws -> ChapterContent {
        guard let handler = linkHandler(for: url) else { throw UnhandledLink(url: url) }
        let content = try await runtime(for: handler.id).resolveLink(url)
        if case .link = content { throw UnhandledLink(url: url) }
        return content
    }

    /// Reader mode for a chapter link: fetch the page and keep only its text.
    func readerMode(_ url: URL) async throws -> ChapterContent {
        guard url.scheme == "https" || url.scheme == "http" else { throw URLError(.unsupportedURL) }
        let response = try await network.fetch(URLRequest(url: url), sourceID: "reader-mode")
        guard (200..<300).contains(response.status) else { throw URLError(.badServerResponse) }
        let article = try ReaderMode.extract(html: response.body, url: URL(string: response.url) ?? url)
        guard article.wordCount > 50 else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "Couldn't find the chapter text on that page."])
        }
        return .text(html: article.html, notesBefore: nil, notesAfter: nil)
    }

    /// For the download queue: like `content`, but falls back to reader mode for links.
    fileprivate func contentForDownload(_ ref: ChapterRef) async throws -> ChapterContent {
        let chapter = library[ref.work]?.chapters.first { $0.id == ref.chapterID }
        do {
            return try await content(for: ref, chapter: chapter)
        } catch let error as UnhandledLink {
            return try await readerMode(error.url)
        }
    }

    // MARK: - Downloads

    func download(_ chapters: [Chapter], of record: WorkRecord, automatic: Bool = false) {
        let requests = chapters.map {
            DownloadRequest(
                ref: ChapterRef(work: record.key, chapterID: $0.id), workTitle: record.title, chapterTitle: $0.title,
                format: record.format, coverURL: record.coverURL, automatic: automatic)
        }
        Task { await downloadManager.enqueue(requests) }
    }

    /// Keeps the next few unread chapters downloaded, for works in the library.
    func downloadAhead(_ record: WorkRecord) {
        guard record.inLibrary, record.settings.autoDownload ?? settings.downloads.autoDownload else { return }
        let upcoming = record.upcomingUnread(settings.downloads.downloadAhead)
            .filter { !downloads.isDownloaded(ChapterRef(work: record.key, chapterID: $0.id)) }
        if !upcoming.isEmpty { download(upcoming, of: record, automatic: true) }
    }

    func deleteDownloads(of key: WorkKey) {
        Task { await downloadManager.deleteWork(key) }
    }

    private func downloadsChanged(_ snapshot: DownloadSnapshot) {
        let newlyBlocked = Set(snapshot.blockedHosts).subtracting(downloads.blockedHosts)
        downloads = snapshot
        widgets.update(downloads: snapshot)
        if !newlyBlocked.isEmpty, UIApplication.shared.applicationState != .active {
            Notifications.postVerificationNeeded(hosts: newlyBlocked.sorted())
        }
    }

    // MARK: - Browser checks

    /// The person passed `host`'s bot check in the browser sheet.
    func didVerify(host: String) {
        verifiedCount += 1
        // Screens watching verifiedCount retry; paused downloads for the host resume.
        Task { await downloadManager.unblock(host: host) }
    }

    // MARK: - Update checks

    /// Checks library works for new chapters, queues automatic downloads, and returns what it found.
    @discardableResult
    func checkForUpdates(only keys: Set<WorkKey>? = nil) async -> UpdateReport {
        guard !isCheckingUpdates else { return lastReport ?? UpdateReport() }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }

        var runtimesBySource: [String: SourceRuntime] = [:]
        for source in Set(library.library.map(\.key.sourceID)) {
            runtimesBySource[source] = try? runtime(for: source)
        }
        let snapshot = runtimesBySource
        let (next, report) = await UpdateChecker.check(library, only: keys) { key in
            guard let runtime = snapshot[key.sourceID] else { throw SourceError.unavailable }
            return try await runtime.getChapters(workID: key.workID)
        }
        // Keep anything the user changed while the check ran; take only the chapter lists.
        for record in next.library {
            library.update(record.key) { current in
                current.chapters = record.chapters
                current.newChapterIDs = record.newChapterIDs.filter { !current.readChapterIDs.contains($0) }
                current.lastCheckedAt = record.lastCheckedAt
            }
        }
        library.lastUpdateCheck = next.lastUpdateCheck
        lastReport = report
        scheduleSave()

        for found in report.found {
            guard let record = library[found.key], record.settings.autoDownload ?? settings.downloads.autoDownload else { continue }
            download(found.newChapters, of: record, automatic: true)
        }
        refreshBadge()
        return report
    }

    /// Runs a check when the app opens, unless one ran in the last ten minutes.
    func checkOnOpenIfDue() {
        if let last = library.lastUpdateCheck, Date().timeIntervalSince(last) < 600 { return }
        guard !library.library.isEmpty else { return }
        Task { await checkForUpdates() }
    }

    func refreshBadge() {
        Notifications.setBadge(settings.badgeNewChapters ? library.newChapterCount : 0)
    }

    // MARK: - Settings

    private func settingsChanged(from old: AppSettings) {
        save(settings, as: Keys.settings)
        if settings.downloads != old.downloads {
            let next = settings.downloads
            Task { await downloadManager.update(settings: next) }
        }
        if settings.maxRating != old.maxRating {
            runtimes.values.forEach { $0.close() }
            runtimes.removeAll()
        }
        if settings.updateInterval != old.updateInterval {
            BackgroundWork.scheduleRefresh(interval: settings.updateInterval)
        }
        if settings.badgeNewChapters != old.badgeNewChapters { refreshBadge() }
    }

    // MARK: - Helpers

    func report(_ error: Error) {
        lastError = error.readable
        showingError = true
    }

    /// Saves the library a moment after the last change.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        var state = library
        // Works only browsed (not saved, never read, no glossary or highlights) aren't worth keeping.
        state.records = state.records.filter {
            $0.value.inLibrary || $0.value.lastReadAt != nil || !$0.value.glossary.isEmpty || !($0.value.highlights ?? []).isEmpty
        }
        try? libraryFile?.save(state)
        widgets.update(library: library, badge: settings.badgeNewChapters)
    }

    private func save<T: Encodable>(_ value: T, as key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

/// Lets the download queue ask the app for chapter content.
private final class ResolverBox: ChapterResolver, @unchecked Sendable {
    weak var model: AppModel?

    func content(for ref: ChapterRef) async throws -> ChapterContent {
        guard let model = await MainActor.run(body: { self.model }) else { throw SourceError.unavailable }
        return try await model.contentForDownload(ref)
    }
}
