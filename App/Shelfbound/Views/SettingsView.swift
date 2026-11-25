import RepoKit
import ShelfCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    ForEach(model.repos) { repo in
                        NavigationLink(value: repo) {
                            VStack(alignment: .leading) {
                                Text(repo.name)
                                Text(repo.url.host ?? repo.url.absoluteString)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in offsets.map { model.repos[$0] }.forEach(model.removeRepo) }
                    NavigationLink("Add a repo") { AddRepoView() }
                } header: {
                    Text("Repos")
                } footer: {
                    Text("Repos are run by other people. Shelfbound doesn't host or check the content they point to.")
                }

                Section("Content") {
                    Picker("Show sources rated up to", selection: $model.maxRating) {
                        Text("Safe").tag(ContentRating.safe)
                        Text("Mature").tag(ContentRating.mature)
                        Text("Explicit").tag(ContentRating.explicit)
                    }
                }

                Section("Reader") {
                    ReaderStyleControls(style: $model.readerStyle)
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SavedRepo.self) { RepoDetailView(repo: $0) }
        }
    }
}

struct ReaderStyleControls: View {
    @Binding var style: ReaderStyle

    var body: some View {
        Picker("Theme", selection: $style.theme) {
            ForEach(ReaderTheme.allCases) { Text($0.rawValue.capitalized).tag($0) }
        }
        .pickerStyle(.segmented)
        Stepper("Text size \(Int(style.fontSize))", value: $style.fontSize, in: 12...32, step: 1)
        Stepper(String(format: "Line spacing %.1f", style.lineHeight), value: $style.lineHeight, in: 1.2...2.2, step: 0.1)
        Stepper("Margins \(Int(style.margin))", value: $style.margin, in: 8...48, step: 4)
    }
}

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
                Button(loading ? "Checking..." : "Check repo") { Task { await check() } }
                    .disabled(input.isEmpty || loading)
            } footer: {
                Text("Paste the link the repo's maintainer shared.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let preview {
                Section("About this repo") {
                    LabeledContent("Name", value: preview.index.name)
                    if let maintainer = preview.index.maintainer {
                        LabeledContent("Maintainer", value: maintainer)
                    }
                    LabeledContent("Sources", value: "\(preview.index.sources.count)")
                    LabeledContent("Key", value: String(preview.index.publicKey.prefix(20)) + "...")
                }
                Section {
                    Button("Add repo") {
                        model.addRepo(url: preview.url, index: preview.index)
                        dismiss()
                    }
                } footer: {
                    Text("Shelfbound remembers this key. If the repo ever changes it, updates are blocked until you re-add the repo.")
                }
            }
        }
        .navigationTitle("Add repo")
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
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct RepoDetailView: View {
    @Environment(AppModel.self) private var model
    let repo: SavedRepo
    @State private var index: RepoIndex?
    @State private var error: String?
    @State private var busy: Set<String> = []

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if let index {
                ForEach(index.sources) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.name)
                            Text("\(entry.kind == .text ? "Text" : "Images") · \(entry.contentRating.rawValue.capitalized) · v\(entry.version)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        actionButton(entry, index: index)
                    }
                }
            } else if error == nil {
                ProgressView()
            }
        }
        .navigationTitle(repo.name)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func actionButton(_ entry: RepoEntry, index: RepoIndex) -> some View {
        if busy.contains(entry.id) {
            ProgressView()
        } else if let installed = model.isInstalled(entry) {
            if SemanticVersion(installed.manifest.version) < SemanticVersion(entry.version) {
                Button("Update") { install(entry, index) }.buttonStyle(.bordered)
            } else {
                Button("Remove", role: .destructive) { model.uninstall(entry.id) }.buttonStyle(.borderless)
            }
        } else {
            Button("Install") { install(entry, index) }.buttonStyle(.bordered)
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
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
