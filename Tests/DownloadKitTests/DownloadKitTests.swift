import Foundation
import ShelfCore
import XCTest
@testable import DownloadKit

private final class FakeTransfer: FileTransfer, @unchecked Sendable {
    let lock = NSLock()
    var handler: (@Sendable (TransferEvent) -> Void)?
    var started: [TransferRequest] = []
    var cancelled: Set<String> = []
    let scratch: URL

    init(scratch: URL) { self.scratch = scratch }

    func setEventHandler(_ handler: @escaping @Sendable (TransferEvent) -> Void) { self.handler = handler }
    func start(_ request: TransferRequest) { lock.lock(); started.append(request); lock.unlock() }
    func cancel(taskIDs: Set<String>) { lock.lock(); cancelled.formUnion(taskIDs); lock.unlock() }
    func runningTaskIDs() async -> Set<String> { [] }

    var startedIDs: [String] { lock.lock(); defer { lock.unlock() }; return started.map(\.taskID) }

    func finish(_ taskID: String, bytes: Int = 1000) {
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try! Data(repeating: 7, count: bytes).write(to: file)
        handler?(.finished(taskID: taskID, file: file))
    }

    func block(_ taskID: String, host: String) {
        handler?(.blocked(taskID: taskID, url: URL(string: "https://\(host)/x.jpg")!))
    }

    func fail(_ taskID: String) {
        handler?(.failed(taskID: taskID, message: "boom", resumeData: Data("partial".utf8)))
    }
}

/// The source site's bot check, passed when `verified` is set.
private final class FakeCheck: @unchecked Sendable {
    var verified = false
}

private struct FakeResolver: ChapterResolver {
    var pages: Int
    var check = FakeCheck()
    func content(for ref: ChapterRef) async throws -> ChapterContent {
        if ref.chapterID.hasPrefix("checked"), !check.verified {
            throw BrowserVerificationNeeded(url: URL(string: "https://site.example.org/\(ref.chapterID)")!)
        }
        if ref.chapterID.hasPrefix("text") || ref.chapterID.hasPrefix("checked") { return .text(html: "<p>Hello</p>", notesBefore: nil, notesAfter: nil) }
        return .images((0..<pages).map { ImagePage(url: URL(string: "https://img\($0 % 2).example.org/\(ref.chapterID)/\($0).jpg")!) })
    }
}

private final class FakeNetwork: NetworkConditions, @unchecked Sendable {
    var current: NetworkKind = .wifi
}

private let work = WorkKey(sourceID: "org.example.manga", workID: "series/42")

private func request(_ chapter: String, format: WorkFormat = .manhwa) -> DownloadRequest {
    DownloadRequest(ref: ChapterRef(work: work, chapterID: chapter), workTitle: "Hollow Tide", chapterTitle: chapter, format: format)
}

