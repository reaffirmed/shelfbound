import Foundation

/// What the Home Screen and Lock Screen widgets show, written by the app into the shared
/// App Group container. The widget extension only reads this file; it never runs sources.
public struct WidgetSnapshot: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var sourceID: String
        public var workID: String
        public var title: String
        /// "Ch. 85 of 87", or the chapter title.
        public var subtitle: String
        /// 0...1 through the work.
        public var progress: Double
        public var newCount: Int
        public var format: WorkFormat
        /// A small JPEG in the App Group's `covers` folder, when the work has a cover.
        public var coverFile: String?

        public var id: String { "\(sourceID)/\(workID)" }
        public var key: WorkKey { WorkKey(sourceID: sourceID, workID: workID) }
        public var link: URL { WidgetSnapshot.link(to: key) }

        public init(key: WorkKey, title: String, subtitle: String, progress: Double, newCount: Int, format: WorkFormat, coverFile: String? = nil) {
            self.sourceID = key.sourceID
            self.workID = key.workID
            self.title = title
            self.subtitle = subtitle
            self.progress = progress
            self.newCount = newCount
            self.format = format
            self.coverFile = coverFile
        }
    }

    public var continueReading: [Item]
    /// Works with unread new chapters, most new first.
    public var newChapters: [Item]
    public var totalNew: Int
    public var updatedAt: Date

    public init(continueReading: [Item] = [], newChapters: [Item] = [], totalNew: Int = 0, updatedAt: Date = Date()) {
        self.continueReading = continueReading
        self.newChapters = newChapters
        self.totalNew = totalNew
        self.updatedAt = updatedAt
    }

    public static let appGroup = "group.app.shelfbound"
    public static let fileName = "widgets.json"
    public static let coversFolder = "covers"

    /// shelfbound://open?source=…&work=… opens the work's page.
    public static func link(to key: WorkKey) -> URL {
        var components = URLComponents()
        components.scheme = "shelfbound"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "source", value: key.sourceID), URLQueryItem(name: "work", value: key.workID)]
        return components.url!
    }

    public static func workKey(from url: URL) -> WorkKey? {
        guard url.scheme == "shelfbound", url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let source = items.first(where: { $0.name == "source" })?.value,
              let work = items.first(where: { $0.name == "work" })?.value
        else { return nil }
        return WorkKey(sourceID: source, workID: work)
    }

    #if canImport(Darwin)
    /// The shared container, or nil when the App Group isn't set up (unsigned builds).
    public static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    public static func load() -> WidgetSnapshot? {
        guard let url = container?.appendingPathComponent(fileName), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
    #endif

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
