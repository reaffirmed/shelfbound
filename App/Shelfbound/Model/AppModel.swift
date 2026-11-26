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
    nonisolated static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5.11"

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
    /// The tab or sidebar item showing, so menu commands and Siri can switch it.
    var selectedTab: AppTab = .library
    /// A work to open straight into the reader at its place, from Siri or Shortcuts.
    var pendingContinue: WorkKey?
    /// A tapped "downloads paused" notification: show the Downloads screen.
    var pendingShowDownloads = false
    /// Sites the person signed in to, by source ID. The cookies are in the Keychain.
    private(set) var accounts: [String: SavedAccount] = [:]

    /// Signed-in sources' cookies. Each source's go only with its own requests.
    @ObservationIgnored let accountJars = AccountCookieJars()
    @ObservationIgnored let network: URLSessionNetwork
    @ObservationIgnored let networkMonitor: NetworkMonitor
    @ObservationIgnored let transfer: BackgroundTransfer
    @ObservationIgnored let downloadManager: DownloadManager
    @ObservationIgnored private let store: SourceStore?
    @ObservationIgnored private let client = RepoClient(appVersion: AppModel.appVersion)
    @ObservationIgnored private var runtimes: [String: SourceRuntime] = [:]
    /// First pages of browse lists, so switching tabs doesn't refetch them (AO3 asks for
    /// three seconds between requests). Keyed by "sourceID/listingID".
    @ObservationIgnored private var listingCache: [String: (at: Date, page: SearchPage)] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let libraryFile: LibraryFile?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let resolverBox: ResolverBox
    @ObservationIgnored private let widgets = WidgetBridge()
    /// EPUB, PDF and CBZ files the person imported.
    @ObservationIgnored let localFiles: LocalFiles?
    /// Files being imported right now, for the progress banner.
    private(set) var importingFiles: [String] = []

    private enum Keys {
        static let repos = "repos"
        static let settings = "settings"
        static let accounts = "accounts"
        static let signedOutAccounts = "accounts.signedOut"
    }

    private init() {
        store = try? SourceStore()
        libraryFile = try? LibraryFile.default()
        localFiles = try? LocalFiles.default()
        let layout = (try? DownloadLayout.default())
            ?? DownloadLayout(root: FileManager.default.temporaryDirectory.appendingPathComponent("Downloads"))
        let transfer = BackgroundTransfer(staging: layout.staging)
        let monitor = NetworkMonitor()
        let box = ResolverBox()
        let loadedSettings = Self.load(AppSettings.self, Keys.settings, from: .standard) ?? AppSettings()
        network = URLSessionNetwork(
            clearances: .shared, accounts: accountJars,
            browserFetch: { try await BrowserFetcher.hostResponse(for: $0) })
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
        relinkLocalCovers()
        accounts = Self.load([String: SavedAccount].self, Keys.accounts, from: .standard) ?? [:]
        // Each signed-in source gets its own cookie jar, filled from the Keychain. Apps
        // before 0.5.6 put sign-in cookies in the shared store, where every source, reader
        // mode and image request could send them, so take them out of there.
        for sourceID in accounts.keys {
            let saved = AccountKeychain.load(for: sourceID)
            accountJars.set(saved, for: sourceID)
            Self.removeSharedCookies(named: Set(saved.map(\.name)), like: saved)
        }
        accountJars.onChange { sourceID, cookies in
            // The site refreshed its session cookie: keep the saved copy current.
            Task { @MainActor in
                guard AppModel.shared.accounts[sourceID] != nil, !cookies.isEmpty else { return }
                AccountKeychain.save(cookies, for: sourceID)
            }
        }
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
        // A file opened with "Open in Shelfbound" or shared from Files.
        if url.isFileURL {
            Task { await importFiles([url]) }
            return
        }
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
            forgetListings(of: entry.id)
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
        forgetListings(of: id)
        try? store?.remove(id)
        installed = store?.installed() ?? []
    }

    func isInstalled(_ entry: RepoEntry) -> InstalledSource? {
        installed.first { $0.id == entry.id }
    }

    func manifest(for sourceID: String) -> SourceManifest? {
        installed.first { $0.id == sourceID }?.manifest
    }

    func sourceName(_ sourceID: String) -> String {
        if sourceID == LocalBooks.sourceID { return LocalBooks.sourceName }
        return manifest(for: sourceID)?.name ?? sourceID
    }

    func runtime(for sourceID: String) throws -> SourceRuntime {
        if let runtime = runtimes[sourceID] { return runtime }
        guard let store else { throw SourceError.unavailable }
        let runtime = try SourceRuntime(
            package: try store.package(for: sourceID), network: network,
            settings: runtimeSettings(for: sourceID))
        runtimes[sourceID] = runtime
        return runtime
    }

    private func runtimeSettings(for sourceID: String) -> [String: String] {
        var values = ["maxRating": settings.maxRating.rawValue]
        if let account = accounts[sourceID] { values["account"] = account.username }
        return values
    }

    /// Starts the source again, so it sees changed settings such as who is signed in.
    private func restartRuntime(_ sourceID: String) {
        runtimes[sourceID]?.close()
        runtimes[sourceID] = nil
        forgetListings(of: sourceID)
    }

    // MARK: - Accounts

    /// Installed sources the person can sign in to.
    var accountSources: [InstalledSource] {
        visibleSources.filter { $0.manifest.has(.account) && $0.manifest.account != nil }
    }

    func isSignedIn(_ sourceID: String) -> Bool { accounts[sourceID] != nil }

    var signedInSourceIDs: [String] { Array(accounts.keys) }

    /// Called with the cookies from the sign-in web view. Asks the source who is signed in,
    /// and keeps the cookies in the Keychain if somebody is. Returns the account, or nil
    /// when the site doesn't show anyone signed in yet.
    func finishSignIn(sourceID: String, cookies: [HTTPCookie]) async throws -> SourceAccount? {
        guard let manifest = manifest(for: sourceID) else { throw SourceError.unavailable }
        // The site's own cookies only, minus a Cloudflare pass, which the shared store keeps.
        let siteCookies = AccountKeychain.cookies(cookies, matching: manifest.domains).filter { $0.name != "cf_clearance" }
        let hadAccount = accounts[sourceID] != nil
        accountJars.set(siteCookies, for: sourceID)
        restartRuntime(sourceID)
        guard let account = try await runtime(for: sourceID).getAccount() else {
            // Nobody signed in: go back to what was there before.
            accountJars.set(hadAccount ? AccountKeychain.load(for: sourceID) : [], for: sourceID)
            return nil
        }
        AccountKeychain.save(accountJars.cookies(for: sourceID), for: sourceID)
        // Signing back in to the same account brings back its sync choices.
        var signedOut = Self.load([String: SavedAccount].self, Keys.signedOutAccounts, from: defaults) ?? [:]
        let previous = accounts[sourceID] ?? signedOut[sourceID].flatMap { $0.username == account.username ? $0 : nil }
        accounts[sourceID] = SavedAccount(
            username: account.username, signedInAt: Date(), syncedLists: previous?.syncedLists ?? [],
            skippedWorks: previous?.skippedWorks)
        signedOut[sourceID] = nil
        save(signedOut, as: Keys.signedOutAccounts)
        save(accounts, as: Keys.accounts)
        restartRuntime(sourceID)
        return account
    }

    /// Checks the saved session still works. Signs out locally if the site says nobody is signed in.
    @discardableResult
    func checkSignIn(sourceID: String) async throws -> Bool {
        guard accounts[sourceID] != nil else { return false }
        if try await runtime(for: sourceID).getAccount() != nil { return true }
        forgetAccount(sourceID)
        return false
    }

    /// Forgets the session here. Nothing on the site changes.
    func signOut(sourceID: String) {
        let saved = AccountKeychain.load(for: sourceID) + accountJars.cookies(for: sourceID)
        Self.removeSharedCookies(named: Set(saved.map(\.name)), like: saved)
        forgetAccount(sourceID)
    }

    /// Deletes cookies from the shared store that have the same name and site as a
    /// sign-in cookie, left there by apps before 0.5.6.
    private static func removeSharedCookies(named names: Set<String>, like cookies: [HTTPCookie]) {
        let storage = HTTPCookieStorage.shared
        let domains = Set(cookies.map(\.domain))
        for cookie in storage.cookies ?? [] where names.contains(cookie.name) && domains.contains(cookie.domain) {
            storage.deleteCookie(cookie)
        }
    }

    private func forgetAccount(_ sourceID: String) {
        accountJars.set([], for: sourceID)
        AccountKeychain.delete(for: sourceID)
        // Keep which lists were synced, so signing in again doesn't mean setting it all up again.
        if let account = accounts[sourceID] {
            var signedOut = Self.load([String: SavedAccount].self, Keys.signedOutAccounts, from: defaults) ?? [:]
            signedOut[sourceID] = account
            save(signedOut, as: Keys.signedOutAccounts)
        }
        accounts[sourceID] = nil
        save(accounts, as: Keys.accounts)
        restartRuntime(sourceID)
    }

    /// Remembers a work the person removed, so "Keep in sync" leaves it out. Adding it back
    /// by hand clears that.
    private func setSkippedBySync(_ key: WorkKey, _ skipped: Bool) {
        guard var account = accounts[key.sourceID] else { return }
        var works = account.skippedWorks ?? []
        let had = works.contains(key.workID)
        guard had != skipped else { return }
        if skipped { works.append(key.workID) } else { works.removeAll { $0 == key.workID } }
        account.skippedWorks = works
        accounts[key.sourceID] = account
        save(accounts, as: Keys.accounts)
    }

    func setSynced(_ listID: String, _ on: Bool, for sourceID: String) {
        guard var account = accounts[sourceID] else { return }
        account.syncedLists.removeAll { $0 == listID }
        if on { account.syncedLists.append(listID) }
        accounts[sourceID] = account
        save(accounts, as: Keys.accounts)
    }

    func accountLists(sourceID: String) async throws -> [AccountList] {
        try await runtime(for: sourceID).getAccountLists()
    }

    func accountList(sourceID: String, listID: String, page: Int) async throws -> SearchPage {
        try await runtime(for: sourceID).getAccountList(id: listID, page: page)
    }

    /// Marks for later, subscribes or leaves kudos on the site, from a tap on the work's page.
    func setWorkState(_ key: WorkKey, _ action: WorkAction, _ value: Bool) async throws {
        let state = try await runtime(for: key.sourceID).setWorkState(workID: key.workID, action: action, value: value)
        library.update(key) { $0.work?.account = state }
        scheduleSave()
    }

    /// Adds a work from a list to the library without fetching it first. Its chapters come
    /// with the next update check. Returns false when it was already there.
    @discardableResult
    func addToLibrary(_ key: WorkKey, summary: WorkSummary, addedAt: Date = Date()) -> Bool {
        if library[key]?.inLibrary == true { return false }
        ensureRecord(key, summary: summary)
        library.setInLibrary(key, true)
        library.update(key) { $0.addedAt = $0.addedAt ?? addedAt }
        // An Import brings back a work the person had removed; sync can keep it from then on.
        setSkippedBySync(key, false)
        scheduleSave()
        return true
    }

    /// Adds new works from the lists the person chose to keep in sync. Only reads the first
    /// pages, where new bookmarks appear, and never removes anything.
    @discardableResult
    func syncAccountLists(pages: Int = 2) async -> [WorkKey] {
        var added: [WorkKey] = []
        for (sourceID, account) in accounts where !account.syncedLists.isEmpty && manifest(for: sourceID) != nil {
            for listID in account.syncedLists {
                for page in 1...max(1, pages) {
                    guard let result = try? await accountList(sourceID: sourceID, listID: listID, page: page) else { break }
                    var fresh = 0
                    let skipped = Set(account.skippedWorks ?? [])
                    for work in result.results where !skipped.contains(work.id) {
                        let key = WorkKey(sourceID: sourceID, workID: work.id)
                        if addToLibrary(key, summary: work) { added.append(key); fresh += 1 }
                    }
                    // A page with nothing new means the rest is already in the library.
                    if fresh == 0 || !result.hasMore { break }
                }
            }
        }
        if !added.isEmpty { saveNow() }
        return added
    }

    /// One page of a source's browse list. First pages are kept for ten minutes unless
    /// `refresh` is set.
    func listing(sourceID: String, listingID: String, page: Int = 1, refresh: Bool = false) async throws -> SearchPage {
        let key = sourceID + "/" + listingID
        if page == 1, !refresh, let cached = listingCache[key], Date().timeIntervalSince(cached.at) < 600 {
            return cached.page
        }
        let result = try await runtime(for: sourceID).getListing(id: listingID, page: page)
        if page == 1 { listingCache[key] = (Date(), result) }
        return result
    }

    /// A first page already fetched, for showing a list without a spinner.
    func cachedListing(sourceID: String, listingID: String) -> SearchPage? {
        listingCache[sourceID + "/" + listingID]?.page
    }

    private func forgetListings(of sourceID: String) {
        listingCache = listingCache.filter { !$0.key.hasPrefix(sourceID + "/") }
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
        if LocalBooks.isLocal(key) {
            try refreshLocal(key)
            return
        }
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
        setSkippedBySync(key, record.inLibrary)
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
        if LocalBooks.isLocal(ref.work) {
            guard let localFiles else { throw LocalFileError.missing }
            let book = try localFiles.load(ref.work.workID)
            return try book.content(of: ref.chapterID, in: localFiles.folder(book.id))
        }
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

    // MARK: - Imported files

    /// Imports EPUB, PDF and CBZ files into the library. Opens the work when it's just one.
    func importFiles(_ urls: [URL]) async {
        guard let localFiles else { return }
        var imported: [WorkKey] = []
        var failures: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            importingFiles.append(name)
            defer { importingFiles.removeAll { $0 == name } }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let book = try await Task.detached(priority: .userInitiated) { try localFiles.importFile(at: url) }.value
                addLocal(book)
                imported.append(book.key)
            } catch {
                failures.append(error.readable)
            }
            // Files shared into the app arrive in its Inbox; they're copied now, so drop the original.
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }
        if imported.count == 1 { pendingOpen = imported[0] }
        if !failures.isEmpty {
            lastError = failures.joined(separator: "\n")
            showingError = true
        }
    }

    private func addLocal(_ book: LocalBook) {
        guard let localFiles else { return }
        let folder = localFiles.folder(book.id)
        library.upsert(key: book.key, summary: book.summary(in: folder), work: book.work(in: folder), chapters: book.chapters, format: book.format)
        library.setInLibrary(book.key, true)
        saveNow()
    }

    private func refreshLocal(_ key: WorkKey) throws {
        guard let localFiles else { throw LocalFileError.missing }
        let book = try localFiles.load(key.workID)
        let folder = localFiles.folder(book.id)
        let existing = library[key]
        library.upsert(key: key, summary: book.summary(in: folder), work: book.work(in: folder), chapters: book.chapters,
                       format: existing?.format ?? book.format)
        scheduleSave()
    }

    /// iOS moves the app's folder when it updates the app, so covers saved with the old path are re-pointed.
    private func relinkLocalCovers() {
        guard let localFiles else { return }
        for record in library.records.values where LocalBooks.isLocal(record.key) {
            guard let book = try? localFiles.load(record.key.workID) else { continue }
            let folder = localFiles.folder(book.id)
            library.update(record.key) {
                $0.summary.coverURL = book.summary(in: folder).coverURL
                $0.work?.coverURL = $0.summary.coverURL
            }
        }
    }

    /// Removes an imported file from the device and the library.
    func deleteLocal(_ key: WorkKey) {
        guard LocalBooks.isLocal(key) else { return }
        localFiles?.delete(key.workID)
        library.records[key.id] = nil
        saveNow()
        refreshBadge()
    }

    // MARK: - Downloads

    func download(_ chapters: [Chapter], of record: WorkRecord, automatic: Bool = false) {
        // Imported files are already on the device.
        guard !LocalBooks.isLocal(record.key) else { return }
        let requests = chapters.map {
            DownloadRequest(
                ref: ChapterRef(work: record.key, chapterID: $0.id), workTitle: record.title, chapterTitle: $0.title,
                format: record.format, coverURL: record.coverURL, automatic: automatic)
        }
        Task { await downloadManager.enqueue(requests) }
    }

    /// "Mark as Read" on a new-chapter alert.
    func markNewChaptersRead(_ chapterIDs: [String], in key: WorkKey) {
        for id in chapterIDs { library.markRead(id, in: key) }
        saveNow()
        refreshBadge()
    }

    /// "Download" on a new-chapter alert.
    func downloadChapters(_ chapterIDs: [String], in key: WorkKey) {
        guard let record = library[key] else { return }
        let wanted = Set(chapterIDs)
        let chapters = record.chapters.filter { wanted.contains($0.id) }
        if !chapters.isEmpty { download(chapters, of: record) }
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
        if keys == nil { await syncAccountLists() }

        var runtimesBySource: [String: SourceRuntime] = [:]
        for source in Set(library.library.map(\.key.sourceID)) {
            runtimesBySource[source] = try? runtime(for: source)
        }
        let snapshot = runtimesBySource
        // Imported files never change, so their chapter list is the one already saved.
        let localChapters = Dictionary(uniqueKeysWithValues: library.library
            .filter { LocalBooks.isLocal($0.key) }.map { ($0.key, $0.chapters) })
        let (next, report) = await UpdateChecker.check(library, only: keys) { key in
            if let chapters = localChapters[key] { return chapters }
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

    // MARK: - Backup

    func makeBackup() throws -> Data {
        var state = library
        state.records = state.records.filter {
            $0.value.inLibrary || $0.value.lastReadAt != nil || !$0.value.glossary.isEmpty || !($0.value.highlights ?? []).isEmpty
        }
        let backup = LibraryBackup(library: state, settings: settings, repos: repos, sources: installed.map(\.id))
        return try LibraryBackup.encoder().encode(backup)
    }

    /// Merges a backup into this install: its works replace the same works here (others
    /// stay), its repos are added, and its sources are installed again from those repos.
    func restore(_ backup: LibraryBackup) async -> RestoreReport {
        var report = RestoreReport()
        for (id, record) in backup.library.records {
            library.records[id] = record
            report.works += 1
        }
        if library.lastUpdateCheck == nil { library.lastUpdateCheck = backup.library.lastUpdateCheck }
        if let restored = backup.settings { settings = restored }
        saveNow()

        for repo in backup.repos where !repos.contains(where: { $0.url == repo.url }) {
            guard let index = try? await client.fetchIndex(repo.url) else { continue }
            addRepo(url: repo.url, index: index)
            report.repos += 1
        }
        let wanted = backup.sources.filter { id in !installed.contains { $0.id == id } }
        var missing = Set(wanted)
        for repo in repos where !missing.isEmpty {
            guard let index = try? await client.fetchIndex(repo.url) else { continue }
            for entry in index.sources where missing.contains(entry.id) {
                await install(entry, index: index, repo: repo.url)
                if installed.contains(where: { $0.id == entry.id }) {
                    missing.remove(entry.id)
                    report.sourcesInstalled += 1
                }
            }
        }
        report.sourcesMissing = missing.sorted()
        refreshBadge()
        return report
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
