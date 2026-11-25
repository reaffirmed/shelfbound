import Foundation
import ShelfCore

/// Gets a chapter's content from its source. The app implements this with the source
/// runtime (and resolves chapter links to text before returning).
public protocol ChapterResolver: Sendable {
    func content(for ref: ChapterRef) async throws -> ChapterContent
}

public enum NetworkKind: Sendable, Equatable {
    case wifi, cellular, offline
}

public protocol NetworkConditions: Sendable {
    var current: NetworkKind { get }
}

public struct TransferRequest: Sendable, Hashable {
    public var taskID: String
    public var url: URL
    public var headers: [String: String]
    public var allowsCellular: Bool
    public var resumeData: Data?
}

public enum TransferEvent: Sendable {
    /// `file` is a staged copy the manager now owns.
    case finished(taskID: String, file: URL)
    case failed(taskID: String, message: String, resumeData: Data?)
    /// The host answered with a bot check (such as a Cloudflare challenge).
    case blocked(taskID: String, url: URL)
}

/// Moves files over the network. On iPhone this is a background `URLSession`, so pages keep
/// downloading after the app is closed; tests use an in-memory fake.
public protocol FileTransfer: AnyObject, Sendable {
    func setEventHandler(_ handler: @escaping @Sendable (TransferEvent) -> Void)
    func start(_ request: TransferRequest)
    func cancel(taskIDs: Set<String>)
    /// Transfers still running from an earlier launch.
    func runningTaskIDs() async -> Set<String>
}

