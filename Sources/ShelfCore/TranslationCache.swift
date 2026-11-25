import Foundation

/// Keeps machine translations of chapters on disk, so reopening a chapter or rereading
/// it later doesn't translate it again. Entries are keyed by the chapter, the language
/// pair and the text itself, so an edited chapter is translated afresh.
public struct TranslationCache: Sendable {
    public let directory: URL
    /// The most chapters kept; the oldest are removed past this.
    public let limit: Int

    public init(directory: URL, limit: Int = 400) {
        self.directory = directory
        self.limit = limit
    }

    public static func `default`() -> TranslationCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return TranslationCache(directory: caches.appendingPathComponent("translations", isDirectory: true))
    }

    public static func key(work: String, chapter: String, source: String?, target: String, paragraphs: [String]) -> String {
        var hash = FNV1a()
        for part in [work, chapter, source ?? "auto", target] { hash.add(part); hash.add("\u{1F}") }
        for paragraph in paragraphs { hash.add(paragraph); hash.add("\u{1E}") }
        return String(hash.value, radix: 16)
    }

    public func load(_ key: String, count: Int) -> [String]? {
        guard let data = try? Data(contentsOf: file(key)),
              let list = try? JSONDecoder().decode([String].self, from: data), list.count == count else { return nil }
        return list
    }

    public func save(_ key: String, _ translated: [String]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(translated) else { return }
        try? data.write(to: file(key), options: .atomic)
        prune()
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > limit else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) {
            try? fm.removeItem(at: url)
        }
    }
}

/// 64-bit FNV-1a, for short stable file names. Not for anything security related.
struct FNV1a {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func add(_ string: String) {
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
    }
}
