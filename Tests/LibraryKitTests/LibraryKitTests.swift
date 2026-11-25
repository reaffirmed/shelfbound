import Foundation
import ShelfCore
import XCTest
@testable import LibraryKit

private func chapters(_ n: Int, prefix: String = "c") -> [Chapter] {
    (1...n).map { Chapter(id: "\(prefix)\($0)", title: "Chapter \($0)", number: Double($0)) }
}

private func record(_ id: String, format: WorkFormat, fandom: String? = nil, inLibrary: Bool = true) -> WorkRecord {
    var r = WorkRecord(
        key: WorkKey(sourceID: "src", workID: id),
        summary: WorkSummary(id: id, title: id.capitalized, fandoms: fandom.map { [$0] }),
        format: format)
    r.inLibrary = inLibrary
    return r
}

final class LibraryKitTests: XCTestCase {
    func testGroupsByFandomWithSeriesAsTheirOwnFandom() {
        let records = [
            record("orbit", format: .fic, fandom: "Starfall Academy (Anime)"),
            record("starfall academy", format: .manga),
            record("crown", format: .fic, fandom: "The Gilded Court - Mara Venn"),
            record("ink", format: .fic, fandom: "The Gilded Court"),
            record("hidden", format: .fic, fandom: "Nope", inLibrary: false),
            record("loose", format: .fic),
        ]
        let sections = LibraryLayout.sections(records, filter: .all, grouping: .fandom, sort: .title)
        XCTAssertEqual(sections.map(\.title), ["Starfall Academy", "The Gilded Court", "Other"])
        XCTAssertEqual(sections[0].subtitle, "1 fic, 1 manga")
        XCTAssertEqual(sections[1].records.map(\.key.workID), ["crown", "ink"])

        let manga = LibraryLayout.sections(records, filter: .manga, grouping: .fandom, sort: .title)
        XCTAssertEqual(manga.map(\.title), ["Starfall Academy"])
    }

    func testFirstFetchMarksNothingNewThenNewChaptersAreBadged() {
        var r = record("hollow", format: .manhwa)
        XCTAssertEqual(UpdateChecker.apply(chapters(3), to: &r), [])
        XCTAssertEqual(r.unreadNewCount, 0)

        let new = UpdateChecker.apply(chapters(5), to: &r)
        XCTAssertEqual(new.map(\.id), ["c4", "c5"])
        XCTAssertEqual(r.unreadNewCount, 2)

        var state = LibraryState(records: [r.id: r])
        state.markRead("c4", in: r.key)
        XCTAssertEqual(state[r.key]?.unreadNewCount, 1)
        XCTAssertEqual(state.newChapterCount, 1)
    }

    func testContinueChapterMovesOnWhenFinished() {
        var r = record("a", format: .manga)
        r.chapters = chapters(4)
        XCTAssertEqual(r.continueChapter?.id, "c1")
        r.position = ReadingPosition(chapterID: "c2", chapterTitle: "Chapter 2", progress: 0.5)
        XCTAssertEqual(r.continueChapter?.id, "c2")
        r.position?.progress = 1
        r.readChapterIDs = ["c1", "c2"]
        XCTAssertEqual(r.continueChapter?.id, "c3")
        XCTAssertEqual(r.upcomingUnread(5).map(\.id), ["c3", "c4"])
    }

    func testReadingOrderSortsAndPicksPreferredGroup() {
        let list = [
            Chapter(id: "b2", title: "2", number: 2, group: "Bamboo"),
            Chapter(id: "a1", title: "1", number: 1, group: "Azure"),
            Chapter(id: "a2", title: "2", number: 2, group: "Azure"),
            Chapter(id: "b3", title: "3", number: 3, group: "Bamboo"),
        ]
        XCTAssertEqual(ChapterOrder.readingOrder(list, preferredGroup: nil).map(\.id), ["a1", "b2", "b3"])
        XCTAssertEqual(ChapterOrder.readingOrder(list, preferredGroup: "Azure").map(\.id), ["a1", "a2", "b3"])
        XCTAssertEqual(ChapterOrder.groups(list), ["Azure", "Bamboo"])
    }

    func testUpdateCheckRunsAcrossSourcesAndReportsFailures() async {
        var a = record("a", format: .manga)
        a.chapters = chapters(1)
        var b = WorkRecord(key: WorkKey(sourceID: "other", workID: "b"), summary: WorkSummary(id: "b", title: "B"), format: .fic)
        b.inLibrary = true
        b.chapters = chapters(1)
        let state = LibraryState(records: [a.id: a, b.id: b])

        let (next, report) = await UpdateChecker.check(state) { key in
            if key.sourceID == "other" { throw URLError(.timedOut) }
            return chapters(2)
        }
        XCTAssertEqual(report.checked, 2)
        XCTAssertEqual(report.newChapterCount, 1)
        XCTAssertNotNil(report.failures[b.key])
        XCTAssertEqual(next[a.key]?.newChapterIDs, ["c2"])
        XCTAssertNotNil(next.lastUpdateCheck)
        XCTAssertEqual(UpdateChecker.notificationText(report)?.title, "A")
    }

    func testStateRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var state = LibraryState()
        state.upsert(key: WorkKey(sourceID: "s", workID: "w"), summary: WorkSummary(id: "w", title: "W"), chapters: chapters(2), format: .fic)
        state.setInLibrary(WorkKey(sourceID: "s", workID: "w"), true)
        state.savePosition(ReadingPosition(chapterID: "c1", chapterTitle: "Chapter 1", progress: 0.3), for: WorkKey(sourceID: "s", workID: "w"))
        let file = LibraryFile(url: url)
        try file.save(state)
        let loaded = file.load()
        XCTAssertEqual(loaded.library.count, 1)
        XCTAssertEqual(loaded.library.first?.position?.chapterID, "c1")
        XCTAssertEqual(loaded.history.count, 1)
    }
}

final class UpdateAlertTests: XCTestCase {
    private func found(_ id: String, _ count: Int) -> UpdateReport.Found {
        UpdateReport.Found(key: WorkKey(sourceID: "s", workID: id), title: "Work \(id)",
                           newChapters: (1...count).map { Chapter(id: "\(id)-\($0)", title: "Chapter \($0)", number: Double($0)) })
    }

    func testOneAlertPerWork() {
        var report = UpdateReport()
        report.found = [found("a", 1), found("b", 3)]
        let alerts = UpdateChecker.alerts(report)
        XCTAssertEqual(alerts.map(\.title), ["Work a", "Work b"])
        XCTAssertEqual(alerts[0].body, "Chapter 1")
        XCTAssertEqual(alerts[1].body, "3 new chapters, up to Chapter 3")
        XCTAssertEqual(alerts[1].chapterIDs, ["b-1", "b-2", "b-3"])
        XCTAssertEqual(alerts[1].thread, "work-s/b")
        XCTAssertNotEqual(alerts[0].id, alerts[1].id)
    }

    func testSummaryWhenMany() {
        var report = UpdateReport()
        report.found = (1...6).map { found("w\($0)", 1) }
        let alerts = UpdateChecker.alerts(report)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertNil(alerts[0].key)
        XCTAssertEqual(alerts[0].title, "6 new chapters")
    }
}
