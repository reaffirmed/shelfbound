import Foundation
import ShelfCore

/// Where downloads live: `<root>/<source>/<work>/<chapter>/` holding `chapter.json`
/// and, for image chapters, one file per page (`0001.jpg`, ...).
public struct DownloadLayout: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func `default`() throws -> DownloadLayout {
        let base = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        var url = base
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Downloads can be fetched again, so keep them out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return DownloadLayout(root: base)
    }

    public var queueFile: URL { root.appendingPathComponent("queue.json") }
    public var indexFile: URL { root.appendingPathComponent("index.json") }
    public var staging: URL { root.appendingPathComponent(".staging", isDirectory: true) }
    public var resumeData: URL { root.appendingPathComponent(".resume", isDirectory: true) }

    public func folder(for work: WorkKey) -> URL {
        root.appendingPathComponent(Self.safeName(work.sourceID), isDirectory: true)
            .appendingPathComponent(Self.safeName(work.workID), isDirectory: true)
    }

    public func folder(for ref: ChapterRef) -> URL {
        folder(for: ref.work).appendingPathComponent(Self.safeName(ref.chapterID), isDirectory: true)
    }

    public func chapterFile(for ref: ChapterRef) -> URL {
        folder(for: ref).appendingPathComponent("chapter.json")
    }

    /// File name for page `index`, keeping a known image extension from the URL.
    public static func pageFileName(index: Int, url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let known = ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic"]
        return String(format: "%04d.", index + 1) + (known.contains(ext) ? ext : "img")
    }

    /// IDs can hold slashes or be very long; folder names must not. Safe IDs are kept
    /// readable, anything else gets a stable hash so two IDs never share a folder.
    public static func safeName(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if !id.isEmpty, id.count <= 64, id.allSatisfy({ allowed.contains($0) }), !id.hasPrefix(".") {
            return id
        }
        let readable = String(id.filter { allowed.contains($0) && $0 != "." }.prefix(32))
        return (readable.isEmpty ? "id" : readable) + "-" + fnv1a(id)
    }

    static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func size(of folder: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
