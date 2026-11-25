import Foundation
import ShelfCore

/// Where the reader is in a work.
public struct ReadingPosition: Codable, Sendable, Hashable {
    public var chapterID: String
    public var chapterTitle: String
    /// 0...1 through the chapter.
    public var progress: Double
    /// Page index for paged image chapters.
    public var page: Int?
    public var updatedAt: Date

    public init(chapterID: String, chapterTitle: String, progress: Double, page: Int? = nil, updatedAt: Date = Date()) {
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.progress = progress
        self.page = page
        self.updatedAt = updatedAt
    }
}

/// Per-work choices that override the app-wide defaults.
public struct WorkSettings: Codable, Sendable, Hashable {
    /// Nil follows the format's default (manga right to left, manhwa vertical).
    public var readingMode: ReadingMode?
    /// Nil follows the app-wide "Download new chapters" switch.
    public var autoDownload: Bool?
    /// Web novels: hide translator notes before and after each chapter.
    public var skipNotes: Bool
    /// Web novels: which translation group to read when several posted the same chapter.
    public var preferredGroup: String?
    /// Text works: this work's own theme, font and spacing. Nil uses the app's.
    public var readerStyle: ReaderStyle?
    /// Vertical strips: this work's auto-scroll speed in points a second. Nil uses the app's.
    public var autoScrollSpeed: Double?
    /// Text works: translate chapters on the device into this language (a BCP 47 code). Nil reads the original.
    public var translateTo: String?
    /// The language the work is written in, when detection guesses wrong. Nil detects it.
    public var translateFrom: String?
    /// Paged image chapters: zoom from panel to panel instead of showing whole pages.
    public var panelByPanel: Bool?

    public init(readingMode: ReadingMode? = nil, autoDownload: Bool? = nil, skipNotes: Bool = false, preferredGroup: String? = nil) {
        self.readingMode = readingMode
        self.autoDownload = autoDownload
        self.skipNotes = skipNotes
        self.preferredGroup = preferredGroup
    }
}

/// Everything the app keeps about one work: what it is, its chapter list, and the
/// reader's progress. Works opened but not saved stay as history (`inLibrary == false`).
public struct WorkRecord: Codable, Sendable, Hashable, Identifiable {
    public var key: WorkKey
    public var summary: WorkSummary
    public var work: Work?
    public var format: WorkFormat
    public var chapters: [Chapter]
    public var inLibrary: Bool
    public var addedAt: Date?
    public var lastReadAt: Date?
    public var position: ReadingPosition?
    public var readChapterIDs: Set<String>
    /// Chapters update checks found that the reader hasn't opened yet, oldest first.
    public var newChapterIDs: [String]
    public var lastCheckedAt: Date?
    public var settings: WorkSettings
    public var glossary: [GlossaryEntry]
    /// Passages marked in text chapters. Optional so library files from before highlights still load.
    public var highlights: [Highlight]?

    public var id: String { key.id }

    public init(key: WorkKey, summary: WorkSummary, format: WorkFormat) {
        self.key = key
        self.summary = summary
        self.format = format
        self.chapters = []
        self.inLibrary = false
        self.readChapterIDs = []
        self.newChapterIDs = []
        self.settings = WorkSettings()
        self.glossary = []
    }

    public var title: String { work?.title ?? summary.title }
    public var authors: [String] { work?.authors ?? summary.authors }
    public var coverURL: URL? { work?.coverURL ?? summary.coverURL }
    public var fandoms: [String] { work?.fandoms ?? summary.fandoms ?? [] }

    public var readingMode: ReadingMode {
        if format.isText { return .text }
        return settings.readingMode ?? format.defaultReadingMode
    }

    /// Chapters in reading order, with one chapter per number when several groups posted it.
    public var readingOrder: [Chapter] {
        ChapterOrder.readingOrder(chapters, preferredGroup: settings.preferredGroup)
    }

    public var unreadNewCount: Int { newChapterIDs.filter { !readChapterIDs.contains($0) }.count }

    public func isRead(_ chapterID: String) -> Bool { readChapterIDs.contains(chapterID) }

    /// The chapter "Continue" opens: the current one if unfinished, else the next unread one.
    public var continueChapter: Chapter? {
        let order = readingOrder
        guard let position, let index = order.firstIndex(where: { $0.id == position.chapterID }) else {
            return order.first { !isRead($0.id) } ?? order.first
        }
        if position.progress < 0.98 && !isRead(position.chapterID) { return order[index] }
        return order[(index + 1)...].first { !isRead($0.id) } ?? (index + 1 < order.count ? order[index + 1] : nil)
    }

