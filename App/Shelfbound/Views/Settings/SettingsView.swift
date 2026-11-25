import DownloadKit
import LibraryKit
import ShelfCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    let showBrowse: () -> Void
    @State private var showingStyle = false
    @State private var exporting = false
    @State private var backupFile: BackupDocument?
    @State private var backupName = "Shelfbound backup.json"
    @State private var importing = false
    @State private var pendingRestore: LibraryBackup?
    @State private var restoring = false
    @State private var restoreMessage: String?
    @State private var choosingFiles = false
    @State private var confirmingAdult = false

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

                Section {
                    Button { choosingFiles = true } label: {
                        row("Import books and comics", icon: "doc.badge.plus", color: Color(hex: "#C2477B"),
                            value: model.importingFiles.isEmpty ? "" : "Importing...", chevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.importFiles")
                    NavigationLink {
                        ImportView()
                    } label: {
                        Label { Text("Import library") } icon: { RowIcon(systemImage: "square.and.arrow.down", color: Color(hex: "#3A7BD5")) }
                    }
                } header: {
                    Text("Import")
                } footer: {
                    Text(AppFlavor.isAppStore
                         ? "EPUB, PDF and CBZ files from Files, iCloud Drive or another app. Import library matches a list of links to your sources."
                         : "EPUB, PDF and CBZ files from Files, iCloud Drive or another app. Import library reads a backup from another reader app, or a list of links.")
                }

                Section {
                    NavigationLink {
                        AccountsView()
                    } label: {
                        row("Accounts", icon: "person.crop.circle", color: Color(hex: "#9E2A2B"), value: accountsValue)
                    }
                    .accessibilityIdentifier("settings.accounts")
                } footer: {
                    Text("Sign in to a site one of your sources supports, to import your lists from it and read works for signed-in users.")
                }

                Section {
                    Button {
                        do {
                            let data = try model.makeBackup()
                            backupFile = BackupDocument(data: data)
                            backupName = "Shelfbound backup \(Date().formatted(.iso8601.year().month().day()))"
                            exporting = true
                        } catch {
                            model.report(error)
                        }
                    } label: {
                        row("Back up library", icon: "externaldrive", color: Color(hex: "#2F8F6A"), value: "", chevron: true)
                    }
                    .buttonStyle(.plain)
                    Button {
                        importing = true
                    } label: {
                        row("Restore from backup", icon: "arrow.counterclockwise", color: Color(hex: "#3A7BD5"), value: restoring ? "Restoring..." : "", chevron: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(restoring)
                } header: {
                    Text("Backup")
                } footer: {
                    Text("A file with your library, reading places, highlights, settings and sources. Keep one in Files or iCloud Drive, so reinstalling or a new phone loses nothing.")
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
                    Picker(selection: ratingBinding) {
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
                    Link(destination: AppFlavor.privacyPolicyURL) {
                        row("Privacy policy", icon: "hand.raised", color: Color(hex: "#2F8F6A"), value: "", chevron: true)
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Shelfbound doesn't host content or list repositories. Only add sources for sites whose terms allow it.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $model.pendingShowDownloads) { DownloadsView() }
            .navigationDestination(for: WorkRoute.self) { WorkDetailView(route: $0) }
            .fileExporter(isPresented: $exporting, document: backupFile, contentType: .json, defaultFilename: backupName) { result in
                if case let .failure(error) = result { model.report(error) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case let .success(url):
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        pendingRestore = try LibraryBackup.decode(Data(contentsOf: url))
                    } catch {
                        model.report(error)
                    }
                case let .failure(error):
                    model.report(error)
                }
            }
            .confirmationDialog(
                "Restore this backup?",
                isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                titleVisibility: .visible
            ) {
                Button("Restore") {
                    guard let backup = pendingRestore else { return }
                    pendingRestore = nil
                    restoring = true
                    Task {
                        let report = await model.restore(backup)
                        restoring = false
                        restoreMessage = report.summary
                    }
                }
            } message: {
                if let backup = pendingRestore {
                    Text("From \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)), with \(backup.library.records.count) works. Works in the backup replace the same works here; everything else stays.")
                }
            }
            .alert("Backup restored", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
                Button("OK") { restoreMessage = nil }
            } message: {
                Text(restoreMessage ?? "")
            }
            .sheet(isPresented: $showingStyle) { ReaderStyleSheet().presentationDetents([.medium, .large]) }
            .localFileImporter(isPresented: $choosingFiles, model: model)
            .confirmationDialog("Are you 18 or older?", isPresented: $confirmingAdult, titleVisibility: .visible) {
                Button("I'm 18 or older") { model.settings.maxRating = .explicit }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Explicit sources can show adult content. Only choose this if you're an adult.")
            }
        }
    }

    /// The App Store build asks for the person's age before explicit sources show.
    private var ratingBinding: Binding<ContentRating> {
        Binding(
            get: { model.settings.maxRating },
            set: { value in
                if value == .explicit, AppFlavor.isAppStore, model.settings.maxRating != .explicit {
                    confirmingAdult = true
                } else {
                    model.settings.maxRating = value
                }
            })
    }

    private var accountsValue: String {
        let names = model.accountSources.compactMap { model.accounts[$0.id]?.username }
        if names.count == 1 { return names[0] }
        if names.count > 1 { return "\(names.count) signed in" }
        return model.accountSources.isEmpty ? "" : "Not signed in"
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
