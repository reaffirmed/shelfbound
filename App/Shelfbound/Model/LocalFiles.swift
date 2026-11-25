import Foundation
import ImageIO
import LibraryKit
import PDFKit
import ShelfCore
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

enum LocalFileError: LocalizedError {
    case unsupported(String)
    case empty(String)
    case locked(String)
    case tooLarge(String)
    case damaged(String)
    case missing

    var errorDescription: String? {
        switch self {
        case let .unsupported(name): "\(name) isn't an EPUB, PDF or CBZ file."
        case let .empty(name): "Couldn't find any chapters or pages in \(name)."
        case let .locked(name): "\(name) is password-protected or has DRM, so it can't be opened."
        case let .tooLarge(name): "\(name) is too large to import."
        case let .damaged(name): "\(name) looks damaged and couldn't be read."
        case .missing: "This file is no longer on this device. Import it again."
        }
    }
}

/// The file types the import picker and "Open in Shelfbound" accept.
enum LocalFileTypes {
    static let cbz = UTType(filenameExtension: "cbz", conformingTo: .zip) ?? .zip
    static let all: [UTType] = [.epub, .pdf, cbz]
}

/// Imported books and comics on disk: `Application Support/Local books/<id>/`, holding
/// `book.json` and the extracted chapters and pages. The original file isn't kept.
struct LocalFiles: Sendable {
    let root: URL

    static func `default`() throws -> LocalFiles {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("Local books", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LocalFiles(root: root)
    }

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    func load(_ id: String) throws -> LocalBook {
        let url = folder(id).appendingPathComponent("book.json")
        guard let data = try? Data(contentsOf: url) else { throw LocalFileError.missing }
        return try JSONDecoder().decode(LocalBook.self, from: data)
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    /// Bytes used by imported files.
    func totalBytes() -> Int64 {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Reads the file and stores what the readers need. Slow for big files; call it off the main actor.
    func importFile(at source: URL) throws -> LocalBook {
        let name = source.lastPathComponent
        guard let kind = LocalBooks.Kind(filename: name) else { throw LocalFileError.unsupported(name) }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size < 2_000_000_000 else { throw LocalFileError.tooLarge(name) }

        let id = UUID().uuidString
        let dest = folder(id)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            var book: LocalBook
            switch kind {
            case .epub: book = try EPUBImporter(source: source, dest: dest, id: id).run()
            case .cbz: book = try ComicImporter(source: source, dest: dest, id: id).run()
            case .pdf: book = try PDFImporter(source: source, dest: dest, id: id).run()
            }
            guard !book.parts.isEmpty else { throw LocalFileError.empty(name) }
            book.originalFilename = name
            let data = try JSONEncoder().encode(book)
            try data.write(to: dest.appendingPathComponent("book.json"), options: .atomic)
            return book
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }
}

// MARK: - Zip helpers

private extension Archive {
    /// One file's bytes, capped so a hostile archive can't fill memory.
    func data(at path: String, limit: UInt64 = 60_000_000) -> Data? {
        guard let entry = self[path], entry.type == .file, entry.uncompressedSize < limit else { return nil }
        var data = Data()
        do {
            _ = try extract(entry, skipCRC32: true) { data.append($0) }
        } catch {
            return nil
        }
        return data
    }
}

private func mimeType(_ path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "jpg", "jpeg": "image/jpeg"
    case "png": "image/png"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "svg": "image/svg+xml"
    case "avif": "image/avif"
    default: "application/octet-stream"
    }
}

/// Height over width of an image file, read from its header without decoding it.
private func aspect(of url: URL) -> Double? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0
    else { return nil }
    return h / w
}

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.sorted()[values.count / 2]
}

// MARK: - EPUB

private struct EPUBImporter {
    let source: URL
    let dest: URL
    let id: String

