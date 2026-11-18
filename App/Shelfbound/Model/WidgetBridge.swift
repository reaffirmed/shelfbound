import ActivityKit
import DownloadKit
import Foundation
import LibraryKit
import ShelfCore
import UIKit
import WidgetKit

/// Keeps the widgets' snapshot file and the download Live Activity in step with the app.
@MainActor
final class WidgetBridge {
    private var lastSnapshot: WidgetSnapshot?
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastState: DownloadActivityAttributes.ContentState?

    // MARK: Widgets

    /// Writes what the widgets show and asks WidgetKit to redraw, only when it changed.
    func update(library: LibraryState, badge: Bool) {
        guard let container = WidgetSnapshot.container else { return }
        let continuing = LibraryLayout.continueReading(library.library, limit: 4)
        let withNew = library.library.filter { $0.unreadNewCount > 0 }
            .sorted { $0.unreadNewCount > $1.unreadNewCount }
            .prefix(4)
        var snapshot = WidgetSnapshot(
            continueReading: continuing.map(item),
            newChapters: withNew.map(item),
            totalNew: badge ? library.newChapterCount : withNew.reduce(0) { $0 + $1.unreadNewCount })
        snapshot.updatedAt = lastSnapshot?.updatedAt ?? Date()
        guard snapshot != lastSnapshot else { return }
        snapshot.updatedAt = Date()
        lastSnapshot = snapshot
        try? snapshot.encoded().write(to: container.appendingPathComponent(WidgetSnapshot.fileName), options: .atomic)
        saveCovers(for: Array(continuing) + Array(withNew), in: container)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func item(_ record: WorkRecord) -> WidgetSnapshot.Item {
        WidgetSnapshot.Item(
            key: record.key, title: record.title,
            subtitle: record.progressLine ?? record.continueChapter?.title ?? "",
            progress: record.workProgress, newCount: record.unreadNewCount, format: record.format,
            coverFile: record.coverURL == nil ? nil : Self.coverFile(record.key))
    }

    static func coverFile(_ key: WorkKey) -> String { DownloadLayout.safeName(key.id) + ".jpg" }

    /// Small cover thumbnails, so the widget never touches the network.
    private func saveCovers(for records: [WorkRecord], in container: URL) {
        let folder = container.appendingPathComponent(WidgetSnapshot.coversFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for record in records {
            guard let url = record.coverURL else { continue }
            let file = folder.appendingPathComponent(Self.coverFile(record.key))
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            Task {
                guard let loaded = try? await ImageLoader.shared.load(ImagePage(url: url), width: 160),
                      let data = loaded.image.jpegData(compressionQuality: 0.8) else { return }
                try? data.write(to: file, options: .atomic)
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    // MARK: Live Activity

    /// Starts, updates or ends the download Live Activity. iOS only lets the app start one
    /// while it's on screen; updates also arrive while background downloads wake it.
    func update(downloads snapshot: DownloadSnapshot) {
        let jobs = snapshot.jobs.filter { !$0.isFailed }
        guard !jobs.isEmpty else {
            end()
            return
        }
        let current = jobs.first { $0.state == .downloading } ?? jobs[0]
        let state = DownloadActivityAttributes.ContentState(
            chaptersLeft: jobs.count,
            current: "\(current.request.workTitle) · \(current.request.chapterTitle)",
            progress: current.progress,
            paused: !snapshot.blockedHosts.isEmpty || snapshot.paused)
        guard state != lastState else { return }
        lastState = state
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))
        if let activity {
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled, UIApplication.shared.applicationState == .active, jobs.count > 1 {
            activity = try? Activity.request(attributes: DownloadActivityAttributes(), content: content)
        }
    }

    private func end() {
        lastState = nil
        guard let activity else { return }
        self.activity = nil
        let final = DownloadActivityAttributes.ContentState(chaptersLeft: 0, current: "Downloads finished", progress: 1, paused: false)
        Task { await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60))) }
    }
}
