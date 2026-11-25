import Foundation
import ShelfCore
import XCTest
@testable import LibraryKit

final class HighlightTests: XCTestCase {
    private let key = WorkKey(sourceID: "a", workID: "1")

    private func makeRecord() -> WorkRecord {
        var r = WorkRecord(key: key, summary: WorkSummary(id: "1", title: "The Long Road", authors: ["Wren"]), format: .novel)
        r.chapters = [
            Chapter(id: "c1", title: "Chapter 1: Start", number: 1),
            Chapter(id: "c2", title: "Chapter 2: Middle", number: 2),
        ]
        return r
    }

    func testAddEditRemove() {
        var state = LibraryState()
        state[key] = makeRecord()
        let h = Highlight(chapterID: "c2", chapterTitle: "Chapter 2: Middle", exact: "the sea")
        state.addHighlight(h, to: key)
        state.addHighlight(Highlight(chapterID: "c1", chapterTitle: "Chapter 1: Start", exact: "a door"), to: key)
        XCTAssertEqual(state[key]?.sortedHighlights.map(\.exact), ["a door", "the sea"])
        state.setHighlightNote(h.id, note: "lovely", in: key)
        XCTAssertEqual(state[key]?.highlights(in: "c2").first?.note, "lovely")
        state.removeHighlight(h.id, from: key)
        XCTAssertEqual(state[key]?.highlights?.count, 1)
    }

    func testQuoteAndMarkdown() {
        var r = makeRecord()
        r.highlights = [
            Highlight(chapterID: "c1", chapterTitle: "Chapter 1: Start", exact: "First line.\n\nSecond line.", note: "Two paragraphs"),
            Highlight(chapterID: "c2", chapterTitle: "Chapter 2: Middle", exact: "Onward"),
        ]
        XCTAssertEqual(QuoteFormatter.quote(r.highlights![1], in: r), "“Onward” — The Long Road, Chapter 2: Middle (Wren)")
        let md = QuoteFormatter.markdown(r)
        XCTAssertTrue(md.hasPrefix("# The Long Road\n\n_Wren_\n"))
        XCTAssertTrue(md.contains("## Chapter 1: Start\n\n> First line. Second line.\n\nTwo paragraphs\n"))
        XCTAssertTrue(md.contains("## Chapter 2: Middle\n\n> Onward\n"))
    }

    func testOldLibraryFilesStillDecode() throws {
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(makeRecord())) as! [String: Any]
        object.removeValue(forKey: "highlights")
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(WorkRecord.self, from: data).highlights)
    }

    func testMigrationMovesHighlightsByChapterNumber() {
        var r = makeRecord()
        r.highlights = [
            Highlight(chapterID: "c2", chapterTitle: "Chapter 2: Middle", exact: "x"),
            Highlight(chapterID: "gone", chapterTitle: "Side story", exact: "y"),
        ]
        let chapters = [Chapter(id: "n1", title: "Ch. 1", number: 1), Chapter(id: "n2", title: "Ch. 2", number: 2)]
        let next = Migration.migrate(r, to: WorkKey(sourceID: "b", workID: "9"), summary: r.summary, work: nil, chapters: chapters, format: .novel)
        XCTAssertEqual(next.highlights?.map(\.chapterID), ["n2", "gone"])
        XCTAssertEqual(next.highlights?.first?.chapterTitle, "Ch. 2")
    }
}
