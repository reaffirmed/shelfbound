import Foundation
import Observation
import RepoKit
import ShelfCore
import SourceKit

struct RepoLink: Identifiable {
    let url: String
    var id: String { url }
}

struct SavedRepo: Codable, Hashable, Identifiable {
    var url: URL
    var name: String
    var maintainer: String?
    var publicKey: String
    var id: URL { url }
}

/// Last place read in a work, kept per device for now (CloudKit sync comes later).
struct ReadingPosition: Codable, Hashable {
    var chapterID: String
    var chapterTitle: String
    var progress: Double
    var updatedAt: Date
}

struct LibraryItem: Codable, Hashable, Identifiable {
    var sourceID: String
    var work: WorkSummary
    var addedAt: Date
    var id: String { sourceID + "/" + work.id }
}

@MainActor
@Observable
final class AppModel {
    nonisolated static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"

    private(set) var repos: [SavedRepo] = []
    private(set) var installed: [InstalledSource] = []
    private(set) var library: [LibraryItem] = []
    var readerStyle = ReaderStyle() { didSet { save(readerStyle, as: Keys.readerStyle) } }
    var maxRating: ContentRating = .mature { didSet { save(maxRating, as: Keys.maxRating) } }

    var lastError: String?
    var showingError = false
    var pendingRepoLink: RepoLink?

    private let store: SourceStore?
    private let client = RepoClient(appVersion: AppModel.appVersion)
    private let network = URLSessionNetwork()
    private var runtimes: [String: SourceRuntime] = [:]
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let repos = "repos"
        static let library = "library"
        static let readerStyle = "readerStyle"
        static let maxRating = "maxRating"
        static func position(_ id: String) -> String { "position." + id }
    }

    init() {
        store = try? SourceStore()
        repos = load([SavedRepo].self, Keys.repos) ?? []
        library = load([LibraryItem].self, Keys.library) ?? []
        readerStyle = load(ReaderStyle.self, Keys.readerStyle) ?? ReaderStyle()
        maxRating = load(ContentRating.self, Keys.maxRating) ?? .mature
        installed = store?.installed() ?? []
    }

    // MARK: Repos

    func handle(url: URL) {
        // shelfbound://add-repo?url=https://example.github.io/repo
        guard url.scheme == "shelfbound", url.host == "add-repo",
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value
        else { return }
        pendingRepoLink = RepoLink(url: target)
    }

    func fetchIndex(for input: String) async throws -> (URL, RepoIndex) {
        guard let url = RepoClient.indexURL(for: input) else {
            throw URLError(.badURL)
        }
        return (url, try await client.fetchIndex(url))
    }

    func addRepo(url: URL, index: RepoIndex) {
        repos.removeAll { $0.url == url }
        repos.append(SavedRepo(url: url, name: index.name, maintainer: index.maintainer, publicKey: index.publicKey))
        save(repos, as: Keys.repos)
    }

    func removeRepo(_ repo: SavedRepo) {
        repos.removeAll { $0.url == repo.url }
        client.pins.removePin(for: repo.url)
        save(repos, as: Keys.repos)
    }

    // MARK: Sources

    func install(_ entry: RepoEntry, index: RepoIndex, repo: URL) async {
        do {
            let (package, data) = try await client.downloadPackage(entry, index: index, indexURL: repo)
            try store?.install(package, data: data, from: repo)
            runtimes[entry.id]?.close()
            runtimes[entry.id] = nil
            installed = store?.installed() ?? []
        } catch {
            report(error)
        }
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

    func runtime(for sourceID: String) throws -> SourceRuntime {
        if let runtime = runtimes[sourceID] { return runtime }
        guard let store else { throw SourceError.unavailable }
        let runtime = try SourceRuntime(package: try store.package(for: sourceID), network: network)
        runtimes[sourceID] = runtime
        return runtime
    }

    var visibleSources: [InstalledSource] {
        installed.filter { $0.manifest.contentRating <= maxRating }
    }

    // MARK: Library and progress

    func isInLibrary(sourceID: String, workID: String) -> Bool {
        library.contains { $0.sourceID == sourceID && $0.work.id == workID }
    }

    func toggleLibrary(sourceID: String, work: WorkSummary) {
        if isInLibrary(sourceID: sourceID, workID: work.id) {
            library.removeAll { $0.sourceID == sourceID && $0.work.id == work.id }
        } else {
            library.insert(LibraryItem(sourceID: sourceID, work: work, addedAt: Date()), at: 0)
        }
        save(library, as: Keys.library)
    }

    func position(sourceID: String, workID: String) -> ReadingPosition? {
        load(ReadingPosition.self, Keys.position(sourceID + "/" + workID))
    }

    func savePosition(_ position: ReadingPosition, sourceID: String, workID: String) {
        save(position, as: Keys.position(sourceID + "/" + workID))
    }

    // MARK: Helpers

    func report(_ error: Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showingError = true
    }

    private func save<T: Encodable>(_ value: T, as key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
