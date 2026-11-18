import Foundation
import ShelfCore

/// A passage the reader marked in a text chapter, with an optional note. The quote is
/// stored with a little text either side so it can be found again after the source
/// changes the chapter's markup.
public struct Highlight: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var chapterID: String
    public var chapterTitle: String
    /// The marked text.
    public var exact: String
    /// Up to 32 characters before and after it, for finding it again.
    public var prefix: String
    public var suffix: String
    public var note: String
    public var createdAt: Date

    public init(id: UUID = UUID(), chapterID: String, chapterTitle: String, exact: String, prefix: String = "", suffix: String = "", note: String = "", createdAt: Date = Date()) {
        self.id = id
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.exact = exact
        self.prefix = prefix
        self.suffix = suffix
        self.note = note
        self.createdAt = createdAt
    }
}

extension WorkRecord {
    /// Highlights in reading order: by chapter, then by when they were made.
    public var sortedHighlights: [Highlight] {
        let order = Dictionary(chapters.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (highlights ?? []).sorted {
            let a = order[$0.chapterID] ?? Int.max, b = order[$1.chapterID] ?? Int.max
            return a != b ? a < b : $0.createdAt < $1.createdAt
        }
    }

    public func highlights(in chapterID: String) -> [Highlight] {
        (highlights ?? []).filter { $0.chapterID == chapterID }
    }
}

extension LibraryState {
    public mutating func addHighlight(_ highlight: Highlight, to key: WorkKey) {
        update(key) { record in
            var list = record.highlights ?? []
            list.removeAll { $0.id == highlight.id }
            list.append(highlight)
            record.highlights = list
        }
    }

    public mutating func removeHighlight(_ id: UUID, from key: WorkKey) {
        update(key) { record in
            record.highlights?.removeAll { $0.id == id }
            if record.highlights?.isEmpty == true { record.highlights = nil }
        }
    }

    public mutating func setHighlightNote(_ id: UUID, note: String, in key: WorkKey) {
        update(key) { record in
            guard let index = record.highlights?.firstIndex(where: { $0.id == id }) else { return }
            record.highlights?[index].note = note
        }
    }
}

/// Turns highlights into text to share or paste elsewhere.
public enum QuoteFormatter {
    /// “Quote” — Title, Chapter (Author)
    public static func quote(_ highlight: Highlight, in record: WorkRecord) -> String {
        var line = "“\(collapse(highlight.exact))” — \(record.title)"
        if !highlight.chapterTitle.isEmpty { line += ", \(highlight.chapterTitle)" }
        if !record.authors.isEmpty { line += " (\(record.authors.joined(separator: ", ")))" }
        let note = highlight.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { line += "\n\(note)" }
        return line
    }

    /// Every highlight in a work as Markdown, grouped by chapter.
    public static func markdown(_ record: WorkRecord) -> String {
        var out = "# \(record.title)\n"
        if !record.authors.isEmpty { out += "\n_\(record.authors.joined(separator: ", "))_\n" }
        var chapter: String?
        for highlight in record.sortedHighlights {
            if highlight.chapterID != chapter {
                chapter = highlight.chapterID
                out += "\n## \(highlight.chapterTitle.isEmpty ? "Chapter" : highlight.chapterTitle)\n"
            }
            out += "\n> \(collapse(highlight.exact))\n"
            let note = highlight.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { out += "\n\(note)\n" }
        }
        return out
    }

    /// Joins the paragraphs of a quote that spans several into one line.
    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
