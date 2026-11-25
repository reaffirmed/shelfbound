import Foundation
import ShelfCore

/// One work found on one or more sources.
public struct MergedResult: Sendable, Hashable, Identifiable {
    public struct Hit: Sendable, Hashable {
        public var sourceID: String
        public var work: WorkSummary
        public var key: WorkKey { WorkKey(sourceID: sourceID, workID: work.id) }
    }

    /// Where a tap goes: the source that ranked it highest, or the one the person prefers.
    public var primary: Hit
    public var others: [Hit]

    public var id: String { primary.key.id }
    public var all: [Hit] { [primary] + others }
}

public enum SearchMerger {
    /// Merges per-source results into one list. The same work on several sources (same
    /// normalised title, and the same author when both list one) shows once. Order
    /// interleaves the sources by rank, so no single source crowds out the rest.
    /// `preferred` decides which source a merged result opens first.
    public static func merge(_ perSource: [(sourceID: String, results: [WorkSummary])], preferred: [String] = []) -> [MergedResult] {
        var merged: [MergedResult] = []
        var indexByTitle: [String: [Int]] = [:]
        let depth = perSource.map(\.results.count).max() ?? 0
        for rank in 0..<depth {
            for (sourceID, results) in perSource where rank < results.count {
                let work = results[rank]
                let hit = MergedResult.Hit(sourceID: sourceID, work: work)
                let title = TitleMatcher.normalize(work.title)
                let match = indexByTitle[title, default: []].first { i in
                    !merged[i].all.contains { $0.sourceID == sourceID } && sameAuthors(merged[i].primary.work, work)
                }
                if let i = match, !title.isEmpty {
                    merged[i].others.append(hit)
                } else {
                    indexByTitle[title, default: []].append(merged.count)
                    merged.append(MergedResult(primary: hit, others: []))
                }
            }
        }
        guard !preferred.isEmpty else { return merged }
        return merged.map { result in
            let hits = result.all
            guard let best = hits.min(by: { rank($0.sourceID, preferred) < rank($1.sourceID, preferred) }), best != result.primary else { return result }
            return MergedResult(primary: best, others: hits.filter { $0 != best })
        }
    }

    private static func rank(_ sourceID: String, _ preferred: [String]) -> Int {
        preferred.firstIndex(of: sourceID) ?? preferred.count
    }

    private static func sameAuthors(_ a: WorkSummary, _ b: WorkSummary) -> Bool {
        guard !a.authors.isEmpty, !b.authors.isEmpty else { return true }
        return !Set(a.authors.map(TitleMatcher.normalize)).isDisjoint(with: Set(b.authors.map(TitleMatcher.normalize)))
    }
}
