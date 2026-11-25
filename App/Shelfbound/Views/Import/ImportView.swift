import LibraryKit
import ShelfCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Import library: a backup from another reader app (sideload build only), or
/// pasted links (bookmarks, a reading list). Works are matched to installed sources, so install those first.
@MainActor
struct ImportView: View {
    @Environment(AppModel.self) private var model
    @State private var session = LibraryImport()
    @State private var choosingFile = false
    @State private var links = ""
    @State private var error: String?

    var body: some View {
        Form {
            if session.items.isEmpty {
                chooser
            } else {
                progress
                results
            }
        }
        .navigationTitle("Import library")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data, .zip, .json, .propertyList, .plainText]) { result in
            do {
                try session.load(fileAt: try result.get())
                error = nil
            } catch {
                self.error = error.readable
            }
        }
        .onDisappear { session.stop() }
    }

    private var chooser: some View {
        Group {
            if !AppFlavor.isAppStore {
                Section {
                    Button { choosingFile = true } label: { Label("Choose a backup file", systemImage: "doc.badge.arrow.up") }
                } footer: {
                    Text("A Paperback backup (.pas4) or an Aidoku backup (.aib). Export it from that app's settings, then pick it here.")
                }
            }
            Section {
                TextField("Paste links, one per line", text: $links, axis: .vertical)
                    .lineLimit(4...10)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Import links") {
                    do { try session.load(links: links); error = nil } catch { self.error = error.readable }
                }
                .disabled(links.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Links")
            } footer: {
                Text("Links to works on any site a source of yours reads, such as your bookmarks there.")
            }
            if let error {
                Section { Text(error).foregroundStyle(Color.shelfWarning) }
            }
            if model.searchableSources.isEmpty {
                Section {
                    Text("Install sources first. Shelfbound finds each work on your sources and keeps your read chapters.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var progress: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(session.added) of \(session.items.count) added")
                    .font(.headline)
                ProgressView(value: Double(session.done), total: Double(max(1, session.items.count)))
                Text(session.running
                     ? "Searching your sources. Sites are asked gently, so this can take a while."
                     : session.done == session.items.count ? "Done." : "Paused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if session.running {
                Button("Pause", role: .cancel) { session.stop() }
            } else if session.done < session.items.count {
                Button(session.done == 0 ? "Start import" : "Continue") { session.start(model: model) }
                    .disabled(model.searchableSources.isEmpty)
            }
        } header: {
            Text("From \(session.origin?.rawValue ?? "file")")
        }
    }

    private var results: some View {
        Section("Works") {
            ForEach(session.items) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle).lineLimit(2)
                        detail(item)
                    }
                    Spacer()
                    icon(item.status)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(_ item: LibraryImport.Item) -> some View {
        let read = item.work.readChapterNumbers.count
        switch item.status {
        case let .added(_, sourceName):
            Text(read > 0 ? "On \(sourceName), \(read) chapters read" : "On \(sourceName)")
                .font(.caption).foregroundStyle(.secondary)
        case let .notFound(reason):
            Text(reason).font(.caption).foregroundStyle(Color.shelfWarning)
        case .waiting, .searching:
            if read > 0 { Text("\(read) chapters read").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private func icon(_ status: LibraryImport.Status) -> some View {
        switch status {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .searching: ProgressView()
        case .added: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.shelfAccent)
        case .notFound: Image(systemName: "questionmark.circle").foregroundStyle(Color.shelfWarning)
        }
    }
}
