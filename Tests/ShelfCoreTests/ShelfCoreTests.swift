import XCTest
@testable import ShelfCore

final class ShelfCoreTests: XCTestCase {
    func testDomainPolicy() {
        let policy = DomainPolicy(patterns: ["example.org", "*.cdn.example.net"])
        XCTAssertTrue(policy.allows(URL(string: "https://example.org/works/1")!))
        XCTAssertFalse(policy.allows(URL(string: "https://evil-example.org/")!))
        XCTAssertTrue(policy.allows(URL(string: "https://img.cdn.example.net/a.png")!))
        XCTAssertTrue(policy.allows(URL(string: "https://cdn.example.net/a.png")!))
        XCTAssertFalse(policy.allows(URL(string: "file:///etc/passwd")!))
    }

    func testChapterContentRoundTrip() throws {
        let content = ChapterContent.text(html: "<p>Hi</p>", notesBefore: "n", notesAfter: nil)
        let data = try JSONEncoder().encode(content)
        XCTAssertEqual(try JSONDecoder().decode(ChapterContent.self, from: data), content)
    }

    func testReaderDocumentEscapesTitleAndBlocksScripts() {
        let html = ReaderDocument.html(title: "<script>", body: "<p>x</p>", style: ReaderStyle())
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("default-src 'none'"))
    }

    func testRatingOrder() {
        XCTAssertTrue(ContentRating.safe < .explicit)
    }
}
