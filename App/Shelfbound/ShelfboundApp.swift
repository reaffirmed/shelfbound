import SwiftUI

@main
struct ShelfboundApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            SourcesView()
                .tabItem { Label("Browse", systemImage: "safari") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .alert("Something went wrong", isPresented: $model.showingError, presenting: model.lastError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
        .sheet(item: $model.pendingRepoLink) { link in
            NavigationStack { AddRepoView(initialURL: link.url) }
        }
    }
}
