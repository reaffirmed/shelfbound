import Foundation
import ShelfCore

public struct InstalledSource: Codable, Sendable, Hashable, Identifiable {
    public var id: String { manifest.id }
    public var manifest: SourceManifest
    public var repoURL: URL
    public var installedAt: Date
}

/// Keeps installed source packages on disk under Application Support.
public final class SourceStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil) throws {
        let base = try directory ?? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Sources", isDirectory: true)
        self.directory = base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private var recordsURL: URL { directory.appendingPathComponent("installed.json") }
    private func packageURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).srcpkg.json") }

    public func installed() -> [InstalledSource] {
        lock.lock(); defer { lock.unlock() }
        return readRecords()
    }

    public func install(_ package: SourcePackage, data: Data, from repo: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try data.write(to: packageURL(package.manifest.id), options: .atomic)
        var records = readRecords().filter { $0.id != package.manifest.id }
        records.append(InstalledSource(manifest: package.manifest, repoURL: repo, installedAt: Date()))
        try encoder.encode(records).write(to: recordsURL, options: .atomic)
    }

    public func remove(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: packageURL(id))
        let records = readRecords().filter { $0.id != id }
        try encoder.encode(records).write(to: recordsURL, options: .atomic)
    }

    public func package(for id: String) throws -> SourcePackage {
        try decoder.decode(SourcePackage.self, from: Data(contentsOf: packageURL(id)))
    }

    /// Entries in `index` newer than what is installed from that repo.
    public func updates(in index: RepoIndex, repo: URL) -> [RepoEntry] {
        let current = Dictionary(uniqueKeysWithValues: installed().filter { $0.repoURL == repo }.map { ($0.id, $0.manifest.version) })
        return index.sources.filter { entry in
            guard let version = current[entry.id] else { return false }
            return SemanticVersion(version) < SemanticVersion(entry.version)
        }
    }

    private func readRecords() -> [InstalledSource] {
        guard let data = try? Data(contentsOf: recordsURL) else { return [] }
        return (try? decoder.decode([InstalledSource].self, from: data)) ?? []
    }
}
