import BackgroundTasks
import ShelfCore
import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundWork.register()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// iOS relaunches the app in the background when page downloads finish.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            AppModel.shared.transfer.handleEvents(forSession: identifier, completion: completionHandler)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let key = Notifications.workKey(from: userInfo)
        let showDownloads = userInfo["opens"] as? String == "downloads"
        await MainActor.run {
            if showDownloads { AppModel.shared.pendingShowDownloads = true } else { AppModel.shared.pendingOpen = key }
        }
    }
}

@main
@MainActor
struct ShelfboundApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.shelfAccent)
                .onOpenURL { model.handle(url: $0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.checkOnOpenIfDue()
                Task { await model.downloadManager.start() }
            case .background:
                model.saveNow()
                BackgroundWork.scheduleRefresh(interval: model.settings.updateInterval)
                if !model.downloads.jobs.isEmpty { BackgroundWork.scheduleCatchUp() }
            default:
                break
            }
        }
    }
}

enum AppTab: Hashable {
    case library, browse, settings
}

@MainActor
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .library

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)
                .badge(model.settings.badgeNewChapters ? model.library.newChapterCount : 0)
            BrowseView()
                .tabItem { Label("Browse", systemImage: "safari") }
                .tag(AppTab.browse)
            SettingsView(showBrowse: { tab = .browse })
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .alert("Something went wrong", isPresented: $model.showingError, presenting: model.lastError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
        .sheet(item: $model.pendingRepoLink) { link in
            NavigationStack { AddRepoView(initialURL: link.url) }
        }
        .onChange(of: model.pendingOpen) { _, key in
            if key != nil { tab = .library }
        }
        .onChange(of: model.pendingShowDownloads) { _, show in
            if show { tab = .settings }
        }
    }
}
