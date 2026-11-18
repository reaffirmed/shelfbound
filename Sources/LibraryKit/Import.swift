import Foundation
import ShelfCore

/// A work read out of another app's backup or a list of links, before it's matched to an
/// installed source.
public struct ImportedWork: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var authors: [String]
    /// The other app's name for the source ("MangaDex", "Asura Scans").
    public var sourceName: String?
    /// The work's page on the site, when the backup has it.
    public var url: URL?
    public var readChapterNumbers: Set<Double>
    public var lastReadChapterNumber: Double?
    public var addedAt: Date?
    public var lastReadAt: Date?
    public var categories: [String]

    public init(
        id: String, title: String, authors: [String] = [], sourceName: String? = nil, url: URL? = nil,
        readChapterNumbers: Set<Double> = [], lastReadChapterNumber: Double? = nil, addedAt: Date? = nil,
        lastReadAt: Date? = nil, categories: [String] = []
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.sourceName = sourceName
        self.url = url
        self.readChapterNumbers = readChapterNumbers
        self.lastReadChapterNumber = lastReadChapterNumber ?? readChapterNumbers.max()
        self.addedAt = addedAt
        self.lastReadAt = lastReadAt
        self.categories = categories
    }
}

public struct ImportBatch: Sendable, Hashable {
    public enum Origin: String, Sendable, Hashable {
        case paperback = "Paperback", aidoku = "Aidoku", links = "Links"
    }

    public var origin: Origin
    public var works: [ImportedWork]
}

public enum ImportError: Error, LocalizedError, Equatable {
    case unrecognised
    case empty

    public var errorDescription: String? {
        switch self {
        case .unrecognised: "That file isn't a Paperback or Aidoku backup that Shelfbound can read."
        case .empty: "There's nothing to import in that file."
        }
    }
}

public enum LibraryImporter {
    /// Reads a backup. `files` is the file itself for Aidoku, or the entries of a Paperback
    /// backup zip (name → contents).
    public static func parse(files: [String: Data]) throws -> ImportBatch {
        if let batch = try? PaperbackBackup.parse(files), !batch.works.isEmpty { return batch }
        for data in files.values {
            if let batch = try? AidokuBackup.parse(data), !batch.works.isEmpty { return batch }
        }
        if let text = files.values.first.flatMap({ String(data: $0, encoding: .utf8) }) {
            let batch = LinkList.parse(text)
            if !batch.works.isEmpty { return batch }
        }
        throw ImportError.unrecognised
    }
}

// MARK: - Links

/// Pasted or exported links, one work per URL. AO3 bookmarks, a reading list, anything.
public enum LinkList {
    public static func parse(_ text: String) -> ImportBatch {
        let pattern = #"https?://[^\s<>"'\])]+"#
        var seen = Set<String>()
        var works: [ImportedWork] = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: search) {
            search = range.upperBound..<text.endIndex
            let raw = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            guard let url = URL(string: raw), let host = url.host, seen.insert(canonical(url)).inserted else { continue }
            works.append(ImportedWork(id: canonical(url), title: "", sourceName: host, url: url))
        }
        return ImportBatch(origin: .links, works: works)
    }

    /// AO3 chapter and work links to the same work count once.
    static func canonical(_ url: URL) -> String {
        let string = url.absoluteString
        if let range = string.range(of: #"archiveofourown\.org/works/\d+"#, options: .regularExpression) {
            return String(string[range])
        }
        return string.components(separatedBy: "#")[0]
    }
}

// MARK: - Aidoku

/// Aidoku's backup: JSON (or a property list) with `library`, `manga`, `chapters`, `history`
/// and `categories`. Read loosely, since fields have come and gone between versions.
public enum AidokuBackup {
    public static func parse(_ data: Data) throws -> ImportBatch {
        let object: Any
        if let json = try? JSONSerialization.jsonObject(with: data) {
            object = json
        } else {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        }
        guard let root = object as? [String: Any], let library = root["library"] as? [[String: Any]] else {
            throw ImportError.unrecognised
        }
        let manga = (root["manga"] as? [[String: Any]]) ?? []
        let chapters = (root["chapters"] as? [[String: Any]]) ?? []
        let history = (root["history"] as? [[String: Any]]) ?? []

        func key(_ item: [String: Any], _ idKey: String) -> String {
            "\(string(item["sourceId"]) ?? "")|\(string(item[idKey]) ?? "")"
        }
        var mangaByKey: [String: [String: Any]] = [:]
        for item in manga { mangaByKey[key(item, "id")] = item }
        var chapterNumber: [String: Double] = [:]
        for item in chapters {
            let chapterKey = "\(key(item, "mangaId"))|\(string(item["id"]) ?? "")"
            chapterNumber[chapterKey] = double(item["chapter"]) ?? double(item["chapterNum"])
        }
        var read: [String: Set<Double>] = [:]
        var lastRead: [String: Date] = [:]
        for item in history {
            let workKey = key(item, "mangaId")
            let chapterKey = "\(workKey)|\(string(item["chapterId"]) ?? "")"
            let completed = (item["completed"] as? Bool) ?? false
            if completed, let number = chapterNumber[chapterKey] { read[workKey, default: []].insert(number) }
            if let date = date(item["dateRead"]) { lastRead[workKey] = max(lastRead[workKey] ?? date, date) }
        }

        let works: [ImportedWork] = library.compactMap { entry in
            let workKey = key(entry, "mangaId")
            let info = mangaByKey[workKey] ?? [:]
            guard let title = string(info["title"]) ?? string(entry["title"]), !title.isEmpty else { return nil }
            let authors = [string(info["author"]), string(info["artist"])].compactMap { $0 }.filter { !$0.isEmpty }
            return ImportedWork(
                id: workKey, title: title, authors: Array(Set(authors)).sorted(),
                sourceName: string(entry["sourceId"]),
                url: string(info["url"]).flatMap(URL.init(string:)),
                readChapterNumbers: read[workKey] ?? [],
                addedAt: date(entry["dateAdded"]), lastReadAt: lastRead[workKey] ?? date(entry["lastOpened"]),
                categories: (entry["categories"] as? [String]) ?? [])
        }
        return ImportBatch(origin: .aidoku, works: works)
    }
}

