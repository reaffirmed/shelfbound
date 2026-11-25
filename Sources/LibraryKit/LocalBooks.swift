import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ShelfCore

/// Books and comics the person imports from their own files: EPUB, PDF and CBZ.
/// They live in the library like any other work, under a built-in source that needs
/// no repo and no network. This file holds the parts that don't need UIKit or a zip
/// reader, so they can be tested on their own; the app does the unzipping and rendering.
public enum LocalBooks {
    /// The `WorkKey.sourceID` of imported files. Not a valid repo source ID, so it can't clash.
    public static let sourceID = "shelfbound.files"
    /// What the library shows as the "source" of an imported file.
    public static let sourceName = "Your files"

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case epub, pdf, cbz

        public init?(filename: String) {
            switch (filename as NSString).pathExtension.lowercased() {
            case "epub": self = .epub
            case "pdf": self = .pdf
            case "cbz", "zip": self = .cbz
            default: return nil
            }
        }

        public var label: String {
            switch self {
            case .epub: "EPUB"
            case .pdf: "PDF"
            case .cbz: "CBZ"
            }
        }
    }

    public static func isLocal(_ key: WorkKey) -> Bool { key.sourceID == sourceID }

    /// A title from a file name: "the_lantern_cycle-v01.epub" becomes "the lantern cycle-v01".
    public static func title(fromFilename name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let spaced = base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return spaced.isEmpty ? "Untitled" : spaced
    }

    /// Orders "page2" before "page10", the way Finder and Files do.
    public static func naturalLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }
}

/// What the app stores next to an imported file's extracted parts, as `book.json`.
/// Paths are relative to the book's folder, because the app's container moves when
/// iOS updates the app.
public struct LocalBook: Codable, Sendable, Hashable, Identifiable {
    public struct Part: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        /// Text parts: one HTML file with the chapter body, images inlined.
        public var file: String?
        /// Image parts: page images in reading order.
        public var pages: [String]?

        public init(id: String, title: String, file: String? = nil, pages: [String]? = nil) {
            self.id = id
            self.title = title
            self.file = file
            self.pages = pages
        }
    }

    public var id: String
    public var kind: LocalBooks.Kind
    public var format: WorkFormat
    public var title: String
    public var authors: [String]
    public var language: String?
    public var summary: String?
    public var series: String?
    public var coverFile: String?
    public var originalFilename: String
    public var importedAt: Date
    public var parts: [Part]

    public init(
        id: String, kind: LocalBooks.Kind, format: WorkFormat, title: String, authors: [String] = [],
        originalFilename: String, importedAt: Date = Date(), parts: [Part] = []
    ) {
        self.id = id
        self.kind = kind
        self.format = format
        self.title = title
        self.authors = authors
        self.originalFilename = originalFilename
        self.importedAt = importedAt
        self.parts = parts
    }

    public var key: WorkKey { WorkKey(sourceID: LocalBooks.sourceID, workID: id) }

    public var chapters: [Chapter] {
        parts.enumerated().map { Chapter(id: $1.id, title: $1.title, number: Double($0 + 1)) }
    }

    /// The library card, with the cover resolved against where the book lives now.
    public func summary(in folder: URL) -> WorkSummary {
        var s = WorkSummary(
            id: id, title: title, authors: authors, coverURL: coverFile.map { folder.appendingPathComponent($0) },
            blurb: summary, format: format, fandoms: series.map { [$0] })
        s.chapterCount = "\(parts.count)/\(parts.count)"
        return s
    }

    public func work(in folder: URL) -> Work {
        var w = Work(id: id, title: title, authors: authors)
        w.coverURL = coverFile.map { folder.appendingPathComponent($0) }
        w.summaryHTML = summary.map { $0.contains("<") ? $0 : "<p>" + ReaderDocument.escape($0) + "</p>" }
        w.format = format
        w.language = language
        w.fandoms = series.map { [$0] }
        w.chapterCount = "\(parts.count)/\(parts.count)"
        w.status = "\(kind.label) file · \(originalFilename)"
        return w
    }

    /// A chapter's content, read from disk.
    public func content(of partID: String, in folder: URL) throws -> ChapterContent {
        guard let part = parts.first(where: { $0.id == partID }) else { throw CocoaError(.fileNoSuchFile) }
        if let file = part.file {
            let html = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            return .text(html: html, notesBefore: nil, notesAfter: nil)
        }
        let pages = (part.pages ?? []).map { ImagePage(url: folder.appendingPathComponent($0)) }
        return .images(pages)
    }
}

