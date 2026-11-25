import Foundation
import XCTest
@testable import SourceKit

final class ReaderModeTests: XCTestCase {
    func testKeepsTheChapterAndDropsTheRest() throws {
        let html = """
        <html><head><title>Ch 3 | Some Translations</title><script>alert(1)</script></head><body>
        <nav><a href="/">Home</a> <a href="/novels">Novels</a></nav>
        <div class="sidebar"><p>Popular posts, other stuff, and so on and so on.</p></div>
        <div class="entry-content">
          <h1>Chapter 3: The Pavilion</h1>
          <p>Lin Feng stepped into the pavilion, and the elders fell silent.</p>
          <p onclick="steal()">"Junior brother," said the eldest, "you are late."</p>
          <p><img src="/art/map.jpg"> <em>Map of the sect</em></p>
          <div class="comments"><p>Thanks for the chapter, translator!</p></div>
        </div>
        <footer>© Some Translations</footer>
        </body></html>
        """
        let article = try ReaderMode.extract(html: html, url: URL(string: "https://translator.example.org/ch-3/")!)
        XCTAssertEqual(article.title, "Chapter 3: The Pavilion")
        XCTAssertTrue(article.html.contains("Lin Feng stepped into the pavilion"))
        XCTAssertTrue(article.html.contains("<img src=\"https://translator.example.org/art/map.jpg\">"))
        XCTAssertFalse(article.html.contains("onclick"))
        XCTAssertFalse(article.html.contains("Thanks for the chapter"))
        XCTAssertFalse(article.html.contains("Popular posts"))
        XCTAssertFalse(article.html.contains("alert"))
    }
}

final class SourceDatesTests: XCTestCase {
    func testAcceptsJavaScriptAndPlainDates() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(SourceDates.decode)
        let dates = try decoder.decode([Date].self, from: Data(#"["2024-05-01T10:00:00Z","2024-05-01T10:00:00.250Z","2024-05-01",1714557600000]"#.utf8))
        XCTAssertEqual(dates[0].timeIntervalSince1970, 1_714_557_600)
        XCTAssertEqual(dates[1].timeIntervalSince1970, 1_714_557_600.25, accuracy: 0.001)
        XCTAssertEqual(dates[2].timeIntervalSince1970, 1_714_521_600)
        XCTAssertEqual(dates[3], dates[0])
    }
}
