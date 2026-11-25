import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShelfCore

/// Remembers the first key seen for each repo URL (trust on first use).
public protocol KeyPinStore: Sendable {
    func pinnedKey(for repo: URL) -> String?
    func pin(_ key: String, for repo: URL)
    func removePin(for repo: URL)
}

public final class UserDefaultsKeyPinStore: KeyPinStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix = "repo.pin."

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func pinnedKey(for repo: URL) -> String? { defaults.string(forKey: prefix + repo.absoluteString) }
    public func pin(_ key: String, for repo: URL) { defaults.set(key, forKey: prefix + repo.absoluteString) }
    public func removePin(for repo: URL) { defaults.removeObject(forKey: prefix + repo.absoluteString) }
}

public protocol RepoTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

public struct URLSessionTransport: RepoTransport {
    public init() {}
    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RepoError.http(status: http.statusCode, url: url)
        }
        return data
    }
}

public struct RepoClient: Sendable {
    public static let supportedFormat = 1

    public let transport: RepoTransport
    public let pins: KeyPinStore
    public let appVersion: String
    /// Public keys (the `ed25519:...` string) of repos the app refuses, updatable remotely later.
    public var blockedKeys: Set<String>

    public init(
        transport: RepoTransport = URLSessionTransport(),
        pins: KeyPinStore = UserDefaultsKeyPinStore(),
        appVersion: String,
        blockedKeys: Set<String> = []
    ) {
        self.transport = transport
        self.pins = pins
        self.appVersion = appVersion
        self.blockedKeys = blockedKeys
    }

    /// Normalises what a user pastes: a repo folder or a direct link to index.json.
    public static func indexURL(for input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        if url.pathExtension.lowercased() != "json" {
            url.appendPathComponent("index.json")
        }
        return url
    }

    /// Downloads the index and checks it against the pinned key. Pins on first use.
    public func fetchIndex(_ url: URL) async throws -> RepoIndex {
        let index = try JSONDecoder().decode(RepoIndex.self, from: try await transport.data(from: url))
        guard index.format <= Self.supportedFormat else { throw RepoError.unsupportedFormat(index.format) }
        _ = try RepoVerifier.publicKey(from: index.publicKey)
        guard !blockedKeys.contains(index.publicKey) else { throw RepoError.blocked(repo: url) }
        if let pinned = pins.pinnedKey(for: url) {
            guard pinned == index.publicKey else { throw RepoError.keyChanged(repo: url) }
        } else {
            pins.pin(index.publicKey, for: url)
        }
        return index
    }

    /// Downloads and verifies one source package from a repo.
    public func downloadPackage(_ entry: RepoEntry, index: RepoIndex, indexURL: URL) async throws -> (SourcePackage, Data) {
        if let required = entry.minAppVersion, SemanticVersion(appVersion) < SemanticVersion(required) {
            throw RepoError.appTooOld(required: required)
        }
        guard let url = URL(string: entry.package, relativeTo: indexURL)?.absoluteURL else {
            throw RepoError.manifestMismatch(sourceID: entry.id)
        }
        let data = try await transport.data(from: url)
        try RepoVerifier.verify(package: data, entry: entry, publicKey: try RepoVerifier.publicKey(from: index.publicKey))
        let package = try JSONDecoder().decode(SourcePackage.self, from: data)
        guard package.manifest.id == entry.id, package.manifest.version == entry.version else {
            throw RepoError.manifestMismatch(sourceID: entry.id)
        }
        return (package, data)
    }
}
