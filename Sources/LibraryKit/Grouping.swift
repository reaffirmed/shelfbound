import Foundation
import ShelfCore

public enum LibraryFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case all, fics, manga, manhwa
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .fics: "Fics"
        case .manga: "Manga"
        case .manhwa: "Manhwa"
        }
    }

    public func matches(_ format: WorkFormat) -> Bool {
        switch self {
        case .all: true
        case .fics: format.shelf == .fics
        case .manga: format.shelf == .manga
        case .manhwa: format.shelf == .manhwa
        }
    }
}

public enum LibraryGrouping: String, Codable, Sendable, CaseIterable, Identifiable {
    case fandom, format, source, none
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fandom: "Fandom"
        case .format: "Type"
        case .source: "Source"
        case .none: "None"
        }
    }
}

public enum LibrarySort: String, Codable, Sendable, CaseIterable, Identifiable {
    case recent, updated, title, added
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .recent: "Recently read"
        case .updated: "New chapters first"
        case .title: "Title"
        case .added: "Date added"
        }
    }
}

public struct LibrarySection: Sendable, Hashable, Identifiable {
    public var title: String
    /// "2 fics, 1 manga"
    public var subtitle: String
    public var records: [WorkRecord]
    public var id: String { title }
}

public enum LibraryLayout {
    /// The fandom a work is filed under. Fics use their first fandom tag. Manga and
    /// manhwa usually have none, so a series is its own fandom, which puts a manga
    /// next to fics written about it.
    public static func fandom(of record: WorkRecord) -> String {
        if let first = record.fandoms.first, !first.isEmpty { return cleanFandom(first) }
        return record.format.isText ? "Other" : record.title
    }

    /// "Starfall Academy (Anime)" and "Starfall Academy - Rin Okaze" both file as "Starfall Academy".
    public static func cleanFandom(_ tag: String) -> String {
        var name = tag
        for separator in [" | ", " - ", " (", " – "] {
            if let range = name.range(of: separator) { name = String(name[..<range.lowerBound]) }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    public static func sections(
        _ records: [WorkRecord], filter: LibraryFilter, grouping: LibraryGrouping, sort: LibrarySort,
        sourceName: (String) -> String = { $0 }
    ) -> [LibrarySection] {
        let visible = sorted(records.filter { $0.inLibrary && filter.matches($0.format) }, by: sort)
        func key(_ record: WorkRecord) -> String {
            switch grouping {
            case .fandom: fandom(of: record)
            case .format: record.format.label
            case .source: sourceName(record.key.sourceID)
            case .none: "All"
            }
        }
        var order: [String] = []
        var groups: [String: [WorkRecord]] = [:]
        for record in visible {
            let k = key(record)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(record)
        }
        // Biggest groups first, then by name; "Other" last.
        order.sort { a, b in
            if a == "Other" { return false }
            if b == "Other" { return true }
            let (ca, cb) = (groups[a]!.count, groups[b]!.count)
            return ca != cb ? ca > cb : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        if grouping == .none { order = order.isEmpty ? [] : ["All"] }
        return order.map { LibrarySection(title: $0, subtitle: countLine(groups[$0]!), records: groups[$0]!) }
    }

    public static func sorted(_ records: [WorkRecord], by sort: LibrarySort) -> [WorkRecord] {
        switch sort {
        case .recent:
            records.sorted { ($0.lastReadAt ?? $0.addedAt ?? .distantPast) > ($1.lastReadAt ?? $1.addedAt ?? .distantPast) }
        case .updated:
            records.sorted {
                $0.unreadNewCount != $1.unreadNewCount
                    ? $0.unreadNewCount > $1.unreadNewCount
                    : ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast)
            }
        case .title:
            records.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .added:
            records.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
        }
    }

    /// "2 fics, 1 manga"
    public static func countLine(_ records: [WorkRecord]) -> String {
        var counts: [WorkFormat: Int] = [:]
        for r in records { counts[r.format, default: 0] += 1 }
        return WorkFormat.allCases.compactMap { format -> String? in
            guard let n = counts[format] else { return nil }
            switch format {
            case .fic: return n == 1 ? "1 fic" : "\(n) fics"
            case .novel: return n == 1 ? "1 novel" : "\(n) novels"
            case .comic: return n == 1 ? "1 comic" : "\(n) comics"
            default: return "\(n) \(format.label.lowercased())"
            }
        }.joined(separator: ", ")
    }

    /// Works with a place saved and something left to read, most recent first.
    public static func continueReading(_ records: [WorkRecord], filter: LibraryFilter = .all, limit: Int = 12) -> [WorkRecord] {
        records
            .filter { r in
                guard r.position != nil, filter.matches(r.format) else { return false }
                return r.continueChapter != nil
            }
            .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}

public enum ChapterOrder {
    /// Sorts by chapter number when every chapter has one (sources list them either way),
    /// and keeps one chapter per number when several translation groups posted it.
    public static func readingOrder(_ chapters: [Chapter], preferredGroup: String?) -> [Chapter] {
        var list = chapters
        if !list.isEmpty, list.allSatisfy({ $0.number != nil }) {
            list = list.enumerated().sorted { a, b in
                a.element.number! != b.element.number! ? a.element.number! < b.element.number! : a.offset < b.offset
            }.map(\.element)
        }
        guard list.contains(where: { $0.group != nil }) else { return list }
        var seen: [Double: Int] = [:]
        var out: [Chapter] = []
        for chapter in list {
            guard let number = chapter.number else {
                out.append(chapter)
                continue
            }
            if let existing = seen[number] {
                if let preferredGroup, chapter.group == preferredGroup, out[existing].group != preferredGroup {
                    out[existing] = chapter
                }
            } else {
                seen[number] = out.count
                out.append(chapter)
            }
        }
        return out
    }

    /// Groups that posted chapters of this work, most chapters first.
    public static func groups(_ chapters: [Chapter]) -> [String] {
        var counts: [String: Int] = [:]
        for c in chapters { if let g = c.group { counts[g, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}