// MARK: - XML

/// A small XML tree, enough for EPUB's container, package, NCX and nav files and
/// a comic's ComicInfo.xml. Names lose their namespace prefix ("dc:title" is "title").
public final class MiniXML: @unchecked Sendable {
    public let name: String
    public let attributes: [String: String]
    public private(set) var children: [MiniXML] = []
    /// Text and child elements in document order, so mixed content reads right.
    private var pieces: [Piece] = []

    private enum Piece {
        case text(String)
        case node(MiniXML)
    }

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    public static func parse(_ data: Data) -> MiniXML? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return builder.root
    }

    public func attribute(_ name: String) -> String? { attributes[name] }

    /// Every element below this one, depth first.
    public var descendants: [MiniXML] { children.flatMap { [$0] + $0.descendants } }

    public func all(_ name: String) -> [MiniXML] { descendants.filter { $0.name == name } }
    public func first(_ name: String) -> MiniXML? { descendants.first { $0.name == name } }
    public func child(_ name: String) -> MiniXML? { children.first { $0.name == name } }

    /// All the text inside, trimmed and with runs of whitespace collapsed.
    public var text: String {
        let raw = pieces.map { piece -> String in
            switch piece {
            case let .text(t): t
            case let .node(n): " " + n.text + " "
            }
        }.joined()
        return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: MiniXML?
        var stack: [MiniXML] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            var attributes: [String: String] = [:]
            for (k, v) in attributeDict { attributes[MiniXML.local(k)] = v }
            let node = MiniXML(name: MiniXML.local(elementName), attributes: attributes)
            if let parent = stack.last {
                parent.children.append(node)
                parent.pieces.append(.node(node))
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.pieces.append(.text(string))
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.pieces.append(.text(String(decoding: CDATABlock, as: UTF8.self)))
        }
    }
}

// MARK: - EPUB

public enum EPUB {
    public struct Item: Sendable, Hashable {
        public var id: String
        /// Path inside the archive, already resolved against the package file.
        public var path: String
        public var mediaType: String
        public var properties: [String]
    }

    public struct Package: Sendable, Hashable {
        public var title: String?
        public var creators: [String] = []
        public var language: String?
        public var description: String?
        public var series: String?
        public var items: [String: Item] = [:]
        /// Reading order, without items marked `linear="no"`.
        public var spine: [Item] = []
        public var coverPath: String?
        /// EPUB 3 navigation document, or the EPUB 2 NCX.
        public var navPath: String?
        public var ncxPath: String?
        /// "rtl" for right-to-left books (most manga EPUBs).
        public var direction: String?
    }

    /// `META-INF/container.xml` names the package (`.opf`) file.
    public static func packagePath(container: Data) -> String? {
        MiniXML.parse(container)?.first("rootfile")?.attribute("full-path")
    }

