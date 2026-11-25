import BackgroundTasks
import DownloadKit
import Foundation
import LibraryKit
import ShelfCore
import UserNotifications

/// Background update checks and catch-up downloads.
///
/// iOS decides when these run (battery, network, how often the app is used), so a check
/// can come hours after the interval. Opening the app always checks right away.
enum BackgroundWork {
    static let refreshID = "app.shelfbound.Shelfbound.refresh"
    static let catchUpID = "app.shelfbound.Shelfbound.catchup"

    /// Must run before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handleRefresh(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: catchUpID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handleCatchUp(task)
        }
    }

    static func scheduleRefresh(interval: UpdateInterval) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshID)
        guard let seconds = interval.seconds else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Asks for a longer background window (usually while charging) to work through a big queue.
    static func scheduleCatchUp() {
        let request = BGProcessingTaskRequest(identifier: catchUpID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleRefresh(_ task: BGAppRefreshTask) {
        let work = Task { @MainActor in
            let model = AppModel.shared
            scheduleRefresh(interval: model.settings.updateInterval)
            let report = await model.checkForUpdates()
            if model.settings.notifyNewChapters {
                Notifications.post(report, downloading: model.settings.downloads.autoDownload)
            }
            if !model.downloads.jobs.isEmpty { scheduleCatchUp() }
            model.saveNow()
            task.setTaskCompleted(success: report.failures.count < max(report.checked, 1))
        }
        task.expirationHandler = { work.cancel() }
    }

    private static func handleCatchUp(_ task: BGProcessingTask) {
        let work = Task { @MainActor in
            let model = AppModel.shared
            await model.downloadManager.start()
            // Text chapters and page lists need the app running; page files continue in the
            // background session after this task ends.
            for _ in 0..<120 {
                let busy = model.downloads.jobs.contains { job in
                    if case .failed = job.state { return false }
                    return job.state == .waiting || job.state == .resolving
                }
                if !busy || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            model.saveNow()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}

enum Notifications {
    static let workKey = "work"

    static func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        }
    }

    static func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    static let newChaptersCategory = "new-chapters"
    static let markReadAction = "mark-read"
    static let downloadAction = "download"
    static let chaptersKey = "chapters"

    /// The buttons under a new-chapter alert. They show on the Lock Screen, in
    /// Notification Center, and on a paired Apple Watch, which mirrors iPhone alerts.
    static func registerCategories() {
        let markRead = UNNotificationAction(identifier: markReadAction, title: "Mark as Read", options: [],
                                            icon: UNNotificationActionIcon(systemImageName: "checkmark.circle"))
        let download = UNNotificationAction(identifier: downloadAction, title: "Download", options: [],
                                            icon: UNNotificationActionIcon(systemImageName: "arrow.down.circle"))
        let category = UNNotificationCategory(
            identifier: newChaptersCategory, actions: [download, markRead], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "New chapters", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// One alert per work ("Hollow Tide: 3 new chapters, up to Chapter 87"), grouped
    /// by work, or one summary when many works updated at once.
    static func post(_ report: UpdateReport, downloading: Bool) {
        for alert in UpdateChecker.alerts(report) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body + (downloading && alert.key != nil ? " · Downloading for offline reading" : "")
            content.sound = .default
            content.threadIdentifier = alert.thread
            content.relevanceScore = alert.key == nil ? 0.5 : 0.8
            if let key = alert.key {
                content.categoryIdentifier = newChaptersCategory
                content.userInfo = [workKey + ".source": key.sourceID, workKey + ".id": key.workID, chaptersKey: alert.chapterIDs]
                content.targetContentIdentifier = key.id
            }
            // Same identifier per work, so a later check replaces the older alert instead of stacking.
            let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    static func chapterIDs(from userInfo: [AnyHashable: Any]) -> [String] {
        userInfo[chaptersKey] as? [String] ?? []
    }

    /// Downloads paused on a site's bot check, which only the person can pass.
    static func postVerificationNeeded(hosts: [String]) {
        guard let first = hosts.first else { return }
        let content = UNMutableNotificationContent()
        content.title = "Downloads paused"
        content.body = hosts.count == 1
            ? "\(first) wants to check you're a person. Open Shelfbound and verify in Downloads to carry on."
            : "\(hosts.count) sites want to check you're a person. Open Shelfbound and verify in Downloads to carry on."
        content.threadIdentifier = "verification"
        content.userInfo = ["opens": "downloads"]
        let request = UNNotificationRequest(identifier: "verify-\(hosts.joined(separator: ","))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func workKey(from userInfo: [AnyHashable: Any]) -> WorkKey? {
        guard let source = userInfo[workKey + ".source"] as? String, let id = userInfo[workKey + ".id"] as? String else { return nil }
        return WorkKey(sourceID: source, workID: id)
    }
}
