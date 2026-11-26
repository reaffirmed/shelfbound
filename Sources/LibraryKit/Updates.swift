import Foundation
import ShelfCore

public enum UpdateInterval: String, Codable, Sendable, CaseIterable, Identifiable {
    case hourly, sixHours, daily, manual
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hourly: "Every hour"
        case .sixHours: "Every 6 hours"
        case .daily: "Once a day"
        case .manual: "Only when I ask"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .hourly: 3600
        case .sixHours: 6 * 3600
        case .daily: 24 * 3600
        case .manual: nil
        }
    }
}

/// What one update check found.
public struct UpdateReport: Sendable, Hashable {
    public struct Found: Sendable, Hashable {
        public var key: WorkKey
        public var title: String
        public var newChapters: [Chapter]
    }

    public var found: [Found] = []
    public var failures: [WorkKey: String] = [:]
    public var checked = 0

    public init() {}

    public var newChapterCount: Int { found.reduce(0) { $0 + $1.newChapters.count } }
}

public enum UpdateChecker {
    /// Why a fetched chapter list shouldn't replace the saved one, or nil when it's fine.
    /// A source returns an empty or much shorter list when the site sends a page it didn't
    /// expect (maintenance, a bot check, a redesign). Taking that list would wipe the work's
    /// chapters, and the next good check would then mark every unread chapter as new.
    public static func suspiciousList(_ fetched: [Chapter], replacing known: [Chapter]) -> String? {
        guard !known.isEmpty else { return nil }
        if fetched.isEmpty {
            return "The source returned no chapters. Kept the \(known.count) already saved."
        }
        if known.count >= 10, fetched.count * 2 < known.count {
            return "The source returned only \(fetched.count) of \(known.count) chapters. Kept the saved list."
        }
        return nil
    }

    /// Merges a fresh chapter list into a record. Chapters not seen before are recorded as
    /// new, unless this is the first time the work's chapters were fetched. A list that
    /// `suspiciousList` rejects leaves the record as it was.
    ///
    /// Only chapters after the last one already known count as new, plus at most a few
    /// that slot in earlier (an extra like 12.5). Many unknown chapters before the last
    /// known one mean the source is filling back in a list it cut short, not new releases.
    @discardableResult
    public static func apply(_ fetched: [Chapter], to record: inout WorkRecord, now: Date = Date()) -> [Chapter] {
        if suspiciousList(fetched, replacing: record.chapters) != nil { return [] }
        let known = Set(record.chapters.map(\.id))
        let isFirstFetch = record.chapters.isEmpty
        record.chapters = fetched
        record.lastCheckedAt = now
        guard !isFirstFetch else { return [] }
        let lastKnown = fetched.lastIndex { known.contains($0.id) } ?? -1
        let unknown = fetched.indices.filter { !known.contains(fetched[$0].id) && !record.readChapterIDs.contains(fetched[$0].id) }
        let earlier = unknown.filter { $0 < lastKnown }
        let maxEarlier = 3
        let picked = unknown.filter { $0 > lastKnown || earlier.count <= maxEarlier }
        let new = picked.map { fetched[$0] }
        for chapter in new where !record.newChapterIDs.contains(chapter.id) {
            record.newChapterIDs.append(chapter.id)
        }
        // Drop "new" marks for chapters the source removed.
        let current = Set(fetched.map(\.id))
        record.newChapterIDs.removeAll { !current.contains($0) }
        return new
    }

    /// Fetches chapter lists for every work in the library and merges them into `state`.
    /// Works from the same source are checked one at a time (sources are rate-limited
    /// anyway); different sources run side by side.
    public static func check(
        _ state: LibraryState,
        only keys: Set<WorkKey>? = nil,
        now: Date = Date(),
        fetch: @escaping @Sendable (WorkKey) async throws -> [Chapter]
    ) async -> (LibraryState, UpdateReport) {
        let targets = state.library.filter { keys?.contains($0.key) ?? true }
        let bySource = Dictionary(grouping: targets.map(\.key), by: \.sourceID)

        let results: [(WorkKey, Result<[Chapter], Error>)] = await withTaskGroup(of: [(WorkKey, Result<[Chapter], Error>)].self) { group in
            for (_, keys) in bySource {
                group.addTask {
                    var out: [(WorkKey, Result<[Chapter], Error>)] = []
                    for key in keys {
                        if Task.isCancelled { break }
                        do { out.append((key, .success(try await fetch(key)))) } catch { out.append((key, .failure(error))) }
                    }
                    return out
                }
            }
            var all: [(WorkKey, Result<[Chapter], Error>)] = []
            for await part in group { all += part }
            return all
        }

        var state = state
        var report = UpdateReport()
        for (key, result) in results {
            report.checked += 1
            switch result {
            case let .success(chapters):
                guard var record = state[key] else { continue }
                if let problem = suspiciousList(chapters, replacing: record.chapters) {
                    report.failures[key] = problem
                    continue
                }
                let new = apply(chapters, to: &record, now: now)
                state[key] = record
                if !new.isEmpty {
                    report.found.append(.init(key: key, title: record.title, newChapters: new))
                }
            case let .failure(error):
                report.failures[key] = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
        report.found.sort { $0.title < $1.title }
        state.lastUpdateCheck = now
        return (state, report)
    }

    /// Notification text for a report: "Hollow Tide: 2 new chapters", or a summary for several works.
    /// One alert to post. Works get their own alert, grouped by work on the phone and
    /// the watch, until there are too many; then one summary covers the lot.
    public struct Alert: Sendable, Hashable {
        public var id: String
        public var title: String
        public var body: String
        /// The work the alert is about, for its actions; nil for a summary.
        public var key: WorkKey?
        public var chapterIDs: [String]
        /// Groups alerts in Notification Center and on Apple Watch.
        public var thread: String
    }

    public static func alerts(_ report: UpdateReport, maxSeparate: Int = 4) -> [Alert] {
        guard !report.found.isEmpty else { return [] }
        if report.found.count > maxSeparate, let text = notificationText(report) {
            return [Alert(id: "updates-summary", title: text.title, body: text.body, key: nil, chapterIDs: [], thread: "updates")]
        }
        return report.found.map { found in
            let n = found.newChapters.count
            let body: String
            if n == 1 {
                body = found.newChapters.first?.title ?? "1 new chapter"
            } else {
                let latest = found.newChapters.last?.title
                body = "\(n) new chapters" + (latest.map { ", up to \($0)" } ?? "")
            }
            return Alert(id: "updates-\(found.key.id)", title: found.title, body: body, key: found.key,
                         chapterIDs: found.newChapters.map(\.id), thread: "work-\(found.key.id)")
        }
    }

    public static func notificationText(_ report: UpdateReport) -> (title: String, body: String)? {
        guard !report.found.isEmpty else { return nil }
        if report.found.count == 1, let only = report.found.first {
            let n = only.newChapters.count
            let body = n == 1 ? (only.newChapters.first?.title ?? "1 new chapter") : "\(n) new chapters"
            return (only.title, body)
        }
        let total = report.newChapterCount
        let names = report.found.prefix(3).map(\.title).joined(separator: ", ")
        let more = report.found.count > 3 ? " and \(report.found.count - 3) more" : ""
        return ("\(total) new chapters", names + more)
    }
}
