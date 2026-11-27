import LibraryKit
import ShelfCore
import SwiftUI

/// Everything read lately, newest first and grouped by day, whether it's in the library
/// or was only opened from a search. Tap to pick up where you left off.
@MainActor
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var reading: ReaderRequest?
    @State private var query = ""
    @State private var confirmingClear = false
    @State private var detail: WorkRoute?

    /// `history` is sorted each time it's asked for, so the screen asks once per redraw.
    private func matching(_ all: [WorkRecord]) -> [WorkRecord] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) || $0.summary.authors.contains { $0.lowercased().contains(q) } }
    }

    var body: some View {
        let history = model.library.history
        let records = matching(history)
        NavigationStack {
            List {
                ForEach(Self.days(records), id: \.title) { day in
                    Section(day.title) {
                        ForEach(day.records) { record in row(record) }
                    }
                }
            }
            .overlay {
                if history.isEmpty {
                    ContentUnavailableView(
                        "Nothing read yet", systemImage: "clock",
                        description: Text("Works you open in the reader show up here, newest first."))
                } else if records.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("History")
            .searchable(text: $query, prompt: "Search history")
            .toolbar {
                if !history.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear", role: .destructive) { confirmingClear = true }
                    }
                }
            }
            .confirmationDialog("Clear your reading history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear older than a month", role: .destructive) {
                    let cutoff = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
                    clear(history.filter { ($0.lastReadAt ?? .distantPast) < cutoff })
                }
                Button("Clear all history", role: .destructive) { clear(history) }
            } message: {
                Text("Works in your library stay there and keep their place in the reader.")
            }
            .navigationDestination(for: WorkRoute.self) { WorkDetailView(route: $0) }
            .navigationDestination(item: $detail) { WorkDetailView(route: $0) }
            .fullScreenCover(item: $reading) { ReaderView(request: $0) }
        }
    }

    private func row(_ record: WorkRecord) -> some View {
        Button { open(record) } label: {
            HStack(spacing: 12) {
                BadgedCover(record: record, showBadge: false, compact: true).frame(width: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(record.progressLine ?? record.position?.chapterTitle ?? model.sourceName(record.key.sourceID))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(model.sourceName(record.key.sourceID))
                        if let at = record.lastReadAt { Text("·"); Text(at, style: .time) }
                        if !record.inLibrary { Text("·"); Text("Not in library") }
                    }
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let progress = record.position?.progress { ProgressBar(value: progress).padding(.top, 2) }
                }
                Spacer(minLength: 0)
                Button { detail = WorkRoute(key: record.key, summary: record.summary) } label: {
                    Image(systemName: "info.circle").imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Details")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button("Remove", role: .destructive) { model.removeFromHistory(record.key) }
        }
        .contextMenu {
            Button { detail = WorkRoute(key: record.key, summary: record.summary) } label: {
                Label("Details", systemImage: "info.circle")
            }
            Button(role: .destructive) { model.removeFromHistory(record.key) } label: {
                Label("Remove from history", systemImage: "trash")
            }
        }
        .accessibilityIdentifier("history.row")
    }

    /// Works in the library keep their reading place; ones only opened from a search lose it
    /// with the rest of their history.
    private func clear(_ records: [WorkRecord]) {
        for record in records { model.removeFromHistory(record.key, keepPlace: record.inLibrary) }
    }

    /// Back into the reader where it was left, or the work's page if there's no place yet.
    private func open(_ record: WorkRecord) {
        if let chapter = record.position?.chapterID ?? record.continueChapter?.id {
            reading = ReaderRequest(key: record.key, chapterID: chapter)
        } else {
            detail = WorkRoute(key: record.key, summary: record.summary)
        }
    }

    /// Today, Yesterday, then one section per day for the past week, then by month.
    static func days(_ records: [WorkRecord], now: Date = Date(), calendar: Calendar = .current) -> [(title: String, records: [WorkRecord])] {
        var order: [String] = []
        var groups: [String: [WorkRecord]] = [:]
        let today = calendar.startOfDay(for: now)
        for record in records {
            guard let at = record.lastReadAt else { continue }
            let day = calendar.startOfDay(for: at)
            let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            let title: String
            switch daysAgo {
            case ..<1: title = "Today"
            case 1: title = "Yesterday"
            case 2..<7: title = at.formatted(.dateTime.weekday(.wide))
            default: title = at.formatted(.dateTime.month(.wide).year())
            }
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(record)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}
