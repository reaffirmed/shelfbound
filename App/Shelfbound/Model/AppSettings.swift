import DownloadKit
import Foundation
import LibraryKit
import ShelfCore

/// Everything on the Settings screen, saved as one value.
struct AppSettings: Codable, Equatable {
    var readerStyle = ReaderStyle()
    var maxRating: ContentRating = .mature
    /// Default direction for paged works (manga). Each work can override it.
    var pagedDirection: ReadingMode = .pagedRightToLeft
    var keepScreenAwake = true
    /// Text reader: pulling up past the end of a chapter opens the next one.
    var autoAdvance = true
    var updateInterval: UpdateInterval = .sixHours
    var badgeNewChapters = true
    var notifyNewChapters = true
    var grouping: LibraryGrouping = .fandom
    var sort: LibrarySort = .recent
    var downloads = DownloadSettings()
    /// Webtoon auto-scroll speed in points per second; 0 is off.
    var autoScrollSpeed: Double = 0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case readerStyle, maxRating, pagedDirection, keepScreenAwake, autoAdvance, updateInterval
        case badgeNewChapters, notifyNewChapters, grouping, sort, downloads, autoScrollSpeed
    }

    // Each field falls back to its default, so settings from older builds still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = AppSettings()
        readerStyle = value(.readerStyle, d.readerStyle)
        maxRating = value(.maxRating, d.maxRating)
        pagedDirection = value(.pagedDirection, d.pagedDirection)
        keepScreenAwake = value(.keepScreenAwake, d.keepScreenAwake)
        autoAdvance = value(.autoAdvance, d.autoAdvance)
        updateInterval = value(.updateInterval, d.updateInterval)
        badgeNewChapters = value(.badgeNewChapters, d.badgeNewChapters)
        notifyNewChapters = value(.notifyNewChapters, d.notifyNewChapters)
        grouping = value(.grouping, d.grouping)
        sort = value(.sort, d.sort)
        downloads = value(.downloads, d.downloads)
        autoScrollSpeed = value(.autoScrollSpeed, d.autoScrollSpeed)
    }
}
