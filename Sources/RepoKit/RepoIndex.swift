import Foundation
import ShelfCore

/// `index.json` at the root of a community repo.
public struct RepoIndex: Codable, Sendable, Hashable {
    public var format: Int
    public var name: String
    public var maintainer: String?
    public var homepage: URL?
    /// `ed25519:<base64 raw 32-byte key>`
    public var publicKey: String
    public var sources: [RepoEntry]
}

public struct RepoEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var kind: ContentKind
    public var contentRating: ContentRating
    public var languages: [String]?
    public var minAppVersion: String?
    /// Path of the `.srcpkg.json` file, relative to the index URL.
    public var package: String
    /// Hex SHA-256 of the package file.
    public var sha256: String
    /// Base64 Ed25519 signature of the raw SHA-256 digest.
    public var signature: String
    public var icon: String?
    /// Copied from the manifest so the repo page can filter manga from manhwa.
    public var format: WorkFormat? = nil
}

/// Dotted numeric version compare ("1.10.0" > "1.9.2").
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let description: String

    public init(_ string: String) {
        description = string
        parts = string.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for i in 0..<count {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}