/// The download queue. Persists itself, so it resumes after the app is closed or killed.
///
/// - Chapters download in the order queued. Text chapters are fetched through the
///   source and saved as one file; image chapters get their page list from the source,
///   then each page is a separate transfer.
/// - Page transfers are spread out per host by `HostThrottle`.
/// - Failed pages retry with backoff, resuming from partial data when the system kept it.
/// - Wi-Fi only, the storage limit and "remove after reading" come from `DownloadSettings`.
public actor DownloadManager {
    private let layout: DownloadLayout
    private let resolver: ChapterResolver
    private let transfer: FileTransfer
    private let network: NetworkConditions
    private let now: @Sendable () -> Date
    private let maxResolving = 2
    private let maxAttempts = 4

    private var settings: DownloadSettings
    private var jobs: [DownloadJob] = []
    private var downloaded: [String: DownloadedChapter] = [:]
    private var throttle: HostThrottle
    private var resolving: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    private var wakeTask: Task<Void, Never>?
    private var wakeAt: Date?
    private var overLimit = false
    private var blockedHosts: Set<String> = []
    private var started = false
    private var observers: [UUID: @Sendable (DownloadSnapshot) -> Void] = [:]

    public init(
        layout: DownloadLayout, resolver: ChapterResolver, transfer: FileTransfer, network: NetworkConditions,
        settings: DownloadSettings = DownloadSettings(), throttle: HostThrottle = HostThrottle(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.layout = layout
        self.resolver = resolver
        self.transfer = transfer
        self.network = network
        self.settings = settings
        self.throttle = throttle
        self.now = now
    }

    // MARK: - Lifecycle

    /// Loads the queue and index from disk, reattaches to transfers still running from an
    /// earlier launch, and starts work.
    public func start() async {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: layout.staging, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: layout.resumeData, withIntermediateDirectories: true)
        loadIndex()
        jobs = (try? decode([DownloadJob].self, from: layout.queueFile)) ?? []

        let running = await transfer.runningTaskIDs()
        for j in jobs.indices {
            if jobs[j].state == .resolving { jobs[j].state = .waiting }
            guard var pages = jobs[j].pages else { continue }
            for p in pages.indices where pages[p].inFlight && !pages[p].done {
                let id = Self.taskID(jobs[j].id, pages[p].index)
                if running.contains(id), let host = pages[p].page.url.host?.lowercased() {
                    throttle.didStart(host: host, now: now())
                } else {
                    pages[p].inFlight = false
                }
            }
            jobs[j].pages = pages
        }
        transfer.setEventHandler { [weak self] event in
            guard let self else { return }
            Task { await self.handle(event) }
        }
        enforceStorage()
        changed()
        pump()
    }

    public func observe(_ observer: @escaping @Sendable (DownloadSnapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(snapshot)
        return id
    }

    public func stopObserving(_ id: UUID) { observers[id] = nil }

    public func update(settings: DownloadSettings) {
        let wasPaused = self.settings.paused
        self.settings = settings
        enforceStorage()
        if settings.paused && !wasPaused { pauseTransfers() }
        changed()
        pump()
    }

    /// Call when the network changes (Wi-Fi to cellular, offline).
    public func networkChanged() {
        if !canUseNetworkForImages { pauseTransfers() }
        pump()
    }

    // MARK: - Queue

    public var snapshot: DownloadSnapshot {
        var s = DownloadSnapshot()
        s.jobs = jobs
        s.downloaded = downloaded
        s.paused = settings.paused
        s.overLimit = overLimit
        s.limitBytes = settings.storageLimitBytes
        s.blockedHosts = blockedHosts.sorted()
        return s
    }

    /// Queues chapters that aren't downloaded or queued yet. Returns how many were added.
    @discardableResult
    public func enqueue(_ requests: [DownloadRequest]) -> Int {
        var added = 0
        for request in requests where downloaded[request.ref.id] == nil && !jobs.contains(where: { $0.id == request.ref.id }) {
            jobs.append(DownloadJob(request: request, state: .waiting, pages: nil, createdAt: now()))
            added += 1
        }
        if added > 0 {
            saveQueue()
            changed()
            pump()
        }
        return added
    }

    public func cancel(_ ref: ChapterRef) {
        guard let job = jobs.first(where: { $0.id == ref.id }) else { return }
        cancelTransfers(of: job)
        jobs.removeAll { $0.id == ref.id }
        try? FileManager.default.removeItem(at: layout.folder(for: ref))
        saveQueue()
        changed()
        pump()
    }

    public func cancelAll() {
        for job in jobs { cancelTransfers(of: job) }
        for job in jobs { try? FileManager.default.removeItem(at: layout.folder(for: job.ref)) }
        jobs.removeAll()
        saveQueue()
        changed()
    }

    public func retry(_ ref: ChapterRef) {
        guard let i = jobs.firstIndex(where: { $0.id == ref.id }) else { return }
        jobs[i].state = jobs[i].pages == nil ? .waiting : .downloading
        if var pages = jobs[i].pages {
            for p in pages.indices { pages[p].attempts = 0 }
            jobs[i].pages = pages
        }
        saveQueue()
        changed()
        pump()
    }

    // MARK: - Downloaded chapters

    /// The person passed the bot check for `host` in the browser: resume its downloads.
    public func unblock(host: String) {
        let host = host.lowercased()
        let cleared = blockedHosts.filter { Self.host($0, isWithin: host) || Self.host(host, isWithin: $0) }
        guard !cleared.isEmpty else { return }
        blockedHosts.subtract(cleared)
        for j in jobs.indices {
            if let blocked = jobs[j].blockedHost, cleared.contains(blocked) {
                jobs[j].blockedHost = nil
                jobs[j].note = nil
            }
        }
        changed()
        pump()
    }

    private func isBlocked(_ host: String) -> Bool {
        blockedHosts.contains { Self.host(host, isWithin: $0) }
    }

    /// `cdn.example.org` is within `example.org`.
    static func host(_ host: String, isWithin domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    public func isDownloaded(_ ref: ChapterRef) -> Bool { downloaded[ref.id] != nil }

    /// Saved content, with image pages pointing at local files.
    public func localContent(for ref: ChapterRef) -> ChapterContent? {
        guard downloaded[ref.id] != nil, let stored = try? decode(StoredChapter.self, from: layout.chapterFile(for: ref)) else {
            return nil
        }
        switch stored.content {
        case let .images(pages):
            let folder = layout.folder(for: ref)
            return .images(pages.map { ImagePage(url: folder.appendingPathComponent($0.url.relativeString)) })
        default:
            return stored.content
        }
    }

    /// Records that a chapter was read: it becomes eligible for cleanup, and is deleted now
    /// if "remove after reading" is on (image chapters only).
    public func markRead(_ ref: ChapterRef) {
        guard var info = downloaded[ref.id] else { return }
        info.readAt = now()
        downloaded[ref.id] = info
        if settings.removeAfterReading && !info.format.isText {
            delete(ref)
            return
        }
        saveIndex()
        enforceStorage()
        changed()
    }

    public func delete(_ ref: ChapterRef) {
        downloaded[ref.id] = nil
        try? FileManager.default.removeItem(at: layout.folder(for: ref))
        saveIndex()
        enforceStorage()
        changed()
        pump()
    }

    public func deleteWork(_ work: WorkKey) {
        for job in jobs where job.ref.work == work { cancelTransfers(of: job) }
        jobs.removeAll { $0.ref.work == work }
        for (id, info) in downloaded where info.ref.work == work { downloaded[id] = nil }
        try? FileManager.default.removeItem(at: layout.folder(for: work))
        saveQueue()
        saveIndex()
        enforceStorage()
        changed()
    }

    public func deleteAll() {
        cancelAll()
        for info in downloaded.values { try? FileManager.default.removeItem(at: layout.folder(for: info.ref.work)) }
        downloaded.removeAll()
        overLimit = false
        saveIndex()
        changed()
    }

    // MARK: - Scheduling

    private var canUseNetworkForImages: Bool {
        switch network.current {
        case .wifi: true
        case .cellular: !settings.wifiOnly
        case .offline: false
        }
    }

    private func canRun(_ job: DownloadJob) -> String? {
        if settings.paused { return "Paused" }
        if let host = job.blockedHost, isBlocked(host) { return "Verify \(host) in the browser to continue" }
        switch network.current {
        case .offline: return "Waiting for a connection"
        case .cellular where settings.wifiOnly && !(job.request.format.isText && settings.cellularForText):
            return "Waiting for Wi-Fi"
        default: break
        }
        if overLimit && !job.request.format.isText { return "Storage limit reached" }
        return nil
    }

    /// Starts whatever can start now, and schedules a wake-up for throttled hosts.
    private func pump() {
        guard started else { return }
        var nextWake: Date?
        var notesChanged = false

        for j in jobs.indices {
            let blocker = canRun(jobs[j])
            // Pages on a host waiting for a bot check hold only those pages.
            let waitingOn = jobs[j].pages?.first { !$0.done && isBlocked($0.host) }?.host
            let note = blocker ?? waitingOn.map { "Verify \($0) in the browser to continue" }
            if jobs[j].note != note && !jobs[j].isFailed {
                jobs[j].note = note
                notesChanged = true
            }
            guard blocker == nil else { continue }

            switch jobs[j].state {
            case .waiting:
                if resolving.count < maxResolving {
                    jobs[j].state = .resolving
                    resolving.insert(jobs[j].id)
                    let request = jobs[j].request
                    notesChanged = true
                    Task { await self.resolve(request) }
                }
            case .downloading:
                guard var pages = jobs[j].pages else { continue }
                for p in pages.indices where !pages[p].done && !pages[p].inFlight && !isBlocked(pages[p].host) {
                    let taskID = Self.taskID(jobs[j].id, pages[p].index)
                    if let until = retryAfter[taskID], until > now() {
                        nextWake = min(nextWake ?? until, until)
                        continue
                    }
                    switch throttle.decide(host: pages[p].host, now: now()) {
                    case .start:
                        throttle.didStart(host: pages[p].host, now: now())
                        pages[p].inFlight = true
                        let resume = try? Data(contentsOf: layout.resumeData.appendingPathComponent(DownloadLayout.safeName(taskID)))
                        transfer.start(TransferRequest(
                            taskID: taskID, url: pages[p].page.url, headers: pages[p].page.headers ?? [:],
                            allowsCellular: !settings.wifiOnly, resumeData: resume))
                    case let .wait(until):
                        nextWake = min(nextWake ?? until, until)
                    case .busy:
                        break
                    }
                }
                jobs[j].pages = pages
            case .resolving, .failed:
                continue
            }
        }
        if notesChanged { changed() }
        saveQueue()
        if let nextWake { scheduleWake(at: nextWake) }
    }

    private func scheduleWake(at date: Date) {
        if let wakeAt, wakeAt <= date, wakeTask != nil { return }
        wakeTask?.cancel()
        wakeAt = date
        let delay = max(0.01, date.timeIntervalSince(now()))
        wakeTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.woke()
        }
    }

    private func woke() {
        wakeTask = nil
        wakeAt = nil
        pump()
    }

    // MARK: - Work

    private func resolve(_ request: DownloadRequest) async {
        let result: Result<ChapterContent, Error>
        do { result = .success(try await resolver.content(for: request.ref)) } catch { result = .failure(error) }
        resolving.remove(request.ref.id)
        guard let j = jobs.firstIndex(where: { $0.id == request.ref.id }) else {
            pump()
            return
        }
        switch result {
        case let .failure(error as BrowserVerificationNeeded):
            // Not a failure: wait for the person to pass the check, then carry on.
            jobs[j].state = .waiting
            jobs[j].blockedHost = error.host
            blockedHosts.insert(error.host)
        case let .failure(error):
            jobs[j].state = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        case let .success(content):
            switch content {
            case .text, .link:
                do {
                    try write(content, for: request, bytes: nil)
                    jobs.remove(at: j)
                } catch {
                    jobs[j].state = .failed("Couldn't save: \(error.localizedDescription)")
                }
            case let .images(pages):
                if pages.isEmpty {
                    jobs[j].state = .failed("The source returned no pages.")
                } else {
                    try? FileManager.default.createDirectory(at: layout.folder(for: request.ref), withIntermediateDirectories: true)
                    jobs[j].pages = pages.enumerated().map { index, page in
                        PageTask(
                            index: index, page: page, file: DownloadLayout.pageFileName(index: index, url: page.url),
                            done: false, bytes: 0, attempts: 0, inFlight: false)
                    }
                    jobs[j].state = .downloading
                }
            }
        }
        saveQueue()
        enforceStorage()
        changed()
        pump()
    }

    private func handle(_ event: TransferEvent) {
        let taskID: String
        switch event {
        case let .finished(id, _), let .failed(id, _, _), let .blocked(id, _): taskID = id
        }
        guard let parsed = Self.parse(taskID),
              let j = jobs.firstIndex(where: { $0.id == parsed.jobID }),
              var pages = jobs[j].pages,
              let p = pages.firstIndex(where: { $0.index == parsed.index })
        else {
            if case let .finished(_, file) = event { try? FileManager.default.removeItem(at: file) }
            return
        }
        throttle.didFinish(host: pages[p].host)
        pages[p].inFlight = false

        switch event {
        case let .finished(_, file):
            let destination = layout.folder(for: jobs[j].ref).appendingPathComponent(pages[p].file)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file, to: destination)
                pages[p].done = true
                pages[p].bytes = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                try? FileManager.default.removeItem(at: layout.resumeData.appendingPathComponent(DownloadLayout.safeName(taskID)))
                retryAfter[taskID] = nil
            } catch {
                pages[p].attempts += 1
            }
        case let .blocked(_, url):
            let host = url.host?.lowercased() ?? pages[p].host
            // Only this host's pages wait; pages on other hosts carry on.
            blockedHosts.insert(host)
        case let .failed(_, message, resumeData):
            pages[p].attempts += 1
            if let resumeData {
                try? resumeData.write(to: layout.resumeData.appendingPathComponent(DownloadLayout.safeName(taskID)))
            }
            if pages[p].attempts >= maxAttempts {
                jobs[j].state = .failed(message)
            } else {
                retryAfter[taskID] = now().addingTimeInterval(pow(2, Double(pages[p].attempts)))
            }
        }
        jobs[j].pages = pages

        if pages.allSatisfy(\.done) {
            let request = jobs[j].request
            let content = ChapterContent.images(pages.map { ImagePage(url: URL(string: $0.file)!) })
            do {
                try write(content, for: request, bytes: pages.reduce(0) { $0 + $1.bytes })
                jobs.remove(at: j)
            } catch {
                jobs[j].state = .failed("Couldn't save: \(error.localizedDescription)")
            }
            enforceStorage()
        }
        saveQueue()
        changed()
        pump()
    }

    private func write(_ content: ChapterContent, for request: DownloadRequest, bytes: Int64?) throws {
        let folder = layout.folder(for: request.ref)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var info = DownloadedChapter(
            ref: request.ref, workTitle: request.workTitle, chapterTitle: request.chapterTitle,
            format: request.format, bytes: 0, downloadedAt: now(), readAt: nil)
        let data = try encode(StoredChapter(info: info, content: content))
        try data.write(to: layout.chapterFile(for: request.ref), options: .atomic)
        info.bytes = (bytes ?? 0) + Int64(data.count)
        downloaded[request.ref.id] = info
        saveIndex()
    }

    private func pauseTransfers() {
        for j in jobs.indices {
            guard var pages = jobs[j].pages else { continue }
            let ids = Set(pages.filter(\.inFlight).map { Self.taskID(jobs[j].id, $0.index) })
            if !ids.isEmpty { transfer.cancel(taskIDs: ids) }
            for p in pages.indices where pages[p].inFlight { pages[p].inFlight = false }
            jobs[j].pages = pages
        }
        throttle.reset()
        saveQueue()
    }

    private func cancelTransfers(of job: DownloadJob) {
        guard let pages = job.pages else { return }
        let ids = Set(pages.filter(\.inFlight).map { Self.taskID(job.id, $0.index) })
        if !ids.isEmpty { transfer.cancel(taskIDs: ids) }
        for page in pages where page.inFlight { throttle.didFinish(host: page.host) }
    }

    /// Removes read chapters if over the limit (when allowed), then records whether we're still over.
    private func enforceStorage() {
        let limit = settings.storageLimitBytes
        if settings.whenFull == .removeOldestRead {
            for chapter in StoragePlanner.evictions(Array(downloaded.values), limit: limit) {
                downloaded[chapter.id] = nil
                try? FileManager.default.removeItem(at: layout.folder(for: chapter.ref))
            }
            saveIndex()
        }
        let queuedBytes = jobs.reduce(Int64(0)) { $0 + ($1.pages ?? []).reduce(0) { $0 + $1.bytes } }
        overLimit = snapshot.totalBytes + queuedBytes >= limit
    }

    // MARK: - Persistence

    private func changed() {
        let s = snapshot
        for observer in observers.values { observer(s) }
    }

    private func saveQueue() {
        try? encode(jobs).write(to: layout.queueFile, options: .atomic)
    }

    private func saveIndex() {
        try? encode(Array(downloaded.values)).write(to: layout.indexFile, options: .atomic)
    }

    private func loadIndex() {
        if let list = try? decode([DownloadedChapter].self, from: layout.indexFile) {
            downloaded = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return
        }
        // No index (first launch, or it was lost): rebuild it from chapter.json files.
        guard let walker = FileManager.default.enumerator(at: layout.root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where url.lastPathComponent == "chapter.json" {
            if let stored = try? decode(StoredChapter.self, from: url) {
                var info = stored.info
                info.bytes = DownloadLayout.size(of: url.deletingLastPathComponent())
                downloaded[info.id] = info
            }
        }
        saveIndex()
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    // Task IDs carry the job and page so background events can be matched after a relaunch.
    static func taskID(_ jobID: String, _ index: Int) -> String { "\(index)|\(jobID)" }

    static func parse(_ taskID: String) -> (jobID: String, index: Int)? {
        guard let bar = taskID.firstIndex(of: "|"), let index = Int(taskID[..<bar]) else { return nil }
        return (String(taskID[taskID.index(after: bar)...]), index)
    }
}
