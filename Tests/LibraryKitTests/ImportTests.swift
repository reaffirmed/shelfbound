import Foundation
import ShelfCore
import XCTest
@testable import LibraryKit

final class ImportTests: XCTestCase {
    func testTitlesMatchAcrossSpellings() {
        XCTAssertEqual(TitleMatcher.normalize("The Beginning After the End!"), "beginning after the end")
        XCTAssertEqual(TitleMatcher.similarity("Solo Leveling", "SOLO LEVELING"), 1)
        XCTAssertEqual(TitleMatcher.similarity("Pokémon Adventures", "Pokemon Adventures"), 1)
        XCTAssertLessThan(TitleMatcher.similarity("Solo Leveling", "Solo Leveling: Ragnarok"), 0.85)

        let candidates = [
            WorkSummary(id: "1", title: "Solo Leveling: Ragnarok", authors: []),
            WorkSummary(id: "2", title: "Solo Leveling", authors: ["Chugong"]),
        ]
        XCTAssertEqual(TitleMatcher.best(for: "solo leveling", authors: ["Chugong"], among: candidates)?.id, "2")
        XCTAssertNil(TitleMatcher.best(for: "Omniscient Reader", among: candidates))
    }

    func testChapterNumbersFromTitles() {
        XCTAssertEqual(ChapterMatcher.number(of: Chapter(id: "a", title: "Chapter 12.5: The Gate")), 12.5)
        XCTAssertEqual(ChapterMatcher.number(of: Chapter(id: "b", title: "Ep. 40")), 40)
        XCTAssertEqual(ChapterMatcher.number(of: Chapter(id: "c", title: "Vol. 2 Ch. 7")), 7)
        XCTAssertEqual(ChapterMatcher.number(of: Chapter(id: "d", title: "Prologue", number: 0)), 0)
        let chapters = (1...5).map { Chapter(id: "c\($0)", title: "Chapter \($0)") }
        XCTAssertEqual(ChapterMatcher.ids(in: chapters, numbered: [1, 3]), ["c1", "c3"])
        XCTAssertEqual(ChapterMatcher.ids(in: chapters, through: 2), ["c1", "c2"])
    }

    func testAidokuBackup() throws {
        let json = """
        {"version":"0.6","date":736000000,
         "library":[{"mangaId":"m1","sourceId":"multi.mangadex","dateAdded":736000000,"categories":["Reading"]}],
         "manga":[{"id":"m1","sourceId":"multi.mangadex","title":"Hollow Tide","author":"Mara","url":"https://mangadex.org/title/m1"}],
         "chapters":[{"id":"c1","mangaId":"m1","sourceId":"multi.mangadex","chapter":1},
                     {"id":"c2","mangaId":"m1","sourceId":"multi.mangadex","chapter":2},
                     {"id":"c3","mangaId":"m1","sourceId":"multi.mangadex","chapter":3}],
         "history":[{"chapterId":"c1","mangaId":"m1","sourceId":"multi.mangadex","completed":true,"dateRead":736000100},
                    {"chapterId":"c2","mangaId":"m1","sourceId":"multi.mangadex","completed":true,"dateRead":736000200},
                    {"chapterId":"c3","mangaId":"m1","sourceId":"multi.mangadex","completed":false,"progress":4}]}
        """
        let batch = try LibraryImporter.parse(files: ["backup.aib": Data(json.utf8)])
        XCTAssertEqual(batch.origin, .aidoku)
        let work = try XCTUnwrap(batch.works.first)
        XCTAssertEqual(work.title, "Hollow Tide")
        XCTAssertEqual(work.authors, ["Mara"])
        XCTAssertEqual(work.sourceName, "multi.mangadex")
        XCTAssertEqual(work.readChapterNumbers, [1, 2])
        XCTAssertEqual(work.lastReadChapterNumber, 2)
        XCTAssertEqual(work.categories, ["Reading"])
        XCTAssertEqual(work.lastReadAt, Date(timeIntervalSinceReferenceDate: 736000200))
    }

