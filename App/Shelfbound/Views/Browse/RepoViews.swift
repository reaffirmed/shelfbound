import RepoKit
import ShelfCore
import SwiftUI

@MainActor
struct AddRepoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var input: String
    @State private var preview: (url: URL, index: RepoIndex)?
    @State private var loading = false
    @State private var error: String?

    init(initialURL: String = "") {
        _input = State(initialValue: initialURL)
    }

    var body: some View {
        Form {
            Section {
                TextField("https://someone.github.io/repo", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { Task { await check() } }
                Button(loading ? "Checking..." : "Check repository") { Task { await check() } }
                    .disabled(input.isEmpty || loading)
            } footer: {
                Text("Paste the link the repository's maintainer shared.")
            }

            if let error {
                Section { Text(error).foregroundStyle(Color.shelfWarning) }
            }

            if let preview {
                Section("About this repository") {
                    LabeledContent("Name", value: preview.index.name)
                    if let maintainer = preview.index.maintainer {
                        LabeledContent("Maintainer", value: maintainer)
                    }
                    LabeledContent("Address", value: preview.url.host ?? preview.url.absoluteString)
                    LabeledContent("Sources", value: "\(preview.index.sources.count)")
                    LabeledContent("Signing key", value: String(preview.index.publicKey.prefix(24)) + "…")
                }
                Section {
                    Button("Add repository") {
                        model.addRepo(url: preview.url, index: preview.index)
                        dismiss()
                    }
                    .bold()
                } footer: {
                    Text("Shelfbound remembers this key. If the repository ever changes it, updates stop until you remove and re-add it. Shelfbound doesn't host or check what repositories point to.")
                }
            }
        }
        .navigationTitle("Add repository")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .task { if !input.isEmpty { await check() } }
    }

    private func check() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let (url, index) = try await model.fetchIndex(for: input)
            preview = (url, index)
        } catch {
            preview = nil
            self.error = error.readable
        }
    }
}

@MainActor
struct RepoDetailView: View {
    @Environment(AppModel.self) private var model
    let repo: SavedRepo
    @State private var index: RepoIndex?
    @State private var error: String?
    @State private var busy: Set<String> = []
    @State private var filter: RepoFilter = .all

    enum RepoFilter: String, CaseIterable, Identifiable {
        case all, fics, manga, manhwa
        var id: String { rawValue }
        var label: String { rawValue == "all" ? "All" : rawValue.capitalized }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    RowIcon(systemImage: "shippingbox.fill", color: .shelfAccent).scaleEffect(1.4).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repo.name).font(.headline)
                        Text(repo.url.deletingLastPathComponent().absoluteString)
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if let maintainer = repo.maintainer {
                            Text("Maintained by \(maintainer)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Show", selection: $filter) {
                    ForEach(RepoFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if let error { Text(error).foregroundStyle(Color.shelfWarning) }

            if let index {
                Section {
                    ForEach(index.sources.filter { matches($0) }) { entry in
                        HStack {
                            SourceIcon(name: entry.name, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text(entryLine(entry)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            actionButton(entry, index: index)
                        }
                    }
                } header: {
                    Text("Available sources")
                } footer: {
                    Text("Installed sources check for updates when you open Browse. You can remove a source at any time.")
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle(repo.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func matches(_ entry: RepoEntry) -> Bool {
        switch filter {
        case .all: true
        case .fics: entry.kind == .text
        case .manga: entry.kind == .images && (entry.format?.shelf ?? .manga) == .manga
        case .manhwa: entry.kind == .images && entry.format?.shelf == .manhwa
        }
    }

    private func entryLine(_ entry: RepoEntry) -> String {
        let kind = entry.format?.label ?? (entry.kind == .text ? "Text" : "Images")
        let language = entry.languages?.first.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        return [kind, language, entry.contentRating.rawValue.capitalized, "v\(entry.version)"].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func actionButton(_ entry: RepoEntry, index: RepoIndex) -> some View {
        if busy.contains(entry.id) {
            ProgressView()
        } else if let installed = model.isInstalled(entry) {
            if SemanticVersion(installed.manifest.version) < SemanticVersion(entry.version) {
                Button("Update") { install(entry, index) }.buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Menu {
                    Button("Remove", role: .destructive) { model.uninstall(entry.id) }
                } label: {
                    Text("Installed").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        } else {
            Button("Install") { install(entry, index) }.buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func install(_ entry: RepoEntry, _ index: RepoIndex) {
        busy.insert(entry.id)
        Task {
            await model.install(entry, index: index, repo: repo.url)
            busy.remove(entry.id)
        }
    }

    private func load() async {
        do {
            index = try await model.fetchIndex(for: repo.url.absoluteString).1
            error = nil
        } catch {
            self.error = error.readable
        }
    }
}
