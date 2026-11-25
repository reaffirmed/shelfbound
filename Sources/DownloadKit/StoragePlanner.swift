import Foundation

/// Picks downloads to remove when storage goes over the limit: chapters already read,
/// oldest read first. Text chapters are never removed (they're tiny and fics vanish).
public enum StoragePlanner {
    public static func evictions(_ chapters: [DownloadedChapter], limit: Int64) -> [DownloadedChapter] {
        var total = chapters.reduce(0) { $0 + $1.bytes }
        guard total > limit else { return [] }
        let candidates = chapters
            .filter { $0.readAt != nil && !$0.format.isText }
            .sorted { ($0.readAt ?? .distantPast) < ($1.readAt ?? .distantPast) }
        var out: [DownloadedChapter] = []
        for chapter in candidates where total > limit {
            out.append(chapter)
            total -= chapter.bytes
        }
        return out
    }
}
