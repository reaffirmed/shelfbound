import Foundation

/// What a source serves: chapters of text (fanfic, novels) or chapters of images (manga, manhwa).
public enum ContentKind: String, Codable, Sendable, CaseIterable {
    case text
    case images
}

public enum ContentRating: String, Codable, Sendable, CaseIterable, Comparable {
    case safe
    case mature
    case explicit

    private var rank: Int {
        switch self {
        case .safe: 0
        case .mature: 1
        case .explicit: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// `manifest.json` of a source package.
public struct SourceManifest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var kind: ContentKind
    public var languages: [String]
    public var contentRating: ContentRating
    /// Hosts the source may contact. A leading "*." allows subdomains.
    public var domains: [String]
    public var minAppVersion: String?

    public init(
        id: String, name: String, version: String, kind: ContentKind,
        languages: [String], contentRating: ContentRating, domains: [String],
        minAppVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.kind = kind
        self.languages = languages
        self.contentRating = contentRating
        self.domains = domains
        self.minAppVersion = minAppVersion
    }
}

/// The single-file package a repo serves: manifest plus script.
public struct SourcePackage: Codable, Sendable, Hashable {
    public var format: Int
    public var manifest: SourceManifest
    public var script: String
    /// Optional PNG icon, base64.
    public var icon: String?

    public init(format: Int = 1, manifest: SourceManifest, script: String, icon: String? = nil) {
        self.format = format
        self.manifest = manifest
        self.script = script
        self.icon = icon
    }
}

/// A search or listing result.
public struct WorkSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var authors: [String]
    public var coverURL: URL?
    public var blurb: String?

    public init(id: String, title: String, authors: [String] = [], coverURL: URL? = nil, blurb: String? = nil) {
        self.id = id
        self.title = title
        self.authors = authors
        self.coverURL = coverURL
        self.blurb = blurb
    }
}

/// Full details for one work. Text sources fill the fanfic-style metadata fields.
public struct Work: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var authors: [String]
    public var coverURL: URL?
    public var summaryHTML: String?
    public var url: URL?
    public var rating: String?
    public var warnings: [String]?
    public var fandoms: [String]?
    public var relationships: [String]?
    public var tags: [String]?
    public var wordCount: Int?
    public var status: String?
    /// Official whole-work downloads the site offers, keyed by format ("epub", "html").
    public var downloads: [String: URL]?

    public init(id: String, title: String, authors: [String] = []) {
        self.id = id
        self.title = title
        self.authors = authors
    }
}

public struct Chapter: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var number: Double?
    public var publishedAt: Date?

    public init(id: String, title: String, number: Double? = nil, publishedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.number = number
        self.publishedAt = publishedAt
    }
}

public enum ChapterContent: Sendable, Hashable {
    case text(html: String, notesBefore: String?, notesAfter: String?)
    case images([URL])
}

extension ChapterContent: Codable {
    private enum CodingKeys: String, CodingKey { case type, html, notesBefore, notesAfter, pages }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text(
                html: try c.decode(String.self, forKey: .html),
                notesBefore: try c.decodeIfPresent(String.self, forKey: .notesBefore),
                notesAfter: try c.decodeIfPresent(String.self, forKey: .notesAfter)
            )
        case "images":
            self = .images(try c.decode([URL].self, forKey: .pages))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown chapter content type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(html, before, after):
            try c.encode("text", forKey: .type)
            try c.encode(html, forKey: .html)
            try c.encodeIfPresent(before, forKey: .notesBefore)
            try c.encodeIfPresent(after, forKey: .notesAfter)
        case let .images(pages):
            try c.encode("images", forKey: .type)
            try c.encode(pages, forKey: .pages)
        }
    }
}

public struct SearchPage: Codable, Sendable, Hashable {
    public var results: [WorkSummary]
    public var hasMore: Bool

    public init(results: [WorkSummary], hasMore: Bool) {
        self.results = results
        self.hasMore = hasMore
    }
}
