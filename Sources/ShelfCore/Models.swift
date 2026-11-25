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
    /// What the source's works are, which picks the default reader (paged right-to-left
    /// for manga, vertical for manhwa). Defaults to `fic` for text and `manga` for images.
    public var format: WorkFormat?
    /// Slower spacing than the app's default of one request a second, for sites that ask for it.
    public var rateLimit: RateLimit?
    /// Optional features: "filters" (`getFilters`), "links" (`resolveLink`, reads chapter
    /// links other sources hand over), "discovery" (chapters are links to other sites),
    /// "listings" (`getListings` and `getListing`, browsable lists like "Trending").
    public var capabilities: [String]?

    public init(
        id: String, name: String, version: String, kind: ContentKind,
        languages: [String], contentRating: ContentRating, domains: [String],
        minAppVersion: String? = nil, format: WorkFormat? = nil, rateLimit: RateLimit? = nil,
        capabilities: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.kind = kind
        self.languages = languages
        self.contentRating = contentRating
        self.domains = domains
        self.minAppVersion = minAppVersion
        self.format = format
        self.rateLimit = rateLimit
        self.capabilities = capabilities
    }

    public var defaultFormat: WorkFormat { format ?? (kind == .text ? .fic : .manga) }

    public func has(_ capability: SourceCapability) -> Bool {
        capabilities?.contains(capability.rawValue) ?? false
    }
}

public enum SourceCapability: String, Sendable {
    case filters, links, discovery, listings
}

public struct RateLimit: Codable, Sendable, Hashable {
    /// Minimum gap between two requests from this source, in milliseconds.
    public var minIntervalMs: Int?

    public init(minIntervalMs: Int? = nil) { self.minIntervalMs = minIntervalMs }
}

/// What a work is. Text formats use the text reader; image formats pick a reading mode.
public enum WorkFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case fic, novel, manga, manhwa, manhua, comic
    public var id: String { rawValue }

    public var isText: Bool { self == .fic || self == .novel }

    public var defaultReadingMode: ReadingMode {
        switch self {
        case .fic, .novel: .text
        case .manga: .pagedRightToLeft
        case .manhwa, .manhua: .vertical
        case .comic: .pagedLeftToRight
        }
    }

    public var label: String {
        switch self {
        case .fic: "Fic"
        case .novel: "Novel"
        case .manga: "Manga"
        case .manhwa: "Manhwa"
        case .manhua: "Manhua"
        case .comic: "Comic"
        }
    }

    /// The library's filter tabs. Manhua and comics sit with manhwa and manga.
    public var shelf: Shelf {
        switch self {
        case .fic, .novel: .fics
        case .manga, .comic: .manga
        case .manhwa, .manhua: .manhwa
        }
    }

    public enum Shelf: String, Codable, Sendable, CaseIterable, Identifiable {
        case fics, manga, manhwa
        public var id: String { rawValue }
    }
}

public enum ReadingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case text, pagedRightToLeft, pagedLeftToRight, vertical
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .text: "Text"
        case .pagedRightToLeft: "Right to left"
        case .pagedLeftToRight: "Left to right"
        case .vertical: "Vertical"
        }
    }

    public var isPaged: Bool { self == .pagedRightToLeft || self == .pagedLeftToRight }
}

/// Identifies a work across the app: source plus the source's own ID.
public struct WorkKey: Codable, Sendable, Hashable, Identifiable, CustomStringConvertible {
    public var sourceID: String
    public var workID: String

    public init(sourceID: String, workID: String) {
        self.sourceID = sourceID
        self.workID = workID
    }

    public var id: String { sourceID + "/" + workID }
    public var description: String { id }
}

public struct ChapterRef: Codable, Sendable, Hashable, Identifiable, CustomStringConvertible {
    public var work: WorkKey
    public var chapterID: String

    public init(work: WorkKey, chapterID: String) {
        self.work = work
        self.chapterID = chapterID
    }

    public var id: String { work.id + "#" + chapterID }
    public var description: String { id }
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
    // Optional card details, shown when a source fills them (AO3-style search results).
    public var format: WorkFormat?
    public var fandoms: [String]?
    public var rating: String?
    public var tags: [String]?
    public var wordCount: Int?
    /// "14/20", or "9/?" for a work in progress.
    public var chapterCount: String?
    public var kudos: Int?
    public var updatedAt: Date?

