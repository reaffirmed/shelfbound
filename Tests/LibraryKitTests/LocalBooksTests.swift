import Foundation
import ShelfCore
import XCTest
@testable import LibraryKit

final class LocalBooksTests: XCTestCase {
    func testFileKinds() {
        XCTAssertEqual(LocalBooks.Kind(filename: "Book.EPUB"), .epub)
        XCTAssertEqual(LocalBooks.Kind(filename: "scan.pdf"), .pdf)
        XCTAssertEqual(LocalBooks.Kind(filename: "Vol 01.cbz"), .cbz)
        XCTAssertNil(LocalBooks.Kind(filename: "notes.txt"))
        XCTAssertEqual(LocalBooks.title(fromFilename: "the_lantern_cycle.epub"), "the lantern cycle")
    }

    func testContainerAndPackage() throws {
        let container = Data("""
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8)
        XCTAssertEqual(EPUB.packagePath(container: container), "OEBPS/content.opf")

        let opf = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>The Lantern Cycle</dc:title>
            <dc:creator>R. Vale</dc:creator>
            <dc:creator>M. Oke</dc:creator>
            <dc:language>en</dc:language>
            <dc:description>A &lt;b&gt;quiet&lt;/b&gt; book.</dc:description>
            <meta name="calibre:series" content="Lanterns"/>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="cover" href="images/cover%20art.jpg" media-type="image/jpeg" properties="cover-image"/>
            <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1b" href="text/ch1b.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine page-progression-direction="ltr">
            <itemref idref="c1"/><itemref idref="c1b"/><itemref idref="c2"/><itemref idref="notes" linear="no"/>
          </spine>
        </package>
        """.utf8)
        let package = try XCTUnwrap(EPUB.package(opf, at: "OEBPS/content.opf"))
        XCTAssertEqual(package.title, "The Lantern Cycle")
        XCTAssertEqual(package.creators, ["R. Vale", "M. Oke"])
        XCTAssertEqual(package.language, "en")
        XCTAssertEqual(package.series, "Lanterns")
        XCTAssertEqual(package.coverPath, "OEBPS/images/cover art.jpg")
        XCTAssertEqual(package.navPath, "OEBPS/nav.xhtml")
        XCTAssertEqual(package.spine.map(\.path), ["OEBPS/text/ch1.xhtml", "OEBPS/text/ch1b.xhtml", "OEBPS/text/ch2.xhtml"])

        let nav = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="text/ch1.xhtml">One: <i>Embers</i></a></li>
            <li><a href="text/ch2.xhtml#start">Two</a></li>
          </ol></nav>
        </body></html>
        """.utf8)
        let titles = EPUB.tocTitles(nav: nav, navPath: package.navPath, ncx: nil, ncxPath: nil)
        XCTAssertEqual(titles["OEBPS/text/ch1.xhtml"], "One: Embers")
        XCTAssertEqual(titles["OEBPS/text/ch2.xhtml"], "Two")

        let chapters = EPUB.chapters(spine: package.spine, titles: titles)
        XCTAssertEqual(chapters.map(\.title), ["One: Embers", "Two"])
        XCTAssertEqual(chapters[0].paths, ["OEBPS/text/ch1.xhtml", "OEBPS/text/ch1b.xhtml"])
    }

    func testEPUB2CoverAndNCX() throws {
        let opf = Data("""
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:title>Old Book</dc:title><meta name="cover" content="img1"/>
          </metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="img1" href="cover.png" media-type="image/png"/>
            <item id="a" href="a.html" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx"><itemref idref="a"/></spine>
        </package>
        """.utf8)
        let package = try XCTUnwrap(EPUB.package(opf, at: "content.opf"))
        XCTAssertEqual(package.coverPath, "cover.png")
        XCTAssertEqual(package.ncxPath, "toc.ncx")
        let ncx = Data("""
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
          <navPoint id="p1"><navLabel><text>Chapter One</text></navLabel><content src="a.html"/></navPoint>
        </navMap></ncx>
        """.utf8)
        XCTAssertEqual(EPUB.tocTitles(nav: nil, navPath: nil, ncx: ncx, ncxPath: "toc.ncx"), ["a.html": "Chapter One"])
    }

    func testNoTableOfContentsMeansOneChapterPerFile() {
        let spine = ["a.xhtml", "b.xhtml"].map { EPUB.Item(id: $0, path: $0, mediaType: "", properties: []) }
        XCTAssertEqual(EPUB.chapters(spine: spine, titles: [:]).map(\.title), ["Part 1", "Part 2"])
    }

    func testBodyAndImages() {
        let xhtml = """
        <?xml version="1.0"?><html><head><title>x</title></head>
        <body class="c"><p>Hi</p><script>alert(1)</script><img src="../images/a.png" alt=""/>
        <svg><image xlink:href='../images/b.jpg'/></svg></body></html>
        """
        let body = EPUB.body(of: xhtml)
        XCTAssertFalse(body.contains("script"))
        XCTAssertTrue(body.hasPrefix("<p>Hi</p>"))
        XCTAssertEqual(EPUB.imageReferences(in: body), ["../images/a.png", "../images/b.jpg"])
        let rewritten = EPUB.rewriteImages(in: body) { ref in
            EPUB.resolve(ref, from: "OEBPS/text/c.xhtml") == "OEBPS/images/a.png" ? "data:image/png;base64,AA==" : nil
        }
        XCTAssertTrue(rewritten.contains("src=\"data:image/png;base64,AA==\""))
        XCTAssertTrue(rewritten.contains("'../images/b.jpg'"))
    }

    func testResolve() {
        XCTAssertEqual(EPUB.resolve("../img/a%20b.png#x", from: "OEBPS/text/c.xhtml"), "OEBPS/img/a b.png")
        XCTAssertEqual(EPUB.resolve("c.xhtml", from: "content.opf"), "c.xhtml")
        XCTAssertEqual(EPUB.resolve("#note", from: "a/b.xhtml"), "a/b.xhtml")
    }

    func testComicChapters() {
        let flat = ComicArchive.chapters(from: ["p10.jpg", "p2.jpg", "p1.jpg", "ComicInfo.xml", "__MACOSX/._p1.jpg", ".hidden/x.png"])
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(flat[0].pages, ["p1.jpg", "p2.jpg", "p10.jpg"])

        let nested = ComicArchive.chapters(from: ["Vol 1/Ch_10/1.png", "Vol 1/Ch_2/1.png", "Vol 1/Ch_2/2.png"])
        XCTAssertEqual(nested.map(\.title), ["Ch 2", "Ch 10"])
        XCTAssertEqual(nested[0].pages, ["Vol 1/Ch_2/1.png", "Vol 1/Ch_2/2.png"])
    }

    func testComicInfoAndFormat() throws {
        let info = try XCTUnwrap(ComicArchive.info(Data("""
        <?xml version="1.0"?><ComicInfo><Title>Gate</Title><Series>Hollow Tide</Series>
        <Writer>A, B</Writer><Manga>YesAndRightToLeft</Manga></ComicInfo>
        """.utf8)))
        XCTAssertEqual(info.title, "Gate")
        XCTAssertEqual(info.series, "Hollow Tide")
        XCTAssertEqual(info.writers, ["A", "B"])
        XCTAssertTrue(info.rightToLeft)
        XCTAssertEqual(ComicArchive.format(rightToLeft: true, medianAspect: 1.4), .manga)
        XCTAssertEqual(ComicArchive.format(rightToLeft: false, medianAspect: 3.5), .manhwa)
        XCTAssertEqual(ComicArchive.format(rightToLeft: false, medianAspect: 1.5), .comic)
    }

    func testStoredBookResolvesPathsAgainstItsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("<p>Hello</p>".utf8).write(to: folder.appendingPathComponent("p0.html"))

        var book = LocalBook(id: "b1", kind: .epub, format: .novel, title: "T", originalFilename: "t.epub")
        book.coverFile = "cover.jpg"
        book.parts = [.init(id: "p0", title: "One", file: "p0.html"), .init(id: "p1", title: "Pics", pages: ["pages/1.jpg"])]
        XCTAssertEqual(book.key.sourceID, LocalBooks.sourceID)
        XCTAssertEqual(book.chapters.map(\.id), ["p0", "p1"])
        XCTAssertEqual(book.summary(in: folder).coverURL, folder.appendingPathComponent("cover.jpg"))
        XCTAssertEqual(try book.content(of: "p0", in: folder), .text(html: "<p>Hello</p>", notesBefore: nil, notesAfter: nil))
        XCTAssertEqual(try book.content(of: "p1", in: folder), .images([ImagePage(url: folder.appendingPathComponent("pages/1.jpg"))]))

        let decoded = try JSONDecoder().decode(LocalBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(decoded, book)
    }
}