    public static func package(_ data: Data, at path: String) -> Package? {
        guard let root = MiniXML.parse(data), root.name == "package" else { return nil }
        var p = Package()
        let metadata = root.child("metadata")
        p.title = metadata?.first("title")?.text.nonEmpty
        p.creators = (metadata?.all("creator") ?? []).map(\.text).filter { !$0.isEmpty }
        p.language = metadata?.first("language")?.text.nonEmpty
        p.description = metadata?.first("description")?.text.nonEmpty
        let metas = metadata?.all("meta") ?? []
        // Calibre's series tag, and EPUB 3's collection.
        p.series = metas.first { $0.attribute("name") == "calibre:series" }?.attribute("content")?.nonEmpty
            ?? metas.first { $0.attribute("property") == "belongs-to-collection" }?.text.nonEmpty

        for node in root.child("manifest")?.children ?? [] where node.name == "item" {
            guard let id = node.attribute("id"), let href = node.attribute("href") else { continue }
            let item = Item(
                id: id, path: resolve(href, from: path), mediaType: node.attribute("media-type") ?? "",
                properties: (node.attribute("properties") ?? "").split(separator: " ").map(String.init))
            p.items[id] = item
        }
        let spine = root.child("spine")
        p.direction = spine?.attribute("page-progression-direction")
        p.spine = (spine?.children ?? []).compactMap { ref in
            guard ref.name == "itemref", ref.attribute("linear") != "no", let id = ref.attribute("idref") else { return nil }
            return p.items[id]
        }
        p.navPath = p.items.values.first { $0.properties.contains("nav") }?.path
        p.ncxPath = spine?.attribute("toc").flatMap { p.items[$0]?.path }
            ?? p.items.values.first { $0.mediaType == "application/x-dtbncx+xml" }?.path

        // EPUB 3 marks the cover in the manifest; EPUB 2 names it in a <meta name="cover">.
        if let cover = p.items.values.first(where: { $0.properties.contains("cover-image") }) {
            p.coverPath = cover.path
        } else if let id = metas.first(where: { $0.attribute("name") == "cover" })?.attribute("content") {
            p.coverPath = p.items[id]?.path
                ?? p.items.values.first { $0.path.hasSuffix("/" + id) || $0.path == id }?.path
        }
        if p.coverPath == nil {
            p.coverPath = p.items.values
                .filter { $0.mediaType.hasPrefix("image/") && $0.path.lowercased().contains("cover") }
                .map(\.path).sorted().first
        }
        return p
    }

    /// Chapter titles from the table of contents, keyed by archive path (no `#fragment`).
    /// The first entry that points into a file names it.
    public static func tocTitles(nav: Data?, navPath: String?, ncx: Data?, ncxPath: String?) -> [String: String] {
        var titles: [String: String] = [:]
        func add(_ href: String, _ title: String, base: String) {
            let path = resolve(href, from: base)
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, titles[path] == nil { titles[path] = clean }
        }
        if let nav, let navPath, let root = MiniXML.parse(nav) {
            let tocNav = root.all("nav").first { $0.attribute("type") == "toc" } ?? root.first("nav")
            for a in tocNav?.all("a") ?? [] {
                if let href = a.attribute("href") { add(href, a.text, base: navPath) }
            }
        }
        if titles.isEmpty, let ncx, let ncxPath, let root = MiniXML.parse(ncx) {
            for point in root.all("navPoint") {
                guard let src = point.child("content")?.attribute("src") else { continue }
                add(src, point.child("navLabel")?.text ?? "", base: ncxPath)
            }
        }
        return titles
    }

    /// Groups the spine into chapters. A file the table of contents names starts a new
    /// chapter; files it doesn't name (a chapter split in two, an untitled interlude)
    /// join the chapter before them, except at the very start, where front matter is
    /// kept as its own part.
    public static func chapters(spine: [Item], titles: [String: String]) -> [(title: String, paths: [String])] {
        var out: [(title: String, paths: [String])] = []
        for item in spine {
            if let title = titles[item.path] {
                out.append((title, [item.path]))
            } else if out.isEmpty {
                out.append(("Front matter", [item.path]))
            } else {
                out[out.count - 1].paths.append(item.path)
            }
        }
        // No table of contents at all: one chapter per file.
        if titles.isEmpty {
            return spine.enumerated().map { ("Part \($0 + 1)", [$1.path]) }
        }
        return out
    }

