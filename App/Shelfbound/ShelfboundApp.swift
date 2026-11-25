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
        .commands { ShelfboundCommands(model: model) }
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

/// Tabs on iPhone and in compact iPad windows; a sidebar when the window is wide
/// (full-screen iPad, the larger side of Split View, and the Mac).
@MainActor
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var model = model
        Group {
            if sizeClass == .regular { sidebar } else { tabs }
        }
        .alert("Something went wrong", isPresented: $model.showingError, presenting: model.lastError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
        .sheet(item: $model.pendingRepoLink) { link in
            NavigationStack { AddRepoView(initialURL: link.url) }
        }
        .onChange(of: model.pendingOpen) { _, key in
            if key != nil { model.selectedTab = .library }
        }
        .onChange(of: model.pendingContinue) { _, key in
            if key != nil { model.selectedTab = .library }
        }
        .onChange(of: model.pendingShowDownloads) { _, show in
            if show { model.selectedTab = .settings }
        }
    }

    private var badge: Int { model.settings.badgeNewChapters ? model.library.newChapterCount : 0 }

    private var tabs: some View {
        @Bindable var model = model
        return TabView(selection: $model.selectedTab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)
                .badge(badge)
            BrowseView()
                .tabItem { Label("Browse", systemImage: "safari") }
                .tag(AppTab.browse)
            SettingsView(showBrowse: { model.selectedTab = .browse })
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }

    private var sidebar: some View {
        NavigationSplitView {
            List(selection: Binding<AppTab?>(get: { model.selectedTab }, set: { if let tab = $0 { model.selectedTab = tab } })) {
                Label("Library", systemImage: "books.vertical").badge(badge).tag(AppTab.library)
                Label("Browse", systemImage: "safari").tag(AppTab.browse)
                Label("Settings", systemImage: "gearshape").tag(AppTab.settings)
            }
            .navigationTitle("Shelfbound")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            switch model.selectedTab {
            case .library: LibraryView()
            case .browse: BrowseView()
            case .settings: SettingsView(showBrowse: { model.selectedTab = .browse })
            }
        }
    }
}

/// Menu bar commands on the Mac and the keyboard shortcut list on iPad.
struct ShelfboundCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Library") {
            Button("Check for New Chapters") { Task { await model.checkForUpdates() } }
                .keyboardShortcut("r")
            Divider()
            Button("Library") { model.selectedTab = .library }.keyboardShortcut("1")
            Button("Browse") { model.selectedTab = .browse }.keyboardShortcut("2")
            Button("Settings") { model.selectedTab = .settings }.keyboardShortcut("3")
        }
    }
}