// MARK: - Paperback

/// Paperback's backup is a zip of JSON files, each a map of id → object, which refer to
/// each other by id: library entries → source manga → manga info; chapter progress → chapter
/// → source manga. Names end in a format version (`__LIBRARY_MANGA_V4`), matched loosely.
public enum PaperbackBackup {
    public static func parse(_ files: [String: Data]) throws -> ImportBatch {
        func table(_ name: String) -> [String: [String: Any]] {
            guard let entry = files.first(where: { tableName($0.key) == name }),
                  let json = try? JSONSerialization.jsonObject(with: entry.value)
            else { return [:] }
            if let map = json as? [String: [String: Any]] { return map }
            if let list = json as? [[String: Any]] {
                var map: [String: [String: Any]] = [:]
                for item in list { if let id = string(item["id"]) { map[id] = item } }
                return map
            }
            return [:]
        }
        let library = table("LIBRARY_MANGA")
        guard !library.isEmpty else { throw ImportError.unrecognised }
        let sourceManga = table("SOURCE_MANGA")
        let mangaInfo = table("MANGA_INFO")
        let chapters = table("CHAPTER")
        let progress = table("CHAPTER_PROGRESS_MARKER")

        // Read chapters per source manga.
        var read: [String: Set<Double>] = [:]
        var lastRead: [String: Date] = [:]
        for marker in progress.values {
            guard let chapter = ref(marker["chapter"]).flatMap({ chapters[$0] }),
                  let sourceMangaID = ref(chapter["sourceManga"]) else { continue }
            let completed = (marker["completed"] as? Bool) ?? false
            if completed, let number = double(chapter["chapNum"]) { read[sourceMangaID, default: []].insert(number) }
            if let time = date(marker["time"]) { lastRead[sourceMangaID] = max(lastRead[sourceMangaID] ?? time, time) }
        }

        let works: [ImportedWork] = library.compactMap { id, entry in
            guard let primaryID = ref(entry["primarySource"]), let primary = sourceManga[primaryID] else { return nil }
            let infoID = ref(primary["mangaInfo"]) ?? ref(entry["mangaInfo"])
            let info = infoID.flatMap { mangaInfo[$0] } ?? [:]
            let titles = (info["titles"] as? [String]) ?? [string(info["title"])].compactMap { $0 }
            guard let title = titles.first, !title.isEmpty else { return nil }
            let authors = [string(info["author"]), string(info["artist"])].compactMap { $0 }.filter { !$0.isEmpty }
            let tabs = (entry["libraryTabs"] as? [Any])?.compactMap { tab -> String? in
                (tab as? [String: Any]).flatMap { string($0["name"]) } ?? ref(tab)
            } ?? []
            return ImportedWork(
                id: id, title: title, authors: Array(Set(authors)).sorted(),
                sourceName: string(primary["sourceId"]),
                readChapterNumbers: read[primaryID] ?? [],
                addedAt: date(entry["dateBookmarked"]), lastReadAt: lastRead[primaryID],
                categories: tabs)
        }
        return ImportBatch(origin: .paperback, works: works.sorted { $0.title < $1.title })
    }

    /// "backup/__CHAPTER_PROGRESS_MARKER_V4.json" → "CHAPTER_PROGRESS_MARKER".
    static func tableName(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent.uppercased()
        if name.hasSuffix(".JSON") { name.removeLast(5) }
        while name.hasPrefix("_") { name.removeFirst() }
        if let range = name.range(of: #"_V\d+$"#, options: .regularExpression) { name.removeSubrange(range) }
        return name
    }

    /// A reference is either the other object's id, or `{ "id": … }` (sometimes with a type).
    static func ref(_ value: Any?) -> String? {
        if let dict = value as? [String: Any] { return string(dict["id"]) }
        return string(value)
    }
}

// MARK: - Loose JSON helpers

private func string(_ value: Any?) -> String? {
    switch value {
    case let s as String: s
    case let n as NSNumber: n.stringValue
    default: nil
    }
}

private func double(_ value: Any?) -> Double? {
    switch value {
    case let n as NSNumber: n.doubleValue
    case let s as String: Double(s)
    default: nil
    }
}

/// ISO 8601 strings, Apple reference-date seconds (Paperback, plists), or Unix seconds/ms.
private func date(_ value: Any?) -> Date? {
    switch value {
    case let d as Date: return d
    case let s as String:
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    case let n as NSNumber:
        let v = n.doubleValue
        if v > 100_000_000_000 { return Date(timeIntervalSince1970: v / 1000) }
        // Before 2017 as Unix time means it's really seconds since 2001 (Apple's reference date).
        if v < 1_500_000_000 { return Date(timeIntervalSinceReferenceDate: v) }
        return Date(timeIntervalSince1970: v)
    default:
        return nil
    }
}