    public init(
        id: String, title: String, authors: [String] = [], coverURL: URL? = nil, blurb: String? = nil,
        format: WorkFormat? = nil, fandoms: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.coverURL = coverURL
        self.blurb = blurb
        self.format = format
        self.fandoms = fandoms
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
    public var format: WorkFormat?
    public var categories: [String]?
    public var characters: [String]?
    public var language: String?
    /// "14/20", or "9/?" for a work in progress.
    public var chapterCount: String?
    public var kudos: Int?
    public var bookmarks: Int?
    public var hits: Int?
    public var publishedAt: Date?
    public var updatedAt: Date?
    public var series: [SeriesPart]?
    // Web novels
    public var originalLanguage: String?
    public var translators: [String]?
    public var releaseGroup: String?

    public init(id: String, title: String, authors: [String] = []) {
        self.id = id
        self.title = title
        self.authors = authors
    }

    /// The summary card for this work, used when it is saved to the library.
    public var summary: WorkSummary {
        var s = WorkSummary(id: id, title: title, authors: authors, coverURL: coverURL, format: format, fandoms: fandoms)
        s.rating = rating
        s.tags = tags
        s.wordCount = wordCount
        s.chapterCount = chapterCount
        s.kudos = kudos
        s.updatedAt = updatedAt
        return s
    }
}

/// "Part 2 of The Lantern Cycle".
public struct SeriesPart: Codable, Sendable, Hashable {
    public var title: String
    public var part: Int?
    /// The series' ID in the source, if it can list it.
    public var id: String?
    public var url: URL?

    public init(title: String, part: Int? = nil, id: String? = nil, url: URL? = nil) {
        self.title = title
        self.part = part
        self.id = id
        self.url = url
    }
}

public struct Chapter: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var number: Double?
    public var publishedAt: Date?
    /// For discovery sources: where the chapter text lives (a translator's own site).
    public var link: URL?
    /// Translation or scanlation group, so the same chapter from two groups can sit side by side.
    public var group: String?

    public init(
        id: String, title: String, number: Double? = nil, publishedAt: Date? = nil,
        link: URL? = nil, group: String? = nil
    ) {
        self.id = id
        self.title = title
        self.number = number
        self.publishedAt = publishedAt
        self.link = link
        self.group = group
    }
}

/// One image of an image chapter. Sources may give a plain URL string, or
/// `{ url, headers }` when the image host needs a Referer.
public struct ImagePage: Codable, Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]?

    public init(url: URL, headers: [String: String]? = nil) {
        self.url = url
        self.headers = headers
    }

    private enum CodingKeys: String, CodingKey { case url, headers }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let url = try? single.decode(URL.self) {
            self.init(url: url)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: try c.decode(URL.self, forKey: .url), headers: try c.decodeIfPresent([String: String].self, forKey: .headers))
    }

    public func encode(to encoder: Encoder) throws {
        if headers == nil || headers?.isEmpty == true {
            var c = encoder.singleValueContainer()
            try c.encode(url)
        } else {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(headers, forKey: .headers)
        }
    }
}

public enum ChapterContent: Sendable, Hashable {
    case text(html: String, notesBefore: String?, notesAfter: String?)
    case images([ImagePage])
    /// The chapter lives on another site. The app hands it to an installed source that
    /// declares that domain, or offers reader mode.
    case link(URL)
}

extension ChapterContent: Codable {
    private enum CodingKeys: String, CodingKey { case type, html, notesBefore, notesAfter, pages, url }

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
            self = .images(try c.decode([ImagePage].self, forKey: .pages))
        case "link":
            self = .link(try c.decode(URL.self, forKey: .url))
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
        case let .link(url):
            try c.encode("link", forKey: .type)
            try c.encode(url, forKey: .url)
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

/// A browsable list a source offers through `getListings()`, such as "Freshly updated"
/// or "Best of all time". Its works come from `getListing(id, page)`.
public struct SourceListing: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// A short line under the title, like "Most kudos this week".
    public var subtitle: String?

    public init(id: String, title: String, subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

/// A search filter a source offers through `getFilters()`. Values go back to
/// `search(query, page, filters)` as `{ [id]: [optionID, ...] }`: one entry for
/// `select`, any number for `multi`, and `["true"]` or nothing for `toggle`.
public struct SearchFilter: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case select, multi, toggle }

    public var id: String
    public var label: String
    public var type: Kind
    public var options: [Option]?
    /// Option IDs selected when the user hasn't picked anything.
    public var defaultValue: [String]?

    public struct Option: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    private enum CodingKeys: String, CodingKey { case id, label, type, options, defaultValue = "default" }

    public init(id: String, label: String, type: Kind, options: [Option]? = nil, defaultValue: [String]? = nil) {
        self.id = id
        self.label = label
        self.type = type
        self.options = options
        self.defaultValue = defaultValue
    }
}

/// A term the reader keeps for a work, mostly for web novels: names, places, cultivation ranks.
public struct GlossaryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var term: String
    public var note: String

    public init(id: UUID = UUID(), term: String, note: String) {
        self.id = id
        self.term = term
        self.note = note
    }
}