    /// The inside of an XHTML file's `<body>`, without scripts.
    public static func body(of xhtml: String) -> String {
        var html = xhtml
        if let start = html.range(of: "<body", options: .caseInsensitive),
           let open = html.range(of: ">", range: start.upperBound..<html.endIndex) {
            let end = html.range(of: "</body>", options: [.caseInsensitive, .backwards], range: open.upperBound..<html.endIndex)
            html = String(html[open.upperBound..<(end?.lowerBound ?? html.endIndex)])
        }
        return html.replacingOccurrences(of: "<script\\b[\\s\\S]*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Image references in chapter HTML (`<img src>` and SVG `<image href>`), as written.
    public static func imageReferences(in html: String) -> [String] {
        imagePattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 3), in: html).map { String(html[$0]) }
        }
    }

    /// Replaces each image reference with what `replacement` returns for it (a `data:` URL),
    /// or leaves it as written when that returns nil.
    public static func rewriteImages(in html: String, _ replacement: (String) -> String?) -> String {
        let ns = html as NSString
        var out = ""
        var last = 0
        for match in imagePattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let ref = match.range(at: 3)
            guard let new = replacement(ns.substring(with: ref)) else { continue }
            out += ns.substring(with: NSRange(location: last, length: ref.location - last)) + new
            last = ref.location + ref.length
        }
        return out + ns.substring(from: last)
    }

    private static let imagePattern = try! NSRegularExpression(
        pattern: "(<(?:img|image)\\b[^>]*?\\s(?:src|xlink:href|href)\\s*=\\s*)([\"'])(.*?)\\2",
        options: [.caseInsensitive])

    /// `href` as a path inside the archive, given the file it appears in.
    /// Drops `#fragments`, decodes `%20`, and follows `../`.
    public static func resolve(_ href: String, from file: String) -> String {
        var target = href
        if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
        target = target.removingPercentEncoding ?? target
        if target.isEmpty { return file }
        var parts: [Substring] = target.hasPrefix("/") ? [] : file.split(separator: "/").dropLast()
        for piece in target.split(separator: "/") {
            switch piece {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(piece)
            }
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - Comic archives

public enum ComicArchive {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp"]

    public static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Page images grouped into chapters: one per folder in the archive, in natural order.
    /// A flat archive is one chapter. Skips macOS resource forks and hidden files.
    public static func chapters(from paths: [String]) -> [(title: String, pages: [String])] {
        let pages = paths.filter { path in
            isImage(path) && !path.hasPrefix("__MACOSX/") && !path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        var byFolder: [String: [String]] = [:]
        for page in pages {
            byFolder[(page as NSString).deletingLastPathComponent, default: []].append(page)
        }
        let folders = byFolder.keys.sorted(by: LocalBooks.naturalLess)
        if folders.count <= 1 {
            return pages.isEmpty ? [] : [("Chapter 1", pages.sorted(by: LocalBooks.naturalLess))]
        }
        return folders.map { folder in
            let name = (folder as NSString).lastPathComponent
            return (name.isEmpty ? "Pages" : name.replacingOccurrences(of: "_", with: " "),
                    byFolder[folder]!.sorted(by: LocalBooks.naturalLess))
        }
    }

    /// The fields of a ComicInfo.xml that the library uses.
    public struct Info: Sendable, Hashable {
        public var title: String?
        public var series: String?
        public var writers: [String] = []
        public var summary: String?
        public var language: String?
        /// ComicInfo's `<Manga>YesAndRightToLeft</Manga>`.
        public var rightToLeft = false
    }

    public static func info(_ data: Data) -> Info? {
        guard let root = MiniXML.parse(data), root.name == "ComicInfo" else { return nil }
        var info = Info()
        info.title = root.child("Title")?.text.nonEmpty
        info.series = root.child("Series")?.text.nonEmpty
        info.writers = (root.child("Writer")?.text ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        info.summary = root.child("Summary")?.text.nonEmpty
        info.language = root.child("LanguageISO")?.text.nonEmpty
        info.rightToLeft = root.child("Manga")?.text == "YesAndRightToLeft"
        return info
    }

    /// Long strips are manhwa; right-to-left books are manga; anything else reads as a comic.
    public static func format(rightToLeft: Bool, medianAspect: Double?) -> WorkFormat {
        if rightToLeft { return .manga }
        if let medianAspect, medianAspect > 2.2 { return .manhwa }
        return .comic
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
