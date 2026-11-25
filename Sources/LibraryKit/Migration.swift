import Foundation
import ShelfCore

/// Moves a work to another source (a site went down, or another source has better scans)
/// and keeps what the reader did: library membership, read chapters, place, settings and
/// glossary. Chapters are matched by number, since IDs differ between sources.
public enum Migration {
    public struct Preview: Sendable, Hashable {
        /// Read chapters on the old source that have a match on the new one.
        public var matchedRead: Int
        public var totalRead: Int
        public var newChapterCount: Int
        public var oldChapterCount: Int
        /// The new source's chapter that the reading position moves to.
        public var position: Chapter?
    }

    public static func preview(_ record: WorkRecord, onto chapters: [Chapter]) -> Preview {
        let read = readNumbers(record)
        let matched = ChapterMatcher.ids(in: chapters, numbered: read)
        return Preview(
            matchedRead: Set(chapters.filter { matched.contains($0.id) }.compactMap(ChapterMatcher.number(of:))).count,
            totalRead: read.count, newChapterCount: chapters.count, oldChapterCount: record.chapters.count,
            position: position(record, onto: chapters)?.chapter)
    }

    /// The new record. The caller replaces the old one with it.
    public static func migrate(_ record: WorkRecord, to key: WorkKey, summary: WorkSummary, work: Work?, chapters: [Chapter], format: WorkFormat) -> WorkRecord {
        var next = WorkRecord(key: key, summary: work?.summary.merging(fallback: summary) ?? summary, format: work?.format ?? summary.format ?? format)
        next.work = work
        next.chapters = chapters
        next.inLibrary = record.inLibrary
        next.addedAt = record.addedAt
        next.lastReadAt = record.lastReadAt
        next.lastCheckedAt = Date()
        next.readChapterIDs = ChapterMatcher.ids(in: chapters, numbered: readNumbers(record))
        next.glossary = record.glossary
        next.highlights = record.highlights.map { remap($0, from: record.chapters, onto: chapters) }
        next.settings = record.settings
        // Group names belong to the old source's chapter list.
        next.settings.preferredGroup = nil
        if let (chapter, progress) = position(record, onto: chapters) {
            next.position = ReadingPosition(
                chapterID: chapter.id, chapterTitle: chapter.title, progress: progress,
                page: nil, updatedAt: record.position?.updatedAt ?? Date())
        }
        return next
    }

    /// Points highlights at the new source's chapter with the same number. Ones that
    /// can't be matched keep their old chapter and still show in the work's list.
    private static func remap(_ highlights: [Highlight], from old: [Chapter], onto chapters: [Chapter]) -> [Highlight] {
        let oldNumbers = Dictionary(old.compactMap { c in ChapterMatcher.number(of: c).map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        var byNumber: [Double: Chapter] = [:]
        for chapter in chapters {
            if let n = ChapterMatcher.number(of: chapter), byNumber[n] == nil { byNumber[n] = chapter }
        }
        return highlights.map { h in
            guard let n = oldNumbers[h.chapterID], let chapter = byNumber[n] else { return h }
            var moved = h
            moved.chapterID = chapter.id
            moved.chapterTitle = chapter.title
            return moved
        }
    }

    private static func readNumbers(_ record: WorkRecord) -> Set<Double> {
        Set(record.chapters.filter { record.isRead($0.id) }.compactMap(ChapterMatcher.number(of:)))
    }

    private static func position(_ record: WorkRecord, onto chapters: [Chapter]) -> (chapter: Chapter, progress: Double)? {
        guard let position = record.position,
              let old = record.chapters.first(where: { $0.id == position.chapterID }),
              let number = ChapterMatcher.number(of: old),
              let match = chapters.first(where: { ChapterMatcher.number(of: $0) == number })
        else { return nil }
        return (match, position.progress)
    }
}

extension LibraryState {
    /// Replaces the record at `old` with `record` (from `Migration.migrate`).
    public mutating func replace(_ old: WorkKey, with record: WorkRecord) {
        records[old.id] = nil
        records[record.key.id] = record
    }
}