final class DownloadKitTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dl-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func waitUntil(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out", file: file, line: line)
    }

    private func makeManager(
        pages: Int = 3, network: FakeNetwork = FakeNetwork(), settings: DownloadSettings = DownloadSettings(),
        throttle: HostThrottle = HostThrottle(maxPerHost: 1, minInterval: 0, maxTotal: 6), check: FakeCheck = FakeCheck()
    ) -> (DownloadManager, FakeTransfer) {
        let transfer = FakeTransfer(scratch: root)
        let manager = DownloadManager(
            layout: DownloadLayout(root: root.appendingPathComponent("Downloads")), resolver: FakeResolver(pages: pages, check: check),
            transfer: transfer, network: network, settings: settings, throttle: throttle)
        return (manager, transfer)
    }

    func testImageChapterDownloadsPageByPageWithinHostLimits() async throws {
        let (manager, transfer) = makeManager(pages: 4)
        await manager.start()
        await manager.enqueue([request("c1")])

        // Two hosts, one transfer each at a time.
        await waitUntil { transfer.startedIDs.count == 2 }
        XCTAssertEqual(Set(transfer.started.map { $0.url.host! }), ["img0.example.org", "img1.example.org"])

        transfer.finish(transfer.startedIDs[0])
        transfer.finish(transfer.startedIDs[1])
        await waitUntil { transfer.startedIDs.count == 4 }
        transfer.finish(transfer.startedIDs[2])
        transfer.finish(transfer.startedIDs[3])

        let ref = ChapterRef(work: work, chapterID: "c1")
        await waitUntil { await manager.isDownloaded(ref) }
        guard case let .images(pages)? = await manager.localContent(for: ref) else { return XCTFail("No content") }
        XCTAssertEqual(pages.count, 4)
        XCTAssertTrue(pages[0].url.isFileURL)
        XCTAssertEqual(pages[0].url.lastPathComponent, "0001.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pages[3].url.path))
        let snapshot = await manager.snapshot
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertGreaterThan(snapshot.totalBytes, 4000)
    }

    func testTextChapterIsSavedDirectly() async throws {
        let (manager, _) = makeManager()
        await manager.start()
        await manager.enqueue([request("text-1", format: .fic)])
        let ref = ChapterRef(work: work, chapterID: "text-1")
        await waitUntil { await manager.isDownloaded(ref) }
        let content = await manager.localContent(for: ref)
        XCTAssertEqual(content, .text(html: "<p>Hello</p>", notesBefore: nil, notesAfter: nil))
    }

    func testWifiOnlyHoldsImagesButLetsFicsThroughOnCellular() async throws {
        let network = FakeNetwork()
        network.current = .cellular
        let (manager, transfer) = makeManager(network: network)
        await manager.start()
        await manager.enqueue([request("c1"), request("text-1", format: .fic)])

        await waitUntil { await manager.isDownloaded(ChapterRef(work: work, chapterID: "text-1")) }
        let job = await manager.snapshot.jobs.first
        XCTAssertEqual(job?.note, "Waiting for Wi-Fi")
        XCTAssertTrue(transfer.startedIDs.isEmpty)

        network.current = .wifi
        await manager.networkChanged()
        await waitUntil { !transfer.startedIDs.isEmpty }
    }

    func testBotCheckOnPagesPausesThatHostUntilVerified() async throws {
        let (manager, transfer) = makeManager(pages: 4)
        await manager.start()
        await manager.enqueue([request("c1")])
        await waitUntil { transfer.startedIDs.count == 2 }
        let img0 = transfer.started.first { $0.url.host == "img0.example.org" }!.taskID
        let img1 = transfer.started.first { $0.url.host == "img1.example.org" }!.taskID
        transfer.block(img0, host: "img0.example.org")
        transfer.finish(img1)

        // img1 carries on; img0 waits, and the job isn't failed.
        await waitUntil { transfer.startedIDs.count == 3 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transfer.started.filter { $0.url.host == "img0.example.org" }.count, 1)
        var snapshot = await manager.snapshot
        XCTAssertEqual(snapshot.blockedHosts, ["img0.example.org"])
        XCTAssertFalse(snapshot.jobs[0].isFailed)

        await manager.unblock(host: "example.org")
        await waitUntil { transfer.started.filter { $0.url.host == "img0.example.org" }.count == 2 }
        snapshot = await manager.snapshot
        XCTAssertEqual(snapshot.blockedHosts, [])
    }

    func testBotCheckOnTheSourceHoldsTheChapterInsteadOfFailing() async throws {
        let check = FakeCheck()
        let (manager, _) = makeManager(check: check)
        await manager.start()
        await manager.enqueue([request("checked-1", format: .fic)])
        await waitUntil { await manager.snapshot.blockedHosts == ["site.example.org"] }
        let job = await manager.snapshot.jobs.first
        XCTAssertEqual(job?.blockedHost, "site.example.org")
        XCTAssertEqual(job?.isFailed, false)

        check.verified = true
        await manager.unblock(host: "site.example.org")
        await waitUntil { await manager.isDownloaded(ChapterRef(work: work, chapterID: "checked-1")) }
    }

    func testFailedPageRetriesWithResumeData() async throws {
        let (manager, transfer) = makeManager(pages: 1)
        await manager.start()
        await manager.enqueue([request("c1")])
        await waitUntil { transfer.startedIDs.count == 1 }
        transfer.fail(transfer.startedIDs[0])
        // Backoff is 2 s after the first failure.
        await waitUntil({ transfer.startedIDs.count == 2 })
        XCTAssertEqual(transfer.started[1].resumeData, Data("partial".utf8))
        XCTAssertEqual(transfer.started[0].taskID, transfer.started[1].taskID)
    }

    func testQueueSurvivesRestart() async throws {
        let (first, transfer) = makeManager(network: { let n = FakeNetwork(); n.current = .offline; return n }())
        await first.start()
        await first.enqueue([request("c1"), request("c2")])
        XCTAssertTrue(transfer.startedIDs.isEmpty)

        let (second, _) = makeManager()
        await second.start()
        let ids = await second.snapshot.jobs.map(\.ref.chapterID)
        XCTAssertEqual(ids, ["c1", "c2"])
    }

    func testRemoveAfterReadingAndStorageEviction() async throws {
        var settings = DownloadSettings()
        settings.removeAfterReading = true
        let (manager, _) = makeManager(settings: settings)
        await manager.start()
        await manager.enqueue([request("text-1", format: .fic)])
        let ref = ChapterRef(work: work, chapterID: "text-1")
        await waitUntil { await manager.isDownloaded(ref) }
        await manager.markRead(ref)
        let kept = await manager.isDownloaded(ref)
        XCTAssertTrue(kept, "Text chapters are kept after reading")

        let old = DownloadedChapter(ref: ChapterRef(work: work, chapterID: "a"), workTitle: "", chapterTitle: "", format: .manga, bytes: 600, downloadedAt: Date(), readAt: Date(timeIntervalSince1970: 1))
        let newer = DownloadedChapter(ref: ChapterRef(work: work, chapterID: "b"), workTitle: "", chapterTitle: "", format: .manga, bytes: 600, downloadedAt: Date(), readAt: Date(timeIntervalSince1970: 2))
        let unread = DownloadedChapter(ref: ChapterRef(work: work, chapterID: "c"), workTitle: "", chapterTitle: "", format: .manga, bytes: 600, downloadedAt: Date(), readAt: nil)
        let fic = DownloadedChapter(ref: ChapterRef(work: work, chapterID: "d"), workTitle: "", chapterTitle: "", format: .fic, bytes: 600, downloadedAt: Date(), readAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(StoragePlanner.evictions([newer, unread, old, fic], limit: 1500).map(\.ref.chapterID), ["a", "b"])
        XCTAssertEqual(StoragePlanner.evictions([newer, unread], limit: 1500), [])
    }

    func testThrottleSpacesStartsPerHost() {
        var throttle = HostThrottle(maxPerHost: 2, minInterval: 1, maxTotal: 3)
        let t0 = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(throttle.decide(host: "a", now: t0), .start)
        throttle.didStart(host: "a", now: t0)
        XCTAssertEqual(throttle.decide(host: "a", now: t0.addingTimeInterval(0.5)), .wait(t0.addingTimeInterval(1)))
        throttle.didStart(host: "a", now: t0.addingTimeInterval(1))
        XCTAssertEqual(throttle.decide(host: "a", now: t0.addingTimeInterval(5)), .busy)
        XCTAssertEqual(throttle.decide(host: "b", now: t0.addingTimeInterval(5)), .start)
        throttle.didFinish(host: "a")
        XCTAssertEqual(throttle.decide(host: "a", now: t0.addingTimeInterval(5)), .start)
    }

    func testSafeNamesNeverCollideOrEscape() {
        XCTAssertEqual(DownloadLayout.safeName("chapter-12"), "chapter-12")
        let a = DownloadLayout.safeName("../../etc")
        XCTAssertFalse(a.contains("/"))
        XCTAssertFalse(a.hasPrefix("."))
        XCTAssertNotEqual(DownloadLayout.safeName("a/b"), DownloadLayout.safeName("a_b"))
        XCTAssertNotEqual(DownloadLayout.safeName("series/42"), DownloadLayout.safeName("series42"))
    }
}
