import BackgroundTasks
import ShelfCore
import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundWork.register()
        UNUserNotificationCenter.current().delegate = self
        Notifications.registerCategories()
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
        let chapters = Notifications.chapterIDs(from: userInfo)
        let showDownloads = userInfo["opens"] as? String == "downloads"
        let action = response.actionIdentifier
        await MainActor.run {
            let model = AppModel.shared
            switch action {
            case Notifications.markReadAction:
                // From the Lock Screen or Apple Watch, without opening the app.
                if let key { model.markNewChaptersRead(chapters, in: key) }
            case Notifications.downloadAction:
                if let key { model.downloadChapters(chapters, in: key) }
            default:
                if showDownloads { model.pendingShowDownloads = true } else { model.pendingOpen = key }
            }
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

/// The tabs, in the order they show: Discover, Search, Library, History, Settings.
enum AppTab: Hashable, CaseIterable {
    case discover, search, library, history, settings

    var title: String {
        switch self {
        case .discover: "Discover"
        case .search: "Search"
        case .library: "Library"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .discover: "book"
        case .search: "magnifyingglass"
        case .library: "bookmark"
        case .history: "clock"
        case .settings: "gearshape"
        }
    }
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
            ForEach(AppTab.allCases, id: \.self) { tab in
                screen(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
                    .badge(tab == .library ? badge : 0)
            }
        }
        .tint(Color.shelfAccent)
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .discover: BrowseView(mode: .discover)
        case .search: BrowseView(mode: .search)
        case .library: LibraryView()
        case .history: HistoryView()
        case .settings: SettingsView(showBrowse: { model.selectedTab = .discover })
        }
    }

    private var sidebar: some View {
        NavigationSplitView {
            List(selection: Binding<AppTab?>(get: { model.selectedTab }, set: { if let tab = $0 { model.selectedTab = tab } })) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.systemImage).badge(tab == .library ? badge : 0).tag(tab)
                }
            }
            .navigationTitle("Shelfbound")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            screen(for: model.selectedTab)
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
            Button("Discover") { model.selectedTab = .discover }.keyboardShortcut("1")
            Button("Search") { model.selectedTab = .search }.keyboardShortcut("2")
            Button("Library") { model.selectedTab = .library }.keyboardShortcut("3")
            Button("History") { model.selectedTab = .history }.keyboardShortcut("4")
            Button("Settings") { model.selectedTab = .settings }.keyboardShortcut("5")
        }
    }
}