    /// Progress through the work, 0...1, counting read chapters.
    public var workProgress: Double {
        let order = readingOrder
        guard !order.isEmpty else { return position?.progress ?? 0 }
        let read = order.filter { isRead($0.id) }.count
        return min(1, Double(read) / Double(order.count))
    }

    /// The next `count` unread chapters after the current position, for "download ahead".
    public func upcomingUnread(_ count: Int) -> [Chapter] {
        guard count > 0 else { return [] }
        let order = readingOrder
        let start = position.flatMap { p in order.firstIndex { $0.id == p.chapterID } } ?? 0
        return Array(order[start...].filter { !isRead($0.id) }.prefix(count))
    }
}

/// The whole library, saved as one JSON file. Small enough for thousands of works.
public struct LibraryState: Codable, Sendable, Hashable {
    public var records: [String: WorkRecord]
    public var lastUpdateCheck: Date?
    /// When the user last looked at the library, for "N new chapters since you last opened".
    public var lastViewedUpdatesAt: Date?

    public init(records: [String: WorkRecord] = [:]) {
        self.records = records
    }

    public subscript(key: WorkKey) -> WorkRecord? {
        get { records[key.id] }
        set { records[key.id] = newValue }
    }

    public var library: [WorkRecord] { records.values.filter(\.inLibrary) }

    public var history: [WorkRecord] {
        records.values.filter { $0.lastReadAt != nil }.sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
    }

    /// Creates the record if needed and refreshes what the source said about the work.
    @discardableResult
    public mutating func upsert(key: WorkKey, summary: WorkSummary, work: Work? = nil, chapters: [Chapter]? = nil, format: WorkFormat) -> WorkRecord {
        var record = records[key.id] ?? WorkRecord(key: key, summary: summary, format: format)
        if let work {
            record.work = work
            record.summary = work.summary.merging(fallback: summary)
            record.format = work.format ?? summary.format ?? format
        } else if record.work == nil {
            record.summary = summary
            record.format = summary.format ?? format
        }
        if let chapters {
            record.chapters = chapters
        }
        records[key.id] = record
        return record
    }

    public mutating func setInLibrary(_ key: WorkKey, _ inLibrary: Bool, now: Date = Date()) {
        guard var record = records[key.id] else { return }
        record.inLibrary = inLibrary
        if inLibrary && record.addedAt == nil { record.addedAt = now }
        records[key.id] = record
    }

    public mutating func savePosition(_ position: ReadingPosition, for key: WorkKey) {
        guard var record = records[key.id] else { return }
        record.position = position
        record.lastReadAt = position.updatedAt
        records[key.id] = record
    }

    /// Returns true if the chapter wasn't read before.
    @discardableResult
    public mutating func markRead(_ chapterID: String, in key: WorkKey, _ read: Bool = true) -> Bool {
        guard var record = records[key.id] else { return false }
        let changed: Bool
        if read {
            changed = record.readChapterIDs.insert(chapterID).inserted
            record.newChapterIDs.removeAll { $0 == chapterID }
        } else {
            changed = record.readChapterIDs.remove(chapterID) != nil
        }
        records[key.id] = record
        return changed
    }

    /// Marks every chapter up to and including `chapterID` as read.
    public mutating func markReadThrough(_ chapterID: String, in key: WorkKey) {
        guard var record = records[key.id] else { return }
        for chapter in record.readingOrder {
            record.readChapterIDs.insert(chapter.id)
            record.newChapterIDs.removeAll { $0 == chapter.id }
            if chapter.id == chapterID { break }
        }
        records[key.id] = record
    }

    public mutating func update(_ key: WorkKey, _ change: (inout WorkRecord) -> Void) {
        guard var record = records[key.id] else { return }
        change(&record)
        records[key.id] = record
    }

    /// Total unread new chapters across the library.
    public var newChapterCount: Int { library.reduce(0) { $0 + $1.unreadNewCount } }
}

extension WorkSummary {
    /// Fills missing fields from another summary (a search result often has a cover the work page lacks).
    func merging(fallback other: WorkSummary) -> WorkSummary {
        var s = self
        if s.coverURL == nil { s.coverURL = other.coverURL }
        if s.blurb == nil { s.blurb = other.blurb }
        if s.authors.isEmpty { s.authors = other.authors }
        if s.fandoms == nil { s.fandoms = other.fandoms }
        if s.format == nil { s.format = other.format }
        return s
    }
}

/// Loads and saves `LibraryState` atomically.
public struct LibraryFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func `default`() throws -> LibraryFile {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return LibraryFile(url: dir.appendingPathComponent("library.json"))
    }

    public func load() -> LibraryState {
        guard let data = try? Data(contentsOf: url) else { return LibraryState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LibraryState.self, from: data)) ?? LibraryState()
    }

    public func save(_ state: LibraryState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
