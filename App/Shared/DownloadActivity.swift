import ActivityKit
import Foundation

/// The Live Activity shown while chapters download: on the Lock Screen and in the
/// Dynamic Island. Shared by the app (which starts and updates it) and the widget
/// extension (which draws it).
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var chaptersLeft: Int
        /// The chapter downloading now, "Hollow Tide · Ch. 86".
        var current: String
        /// 0...1 through the chapter downloading now.
        var progress: Double
        /// A site is waiting for a browser check.
        var paused: Bool
    }
}
