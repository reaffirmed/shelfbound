import DownloadKit
import ShelfCore
import SwiftUI

/// Storage, automatic downloads and the queue, as in the mockup.
@MainActor
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDeleteAll = false

    var body: some View {
        @Bindable var model = model
        let snapshot = model.downloads
        Form {
            Section { StorageSummary(snapshot: snapshot, limit: model.settings.downloads.storageLimitBytes) }

            Section {
                Toggle(isOn: $model.settings.downloads.autoDownload) {
                    VStack(alignment: .leading) {
                        Text("Download new chapters")
                        Text("For works in your library").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Only on Wi-Fi", isOn: $model.settings.downloads.wifiOnly)
                Toggle(isOn: $model.settings.downloads.cellularForText) {
                    VStack(alignment: .leading) {
                        Text("Allow fics on cellular")
                        Text("Fics are tiny, about 50 KB a chapter").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!model.settings.downloads.wifiOnly)
                Stepper(value: $model.settings.downloads.downloadAhead, in: 0...10) {
                    VStack(alignment: .leading) {
                        Text("Download ahead")
                        Text(model.settings.downloads.downloadAhead == 0 ? "Off" : "Next \(model.settings.downloads.downloadAhead) unread chapters")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!model.settings.downloads.autoDownload)
            } header: {
                Text("Automatic downloads")
            } footer: {
                Text("New chapters download in the background when iOS allows it. Manhwa chapters are the largest, often 10 to 20 MB each.")
            }

            Section("Storage limit") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Keep up to")
                        Spacer()
                        Text("\(gigabytes) GB").bold().monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(gigabytes) },
                        set: { model.settings.downloads.storageLimitBytes = Int64($0.rounded()) * 1_000_000_000 }
                    ), in: 1...32, step: 1) {
                        Text("Storage limit")
                    } minimumValueLabel: {
                        Text("1 GB").font(.caption2)
                    } maximumValueLabel: {
                        Text("32 GB").font(.caption2)
                    }
                }
                Picker("When the limit is reached", selection: $model.settings.downloads.whenFull) {
                    ForEach(FullStoragePolicy.allCases) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $model.settings.downloads.removeAfterReading) {
                    VStack(alignment: .leading) {
                        Text("Remove chapters after reading")
                        Text("Fics are always kept").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if snapshot.jobs.isEmpty {
                    Text("Nothing waiting").foregroundStyle(.secondary)
                }
                ForEach(snapshot.jobs) { job in
                    QueueRow(job: job)
                        .swipeActions {
                            Button("Cancel", role: .destructive) { Task { await model.downloadManager.cancel(job.ref) } }
                            if job.isFailed {
                                Button("Retry") { Task { await model.downloadManager.retry(job.ref) } }.tint(.shelfAccent)
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Queue (\(snapshot.jobs.count))")
                    Spacer()
                    if !snapshot.jobs.isEmpty {
                        Button(model.settings.downloads.paused ? "Resume all" : "Pause all") {
                            model.settings.downloads.paused.toggle()
                        }
                        .font(.subheadline)
                        .textCase(nil)
                    }
                }
            }

            Section("Manage") {
                NavigationLink("Review downloads by title") { DownloadedWorksView() }
                Button("Delete all downloads", role: .destructive) { confirmingDeleteAll = true }
                    .disabled(snapshot.downloaded.isEmpty && snapshot.jobs.isEmpty)
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete all downloads?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete \(snapshot.totalBytes.byteString)", role: .destructive) {
                Task { await model.downloadManager.deleteAll() }
            }
        } message: {
            Text("Chapters stay in your library and can be downloaded again.")
        }
    }

    private var gigabytes: Int { Int((Double(model.settings.downloads.storageLimitBytes) / 1_000_000_000).rounded()) }
}

@MainActor
struct StorageSummary: View {
    let snapshot: DownloadSnapshot
    let limit: Int64

    var body: some View {
        let parts: [(String, Int64, Color)] = [
            ("Fics", snapshot.bytes(for: .fics), .shelfAccent),
            ("Manga", snapshot.bytes(for: .manga), Color(hex: "#6B6FE0")),
            ("Manhwa", snapshot.bytes(for: .manhwa), Color(hex: "#E0954A")),
        ]
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(snapshot.totalBytes.byteString).font(.title.weight(.bold))
                Text("of \(limit.byteString) used").foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { part in
                        let fraction = limit > 0 ? CGFloat(part.1) / CGFloat(limit) : 0
                        Rectangle().fill(part.2).frame(width: max(part.1 > 0 ? 3 : 0, geo.size.width * min(1, fraction)))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .background(Color(.tertiarySystemFill))
            .clipShape(Capsule())
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.2).frame(width: 8, height: 8)
                        Text("\(part.0) \(part.1.byteString)")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if snapshot.overLimit {
                Text("At the limit. Image chapters wait until space frees up.")
                    .font(.footnote).foregroundStyle(Color.shelfBadge)
            }
        }
        .padding(.vertical, 6)
    }
}

@MainActor
struct QueueRow: View {
    let job: DownloadJob

    var body: some View {
        HStack(spacing: 12) {
            CoverView(title: job.request.workTitle, format: job.request.format, url: job.request.coverURL, compact: true)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.request.workTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(job.isFailed ? Color.shelfWarning : Color.secondary).lineLimit(2)
                if job.pageCount > 0 && !job.isFailed { ProgressBar(value: job.progress, height: 3) }
            }
        }
    }

    private var status: String {
        let chapter = job.request.chapterTitle
        if case let .failed(message) = job.state { return "\(chapter) · Failed: \(message). Swipe to retry." }
        if let note = job.note { return "\(chapter) · \(note)" }
        switch job.state {
        case .waiting: return "\(chapter) · Waiting"
        case .resolving: return "\(chapter) · Getting pages…"
        case .downloading: return "\(chapter) · \(job.pagesDone) of \(job.pageCount) pages"
        case .failed: return chapter
        }
    }
}

@MainActor
struct DownloadedWorksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.downloads.byWork, id: \.work) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(item.count == 1 ? "1 chapter" : "\(item.count) chapters").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.bytes.byteString).foregroundStyle(.secondary).monospacedDigit()
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { model.deleteDownloads(of: item.work) }
                }
            }
        }
        .overlay {
            if model.downloads.downloaded.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle("Downloads by title")
        .navigationBarTitleDisplayMode(.inline)
    }
}
