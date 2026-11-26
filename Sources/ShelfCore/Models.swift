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
    /// "listings" (`getListings` and `getListing`, browsable lists like "Trending"),
    /// "account" (sign-in through the site's own page, and the person's lists on the site).
    public var capabilities: [String]?
    /// With the "account" capability: where the person signs in.
    public var account: AccountConfig?

    public init(
        id: String, name: String, version: String, kind: ContentKind,
        languages: [String], contentRating: ContentRating, domains: [String],
        minAppVersion: String? = nil, format: WorkFormat? = nil, rateLimit: RateLimit? = nil,
        capabilities: [String]? = nil, account: AccountConfig? = nil
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
        self.account = account
    }

    public var defaultFormat: WorkFormat { format ?? (kind == .text ? .fic : .manga) }

    public func has(_ capability: SourceCapability) -> Bool {
        capabilities?.contains(capability.rawValue) ?? false
    }
}

public enum SourceCapability: String, Sendable {
    case filters, links, discovery, listings, account
}

/// How a source with the "account" capability signs in: the site's own sign-in page,
/// opened in a web view. The app keeps the site's cookies, never a password.
public struct AccountConfig: Codable, Sendable, Hashable {
    public var loginURL: URL

    public init(loginURL: URL) { self.loginURL = loginURL }
}

/// Who is signed in, from a source's `getAccount()`.
public struct SourceAccount: Codable, Sendable, Hashable {
    public var username: String
    public var url: URL?

    public init(username: String, url: URL? = nil) {
        self.username = username
        self.url = url
    }
}

/// One of the person's own lists on the site, from `getAccountLists()`: bookmarks,
/// a reading list, history. Its works come from `getAccountList(id, page)`.
public struct AccountList: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    /// Whether it makes sense to copy the list into the library.
    public var importable: Bool?

    public init(id: String, title: String, subtitle: String? = nil, importable: Bool? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.importable = importable
    }
}

/// What the signed-in person has done with a work on the site. Nil fields are unknown.
public struct WorkAccountState: Codable, Sendable, Hashable {
    public var markedForLater: Bool?
    public var subscribed: Bool?
    public var kudos: Bool?

    public init(markedForLater: Bool? = nil, subscribed: Bool? = nil, kudos: Bool? = nil) {
        self.markedForLater = markedForLater
        self.subscribed = subscribed
        self.kudos = kudos
    }
}

/// Something the signed-in person can do to a work from its page, through `setWorkState`.
public enum WorkAction: String, Codable, Sendable, CaseIterable {
    case markedForLater, subscribed, kudos
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
    /// The signed-in person's marks on this work, for sources with the "account" capability.
    public var account: WorkAccountState?

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
/// `search(query, page, filters)` as `{ [id]: [String] }`:
/// - `select`: one option ID. `multi`: any number of option IDs.
/// - `toggle`: `["true"]`, or nothing.
/// - `text`: the text typed, as one entry.
/// - `range`: `[min, max]`, either of which may be "" for no limit.
/// - `date`: `[from, to]` as `YYYY-MM-DD`, either of which may be "" for no limit.
/// - `tags`: the names to include. When `excludable`, the names to leave out go
///   under `"<id>.exclude"`. Names come from `options`, from the source's optional
///   `suggest(filterID, text)` when `suggests` is set, or from what the person types.
///
/// Apps before 0.4 only know `select`, `multi` and `toggle`, and apps before 0.5.6 don't
/// know `date`, so sources check `host.filterTypes` before offering the others.
public struct SearchFilter: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case select, multi, toggle, text, range, tags, date }

    public var id: String
    public var label: String
    public var type: Kind
    public var options: [Option]?
    /// Option IDs selected when the user hasn't picked anything.
    public var defaultValue: [String]?
    /// Grey hint text in a `text` or `tags` field, the unit of a `range` ("words"), or for a
    /// `date`, what the dates are ("updated").
    public var placeholder: String?
    /// `tags` only: whether names can be left out as well as included.
    public var excludable: Bool?
    /// `tags` only: whether the source's `suggest(filterID, text)` offers names as you type.
    public var suggests: Bool?
    /// A heading the filter screen groups this filter under, like "Tags" or "Stats".
    public var group: String?
    /// The `Work` field whose values this filter searches by: "fandoms", "relationships",
    /// "characters", "tags", "warnings", "categories", "rating", "language" or "authors".
    /// Tapping one of those on a work's page then searches the source for it.
    public var workField: String?

    public struct Option: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, type, options, defaultValue = "default", placeholder, excludable, suggests, group, workField
    }

    public init(
        id: String, label: String, type: Kind, options: [Option]? = nil, defaultValue: [String]? = nil,
        placeholder: String? = nil, excludable: Bool? = nil, suggests: Bool? = nil, group: String? = nil,
        workField: String? = nil
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.options = options
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.excludable = excludable
        self.suggests = suggests
        self.group = group
        self.workField = workField
    }

    /// The key that holds a `tags` filter's left-out names.
    public var excludeKey: String { id + ".exclude" }

    /// Whether `values` differ from this filter's default.
    public func isActive(in values: [String: [String]]) -> Bool {
        let current = (values[id] ?? []).filter { !$0.isEmpty }
        let base = (defaultValue ?? []).filter { !$0.isEmpty }
        if type == .tags, !(values[excludeKey] ?? []).isEmpty { return true }
        return current != base
    }
}

/// Turns a tag on a work's page into search filters, using the filter that declares
/// that work field.
public enum TagSearch {
    /// The filter a tag in `field` can search by, if the source has one that can take it.
    public static func filter(for tag: String, field: String, in filters: [SearchFilter], exclude: Bool = false) -> SearchFilter? {
        filters.first { filter in
            guard filter.workField == field else { return false }
            switch filter.type {
            case .tags: return !exclude || filter.excludable == true
            case .select: return !exclude && option(for: tag, in: filter) != nil
            case .multi: return !exclude && option(for: tag, in: filter) != nil
            case .text: return !exclude
            case .toggle, .range, .date: return false
            }
        }
    }

    /// The filter values for a search for works with `tag`, or without it when `exclude`
    /// is set. Every other filter keeps its default.
    public static func values(for tag: String, field: String, in filters: [SearchFilter], exclude: Bool = false) -> [String: [String]]? {
        guard let filter = filter(for: tag, field: field, in: filters, exclude: exclude) else { return nil }
        var values: [String: [String]] = [:]
        for f in filters { values[f.id] = f.defaultValue ?? [] }
        switch filter.type {
        case .tags:
            let name = option(for: tag, in: filter)?.id ?? tag
            values[exclude ? filter.excludeKey : filter.id] = [name]
        case .select, .multi:
            guard let option = option(for: tag, in: filter) else { return nil }
            values[filter.id] = [option.id]
        case .text:
            values[filter.id] = [tag]
        case .toggle, .range, .date:
            return nil
        }
        return values
    }

    /// The option whose label or ID matches the tag, ignoring case.
    static func option(for tag: String, in filter: SearchFilter) -> SearchFilter.Option? {
        let wanted = tag.trimmingCharacters(in: .whitespaces).lowercased()
        return filter.options?.first { $0.label.lowercased() == wanted || $0.id.lowercased() == wanted }
    }
}

/// Decodes an array, dropping elements it can't read, so one filter of a kind this
/// version doesn't know doesn't hide all the others.
public struct LossyArray<Element: Decodable>: Decodable {
    public var elements: [Element]

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        self.elements = elements
    }

    private struct Skip: Decodable {}
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