    func run() throws -> LocalBook {
        let name = source.lastPathComponent
        let archive: Archive
        do { archive = try Archive(url: source, accessMode: .read) } catch { throw LocalFileError.damaged(name) }
        // Adobe and Apple DRM leave an encryption.xml naming the content files they lock.
        if let encryption = archive.data(at: "META-INF/encryption.xml"),
           String(decoding: encryption, as: UTF8.self).contains("EncryptedData") {
            throw LocalFileError.locked(name)
        }
        guard let container = archive.data(at: "META-INF/container.xml"),
              let opfPath = EPUB.packagePath(container: container),
              let opf = archive.data(at: opfPath),
              let package = EPUB.package(opf, at: opfPath)
        else { throw LocalFileError.damaged(name) }

        let titles = EPUB.tocTitles(
            nav: package.navPath.flatMap { archive.data(at: $0) }, navPath: package.navPath,
            ncx: package.ncxPath.flatMap { archive.data(at: $0) }, ncxPath: package.ncxPath)
        let chapters = EPUB.chapters(spine: package.spine, titles: titles)

        var book = LocalBook(
            id: id, kind: .epub, format: .novel, title: package.title ?? LocalBooks.title(fromFilename: name),
            authors: package.creators, originalFilename: name)
        book.language = package.language
        book.summary = package.description
        book.series = package.series

        if let coverPath = package.coverPath, let data = archive.data(at: coverPath) {
            let file = "cover." + ((coverPath as NSString).pathExtension.lowercased().nonEmpty ?? "jpg")
            try data.write(to: dest.appendingPathComponent(file))
            book.coverFile = file
        }

        // Bodies first, to tell a picture book (most manga EPUBs) from a text one.
        var bodies: [String: String] = [:]
        for path in chapters.flatMap(\.paths) where bodies[path] == nil {
            guard let data = archive.data(at: path) else { continue }
            bodies[path] = EPUB.body(of: String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
        }
        let imageOnly = !bodies.isEmpty && bodies.values.allSatisfy { body in
            !EPUB.imageReferences(in: body).isEmpty && visibleText(body).count < 40
        }

        if imageOnly {
            book.format = package.direction == "rtl" ? .manga : .comic
            for (index, chapter) in chapters.enumerated() {
                var pages: [String] = []
                for path in chapter.paths {
                    for ref in EPUB.imageReferences(in: bodies[path] ?? "") {
                        let imagePath = EPUB.resolve(ref, from: path)
                        guard let data = archive.data(at: imagePath) else { continue }
                        let file = "pages/\(index)/\(pages.count).\((imagePath as NSString).pathExtension.lowercased())"
                        try write(data, to: file)
                        pages.append(file)
                    }
                }
                if !pages.isEmpty { book.parts.append(.init(id: "p\(index)", title: chapter.title, pages: pages)) }
            }
            if book.coverFile == nil { book.coverFile = book.parts.first?.pages?.first }
            return book
        }

        var inlined: [String: String] = [:]
        for (index, chapter) in chapters.enumerated() {
            let html = chapter.paths.map { path in
                EPUB.rewriteImages(in: bodies[path] ?? "") { ref in
                    let imagePath = EPUB.resolve(ref, from: path)
                    if let known = inlined[imagePath] { return known }
                    guard let data = archive.data(at: imagePath, limit: 12_000_000) else { return nil }
                    let url = "data:\(mimeType(imagePath));base64,\(data.base64EncodedString())"
                    inlined[imagePath] = url
                    return url
                }
            }.joined(separator: "\n")
            guard !visibleText(html).isEmpty || html.contains("data:image") else { continue }
            let file = "parts/\(index).html"
            try write(Data(html.utf8), to: file)
            book.parts.append(.init(id: "p\(index)", title: chapter.title, file: file))
        }
        return book
    }

    private func visibleText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ data: Data, to file: String) throws {
        let url = dest.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

// MARK: - CBZ

private struct ComicImporter {
    let source: URL
    let dest: URL
    let id: String

    func run() throws -> LocalBook {
        let name = source.lastPathComponent
        let archive: Archive
        do { archive = try Archive(url: source, accessMode: .read) } catch { throw LocalFileError.damaged(name) }
        let paths = archive.filter { $0.type == .file }.map(\.path)
        let info = paths.first { ($0 as NSString).lastPathComponent.lowercased() == "comicinfo.xml" }
            .flatMap { archive.data(at: $0) }.flatMap(ComicArchive.info)
        let chapters = ComicArchive.chapters(from: paths)

        var book = LocalBook(
            id: id, kind: .cbz, format: .comic,
            title: info?.title ?? info?.series ?? LocalBooks.title(fromFilename: name),
            authors: info?.writers ?? [], originalFilename: name)
        book.summary = info?.summary
        book.language = info?.language
        if let series = info?.series, series != book.title { book.series = series }

        var total: UInt64 = 0
        var aspects: [Double] = []
        for (index, chapter) in chapters.enumerated() {
            var pages: [String] = []
            for path in chapter.pages {
                guard let entry = archive[path] else { continue }
                total += entry.uncompressedSize
                guard total < 4_000_000_000 else { throw LocalFileError.tooLarge(name) }
                let file = "pages/\(index)/\(pages.count).\((path as NSString).pathExtension.lowercased())"
                let url = dest.appendingPathComponent(file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    _ = try archive.extract(entry, to: url, skipCRC32: true)
                } catch {
                    continue
                }
                if aspects.count < 12, let a = aspect(of: url) { aspects.append(a) }
                pages.append(file)
            }
            if !pages.isEmpty { book.parts.append(.init(id: "p\(index)", title: chapter.title, pages: pages)) }
        }
        book.format = ComicArchive.format(rightToLeft: info?.rightToLeft ?? false, medianAspect: median(aspects))
        book.coverFile = book.parts.first?.pages?.first
        return book
    }
}

// MARK: - PDF

private struct PDFImporter {
    let source: URL
    let dest: URL
    let id: String
    /// Pages are drawn this many pixels wide, sharp on any iPhone and fine on iPad.
    let pixelWidth: CGFloat = 1500

    func run() throws -> LocalBook {
        let name = source.lastPathComponent
        guard let document = PDFDocument(url: source) else { throw LocalFileError.damaged(name) }
        if document.isLocked { throw LocalFileError.locked(name) }
        guard document.pageCount > 0 else { throw LocalFileError.empty(name) }
        guard document.pageCount <= 3000 else { throw LocalFileError.tooLarge(name) }

        let attributes = document.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty
        var book = LocalBook(
            id: id, kind: .pdf, format: .comic, title: title ?? LocalBooks.title(fromFilename: name),
            authors: author.map { [$0] } ?? [], originalFilename: name)

        let folder = dest.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [String] = []
        for index in 0..<document.pageCount {
            try autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let bounds = page.bounds(for: .mediaBox)
                let rotated = page.rotation % 180 != 0
                let w = rotated ? bounds.height : bounds.width
                let h = rotated ? bounds.width : bounds.height
                guard w > 0, h > 0 else { return }
                let size = CGSize(width: pixelWidth, height: (pixelWidth * h / w).rounded())
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                    UIColor.white.setFill()
                    ctx.fill(CGRect(origin: .zero, size: size))
                    ctx.cgContext.translateBy(x: 0, y: size.height)
                    ctx.cgContext.scaleBy(x: size.width / w, y: -size.height / h)
                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }
                guard let data = image.jpegData(compressionQuality: 0.82) else { return }
                let file = "pages/\(index).jpg"
                try data.write(to: dest.appendingPathComponent(file))
                files.append(file)
            }
        }
        guard !files.isEmpty else { throw LocalFileError.empty(name) }

        // The PDF's own bookmarks become chapters, when it has a few.
        let starts = outlineStarts(document)
        if starts.count >= 2 {
            var bounds = starts
            if bounds[0].page > 0 { bounds.insert(("Start", 0), at: 0) }
            for (i, start) in bounds.enumerated() {
                let end = i + 1 < bounds.count ? bounds[i + 1].page : files.count
                let pages = Array(files[min(start.page, files.count)..<min(end, files.count)])
                if !pages.isEmpty { book.parts.append(.init(id: "p\(i)", title: start.title, pages: pages)) }
            }
        } else {
            book.parts = [.init(id: "p0", title: "All pages", pages: files)]
        }
        book.coverFile = files.first
        return book
    }

    /// Top-level bookmarks and the page each starts on, in page order.
    private func outlineStarts(_ document: PDFDocument) -> [(title: String, page: Int)] {
        guard let root = document.outlineRoot else { return [] }
        var out: [(title: String, page: Int)] = []
        for i in 0..<root.numberOfChildren {
            guard let item = root.child(at: i), let page = item.destination?.page else { continue }
            let index = document.index(for: page)
            if let last = out.last, index <= last.page { continue }
            out.append(((item.label ?? "").trimmingCharacters(in: .whitespaces).nonEmpty ?? "Part \(out.count + 1)", index))
        }
        return out
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