    func testPaperbackBackup() throws {
        func data(_ s: String) -> Data { Data(s.utf8) }
        let files: [String: Data] = [
            "__LIBRARY_MANGA_V4": data(#"{"lib1":{"id":"lib1","primarySource":{"type":"__TYPE_SOURCE_MANGA","id":"sm1"},"dateBookmarked":736000000,"libraryTabs":[{"id":"t1","name":"Manhwa"}]}}"#),
            "__SOURCE_MANGA_V4": data(#"{"sm1":{"id":"sm1","sourceId":"AsuraScans","mangaId":"tbate","mangaInfo":{"id":"info1"}}}"#),
            "__MANGA_INFO_V4": data(#"{"info1":{"id":"info1","titles":["The Beginning After the End","TBATE"],"author":"TurtleMe"}}"#),
            "__CHAPTER_V4": data(#"{"ch1":{"id":"ch1","chapNum":1,"sourceManga":{"id":"sm1"}},"ch2":{"id":"ch2","chapNum":2,"sourceManga":{"id":"sm1"}}}"#),
            "__CHAPTER_PROGRESS_MARKER_V4": data(#"{"p1":{"chapter":{"id":"ch1"},"completed":true,"time":736000500},"p2":{"chapter":{"id":"ch2"},"completed":false,"lastPage":3,"time":736000900}}"#),
        ]
        let batch = try LibraryImporter.parse(files: files)
        XCTAssertEqual(batch.origin, .paperback)
        let work = try XCTUnwrap(batch.works.first)
        XCTAssertEqual(work.title, "The Beginning After the End")
        XCTAssertEqual(work.sourceName, "AsuraScans")
        XCTAssertEqual(work.readChapterNumbers, [1])
        XCTAssertEqual(work.categories, ["Manhwa"])
        XCTAssertEqual(work.lastReadAt, Date(timeIntervalSinceReferenceDate: 736000900))
    }

    func testLinksDedupeAO3Chapters() throws {
        let text = """
        Bookmarks:
        https://archiveofourown.org/works/1001
        https://archiveofourown.org/works/1001/chapters/5003, and
        <a href="https://archiveofourown.org/works/2002">Salt</a>
        https://www.novelupdates.com/series/the-quiet-cultivator/.
        """
        let batch = try LibraryImporter.parse(files: ["links.txt": Data(text.utf8)])
        XCTAssertEqual(batch.origin, .links)
        XCTAssertEqual(batch.works.map(\.url?.absoluteString), [
            "https://archiveofourown.org/works/1001",
            "https://archiveofourown.org/works/2002",
            "https://www.novelupdates.com/series/the-quiet-cultivator/",
        ])
    }

    func testUnknownFilesAreRefused() {
        XCTAssertThrowsError(try LibraryImporter.parse(files: ["x.json": Data(#"{"hello":1}"#.utf8)]))
    }
}

final class SearchMergeTests: XCTestCase {
    private func w(_ id: String, _ title: String, _ authors: [String] = []) -> WorkSummary { WorkSummary(id: id, title: title, authors: authors) }

    func testSameWorkOnSeveralSourcesShowsOnce() {
        let merged = SearchMerger.merge([
            ("a", [w("a1", "Solo Leveling", ["Chugong"]), w("a2", "Solo Leveling: Ragnarok")]),
            ("b", [w("b1", "SOLO LEVELING"), w("b2", "Hollow Tide")]),
            ("c", [w("c1", "Solo Leveling", ["Someone Else"])]),
        ])
        XCTAssertEqual(merged.map(\.primary.work.id), ["a1", "c1", "a2", "b2"])
        XCTAssertEqual(merged[0].others.map(\.work.id), ["b1"], "different author stays separate")
    }

    func testPreferredSourceOpensFirst() {
        let merged = SearchMerger.merge([("a", [w("a1", "Hollow Tide")]), ("b", [w("b1", "Hollow Tide")])], preferred: ["b"])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].primary.sourceID, "b")
        XCTAssertEqual(merged[0].others.map(\.sourceID), ["a"])
    }

    func testTwoResultsFromOneSourceNeverMerge() {
        let merged = SearchMerger.merge([("a", [w("a1", "Tea"), w("a2", "Tea")])])
        XCTAssertEqual(merged.count, 2)
    }
}

final class MigrationTests: XCTestCase {
    func testKeepsReadChaptersPositionSettingsAndGlossary() {
        let oldKey = WorkKey(sourceID: "old", workID: "w")
        var record = WorkRecord(key: oldKey, summary: WorkSummary(id: "w", title: "Hollow Tide", authors: []), format: .manhwa)
        record.chapters = (1...5).map { Chapter(id: "o\($0)", title: "Chapter \($0)") }
        record.inLibrary = true
        record.readChapterIDs = ["o1", "o2", "o3"]
        record.position = ReadingPosition(chapterID: "o4", chapterTitle: "Chapter 4", progress: 0.4)
        record.settings.readingMode = .pagedLeftToRight
        record.settings.preferredGroup = "Old Scans"
        record.glossary = [GlossaryEntry(term: "Lin", note: "the hero")]

        let newChapters = [Chapter(id: "n1", title: "Ep. 1"), Chapter(id: "n2", title: "Ep. 2"), Chapter(id: "n4", title: "Ep. 4"), Chapter(id: "n6", title: "Ep. 6")]
        let preview = Migration.preview(record, onto: newChapters)
        XCTAssertEqual(preview.matchedRead, 2)
        XCTAssertEqual(preview.totalRead, 3)
        XCTAssertEqual(preview.position?.id, "n4")

        let newKey = WorkKey(sourceID: "new", workID: "x")
        let next = Migration.migrate(record, to: newKey, summary: WorkSummary(id: "x", title: "Hollow Tide", authors: []), work: nil, chapters: newChapters, format: .manhwa)
        XCTAssertEqual(next.key, newKey)
        XCTAssertTrue(next.inLibrary)
        XCTAssertEqual(next.readChapterIDs, ["n1", "n2"])
        XCTAssertEqual(next.position?.chapterID, "n4")
        XCTAssertEqual(next.position?.progress, 0.4)
        XCTAssertEqual(next.settings.readingMode, .pagedLeftToRight)
        XCTAssertNil(next.settings.preferredGroup)
        XCTAssertEqual(next.glossary.map(\.term), ["Lin"])

        var state = LibraryState()
        state[oldKey] = record
        state.replace(oldKey, with: next)
        XCTAssertNil(state[oldKey])
        XCTAssertEqual(state[newKey]?.readChapterIDs.count, 2)
    }
}
