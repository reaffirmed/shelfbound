import DownloadKit
import LibraryKit
import ShelfCore
import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    let showBrowse: () -> Void
    @State private var showingStyle = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Reading") {
                    Button { showingStyle = true } label: {
                        row("Text reader theme", icon: "textformat", color: Color(hex: "#5B6CD6"), value: model.settings.readerStyle.theme.label, chevron: true)
                    }
                    .buttonStyle(.plain)
                    Picker(selection: $model.settings.pagedDirection) {
                        Text("Right to left").tag(ReadingMode.pagedRightToLeft)
                        Text("Left to right").tag(ReadingMode.pagedLeftToRight)
                    } label: {
                        Label { Text("Manga direction") } icon: { RowIcon(systemImage: "arrow.left.arrow.right", color: Color(hex: "#C2477B")) }
                    }
                    Toggle(isOn: $model.settings.keepScreenAwake) {
                        Label { Text("Keep screen awake") } icon: { RowIcon(systemImage: "sun.max", color: Color(hex: "#D9971C")) }
                    }
                }

                Section {
                    Picker(selection: $model.settings.updateInterval) {
                        ForEach(UpdateInterval.allCases) { Text($0.label).tag($0) }
                    } label: {
                        Label { Text("Check for updates") } icon: { RowIcon(systemImage: "clock", color: Color(hex: "#2F8F6A")) }
                    }
                    Toggle(isOn: $model.settings.notifyNewChapters) {
                        Label { Text("Notify about new chapters") } icon: { RowIcon(systemImage: "bell.badge", color: .shelfBadge) }
                    }
                    .onChange(of: model.settings.notifyNewChapters) { _, on in if on { Notifications.requestPermissionIfNeeded() } }
                    Toggle(isOn: $model.settings.badgeNewChapters) {
                        Label { Text("Badge new chapters") } icon: { RowIcon(systemImage: "app.badge", color: .shelfBadge) }
                    }
                    Picker(selection: $model.settings.grouping) {
                        ForEach(LibraryGrouping.allCases) { Text($0.label).tag($0) }
                    } label: {
                        Label { Text("Group library by") } icon: { RowIcon(systemImage: "square.stack.3d.up", color: Color(.systemGray)) }
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text(lastCheckFooter)
                }

                Section("Storage") {
                    NavigationLink {
                        DownloadsView()
                    } label: {
                        row("Downloads", icon: "arrow.down.circle", color: .shelfAccent,
                            value: model.downloads.blockedHosts.isEmpty ? model.downloads.totalBytes.byteString : "Needs a browser check")
                    }
                }

                Section {
                    Button(action: showBrowse) {
                        row("Repositories", icon: "shippingbox", color: Color(hex: "#4B4FB8"), value: "\(model.repos.count)", chevron: true)
                    }
                    .buttonStyle(.plain)
                    Picker(selection: $model.settings.maxRating) {
                        Text("Safe").tag(ContentRating.safe)
                        Text("Mature").tag(ContentRating.mature)
                        Text("Explicit").tag(ContentRating.explicit)
                    } label: {
                        Label { Text("Show sources rated up to") } icon: { RowIcon(systemImage: "eye", color: Color(hex: "#9E2A2B")) }
                    }
                    NavigationLink {
                        InstalledSourcesView()
                    } label: {
                        row("Installed sources", icon: "puzzlepiece.extension", color: Color(hex: "#6E6E73"), value: "\(model.installed.count)")
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Explicit sources stay hidden until you choose Explicit here.")
                }

                Section {
                    LabeledContent("Version", value: AppModel.appVersion)
                } footer: {
                    Text("Shelfbound doesn't host content or list repositories. Only add sources for sites whose terms allow it.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $model.pendingShowDownloads) { DownloadsView() }
            .sheet(isPresented: $showingStyle) { ReaderStyleSheet().presentationDetents([.medium, .large]) }
        }
    }

    private var lastCheckFooter: String {
        let interval = model.settings.updateInterval == .manual
            ? "Pull down in the library to check."
            : "iOS decides exactly when background checks run, so they can come later than this. Opening the app always checks."
        guard let last = model.library.lastUpdateCheck else { return interval }
        return "Last checked \(last.formatted(.relative(presentation: .named))). " + interval
    }

    private func row(_ title: String, icon: String, color: Color, value: String, chevron: Bool = false) -> some View {
        HStack {
            Label { Text(title).foregroundStyle(.primary) } icon: { RowIcon(systemImage: icon, color: color) }
            Spacer()
            Text(value).foregroundStyle(.secondary)
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }
}

@MainActor
struct InstalledSourcesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.installed) { source in
                HStack(spacing: 12) {
                    SourceIcon(name: source.manifest.name, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.manifest.name)
                        Text("v\(source.manifest.version) · \(source.manifest.contentRating.rawValue.capitalized) · \(source.repoURL.host ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                        if source.manifest.has(.links) {
                            Text("Reads chapter links from \(source.manifest.domains.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { offsets in offsets.map { model.installed[$0].id }.forEach { model.uninstall($0) } }
        }
        .overlay {
            if model.installed.isEmpty { ContentUnavailableView("No sources installed", systemImage: "puzzlepiece.extension") }
        }
        .navigationTitle("Installed sources")
        .toolbar { EditButton() }
    }
}
