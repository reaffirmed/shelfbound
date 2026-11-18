import Foundation
import ShelfCore

public enum FullStoragePolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case removeOldestRead, pauseDownloads
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .removeOldestRead: "Remove oldest read"
        case .pauseDownloads: "Pause downloads"
        }
    }
}

public struct DownloadSettings: Codable, Sendable, Hashable {
    /// Queue new chapters that update checks find, for works in the library.
    public var autoDownload: Bool
    public var wifiOnly: Bool
    /// Fics are about 50 KB a chapter, so they may use cellular even when `wifiOnly` is on.
    public var cellularForText: Bool
    /// Keep this many unread chapters ahead of where you are downloaded.
    public var downloadAhead: Int
    public var storageLimitBytes: Int64
    public var whenFull: FullStoragePolicy
    /// Delete image chapters once read. Text chapters are always kept.
    public var removeAfterReading: Bool
    public var paused: Bool

    public init(
        autoDownload: Bool = true, wifiOnly: Bool = true, cellularForText: Bool = true, downloadAhead: Int = 3,
        storageLimitBytes: Int64 = 8 * 1_000_000_000, whenFull: FullStoragePolicy = .removeOldestRead,
        removeAfterReading: Bool = false, paused: Bool = false
    ) {
        self.autoDownload = autoDownload
        self.wifiOnly = wifiOnly
        self.cellularForText = cellularForText
        self.downloadAhead = downloadAhead
        self.storageLimitBytes = storageLimitBytes
        self.whenFull = whenFull
        self.removeAfterReading = removeAfterReading
        self.paused = paused
    }
}

/// What to download: one chapter, with enough labels to show it in the queue.
public struct DownloadRequest: Codable, Sendable, Hashable {
    public var ref: ChapterRef
    public var workTitle: String
    public var chapterTitle: String
    public var format: WorkFormat
    public var coverURL: URL?
    public var automatic: Bool

    public init(ref: ChapterRef, workTitle: String, chapterTitle: String, format: WorkFormat, coverURL: URL? = nil, automatic: Bool = false) {
        self.ref = ref
        self.workTitle = workTitle
        self.chapterTitle = chapterTitle
        self.format = format
        self.coverURL = coverURL
        self.automatic = automatic
    }
}

public struct PageTask: Codable, Sendable, Hashable {
    public var index: Int
    public var page: ImagePage
    public var file: String
    public var done: Bool
    public var bytes: Int64
    public var attempts: Int
    /// A transfer for this page is running (possibly in the background session).
    public var inFlight: Bool

    public var host: String { page.url.host?.lowercased() ?? "" }
}

public struct DownloadJob: Codable, Sendable, Hashable, Identifiable {
    public enum State: Codable, Sendable, Hashable {
        case waiting
        case resolving
        case downloading
        case failed(String)
    }

    public var request: DownloadRequest
    public var state: State
    public var pages: [PageTask]?
    public var createdAt: Date
    /// Why the job isn't moving, for the queue screen ("Waiting for Wi-Fi").
    public var note: String?

    public var id: String { request.ref.id }
    public var ref: ChapterRef { request.ref }

    public var pagesDone: Int { pages?.filter(\.done).count ?? 0 }
    public var pageCount: Int { pages?.count ?? 0 }

    public var progress: Double {
        guard let pages, !pages.isEmpty else { return 0 }
        return Double(pagesDone) / Double(pages.count)
    }

    public var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

/// A finished download on disk.
public struct DownloadedChapter: Codable, Sendable, Hashable, Identifiable {
    public var ref: ChapterRef
    public var workTitle: String
    public var chapterTitle: String
    public var format: WorkFormat
    public var bytes: Int64
    public var downloadedAt: Date
    public var readAt: Date?

    public var id: String { ref.id }
}

/// `chapter.json` inside a chapter's folder. Image pages are file names in the same folder.
public struct StoredChapter: Codable, Sendable, Hashable {
    public var info: DownloadedChapter
    public var content: ChapterContent
}

/// What the UI shows: the queue, what's on disk and how much space it takes.
public struct DownloadSnapshot: Sendable, Hashable {
    public var jobs: [DownloadJob] = []
    public var downloaded: [String: DownloadedChapter] = [:]
    public var paused = false
    public var overLimit = false
    public var limitBytes: Int64 = 0

    public init() {}

    public var totalBytes: Int64 { downloaded.values.reduce(0) { $0 + $1.bytes } }

    public func bytes(for shelf: WorkFormat.Shelf) -> Int64 {
        downloaded.values.filter { $0.format.shelf == shelf }.reduce(0) { $0 + $1.bytes }
    }

    public func isDownloaded(_ ref: ChapterRef) -> Bool { downloaded[ref.id] != nil }
    public func job(for ref: ChapterRef) -> DownloadJob? { jobs.first { $0.id == ref.id } }

    public func chapters(of work: WorkKey) -> [DownloadedChapter] {
        downloaded.values.filter { $0.ref.work == work }
    }

    /// Downloads grouped by work, biggest first, for "Review downloads by title".
    public var byWork: [(work: WorkKey, title: String, bytes: Int64, count: Int)] {
        Dictionary(grouping: downloaded.values, by: \.ref.work)
            .map { (work: $0.key, title: $0.value.first?.workTitle ?? $0.key.workID, bytes: $0.value.reduce(0) { $0 + $1.bytes }, count: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
    }
}
