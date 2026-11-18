import ActivityKit
import ShelfCore
import SwiftUI
import WidgetKit

@main
struct ShelfboundWidgets: WidgetBundle {
    var body: some Widget {
        ContinueReadingWidget()
        NewChaptersWidget()
        DownloadLiveActivity()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Reads the snapshot the app writes. The app reloads the widgets whenever it changes,
/// so one entry is enough; a refresh every few hours catches anything missed.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snapshot: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? .sample : (WidgetSnapshot.load() ?? .sample)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? WidgetSnapshot())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(4 * 3600))))
    }
}

extension WidgetSnapshot {
    static let sample = WidgetSnapshot(
        continueReading: [
            Item(key: WorkKey(sourceID: "s", workID: "1"), title: "Hollow Tide", subtitle: "Ch. 85 of 87", progress: 0.97, newCount: 2, format: .manhwa),
            Item(key: WorkKey(sourceID: "s", workID: "2"), title: "Tea at the Edge of the World", subtitle: "Chapter 9 of 20", progress: 0.45, newCount: 0, format: .fic),
            Item(key: WorkKey(sourceID: "s", workID: "3"), title: "Lantern Street", subtitle: "Ch. 12 of 40", progress: 0.3, newCount: 1, format: .manga),
        ],
        newChapters: [
            Item(key: WorkKey(sourceID: "s", workID: "1"), title: "Hollow Tide", subtitle: "Ch. 86", progress: 0.97, newCount: 2, format: .manhwa),
            Item(key: WorkKey(sourceID: "s", workID: "3"), title: "Lantern Street", subtitle: "Ch. 13", progress: 0.3, newCount: 1, format: .manga),
        ],
        totalNew: 3)
}

// MARK: - Shared pieces

private let accent = Color(red: 0.16, green: 0.45, blue: 0.40)
private let badgeRed = Color(red: 0.86, green: 0.23, blue: 0.20)

/// A stable colour per title, the same idea as the app's generated covers.
private func hue(_ text: String) -> Double {
    var hash: UInt64 = 5381
    for byte in text.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
    return Double(hash % 360) / 360
}

struct WidgetCover: View {
    let item: WidgetSnapshot.Item

    var body: some View {
        Group {
            if let file = item.coverFile,
               let url = WidgetSnapshot.container?.appendingPathComponent(WidgetSnapshot.coversFolder).appendingPathComponent(file),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack(alignment: .bottomLeading) {
                    Color(hue: hue(item.title), saturation: item.format.isText ? 0.32 : 0.55, brightness: item.format.isText ? 0.93 : 0.55)
                    Text(item.title)
                        .font(.system(size: 9, weight: .semibold, design: item.format.isText ? .serif : .default))
                        .foregroundStyle(item.format.isText ? Color(hue: hue(item.title), saturation: 0.55, brightness: 0.28) : .white)
                        .lineLimit(3)
                        .padding(4)
                }
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct ProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(accent).frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Continue reading

struct ContinueReadingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueReading", provider: SnapshotProvider()) { entry in
            ContinueReadingView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Continue reading")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct ContinueReadingView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        if let first = snapshot.continueReading.first {
            switch family {
            case .accessoryInline:
                Text("\(first.title) · \(first.subtitle)")
                    .widgetURL(first.link)
            case .accessoryCircular:
                Gauge(value: first.progress) { Image(systemName: "book") }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .widgetURL(first.link)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text(first.title).font(.headline).lineLimit(1)
                    Text(first.subtitle).font(.caption).lineLimit(1)
                    Gauge(value: first.progress) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
                }
                .widgetURL(first.link)
            case .systemMedium:
                HStack(spacing: 10) {
                    ForEach(snapshot.continueReading.prefix(3)) { item in
                        Link(destination: item.link) { tile(item) }
                    }
                }
            default:
                tile(first).widgetURL(first.link)
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "books.vertical").font(.title2).foregroundStyle(accent)
                Text("Start reading something and it shows here.").font(.caption).multilineTextAlignment(.center)
            }
        }
    }

    private func tile(_ item: WidgetSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            WidgetCover(item: item)
                .overlay(alignment: .topTrailing) {
                    if item.newCount > 0 {
                        Text("\(item.newCount)").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 5).background(Capsule().fill(badgeRed))
                    }
                }
            Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
            Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            ProgressLine(value: item.progress)
        }
    }
}

// MARK: - New chapters

struct NewChaptersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NewChapters", provider: SnapshotProvider()) { entry in
            NewChaptersView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("New chapters")
        .description("What's been posted since you last read.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct NewChaptersView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(snapshot.totalNew == 0 ? "No new chapters" : "\(snapshot.totalNew) new chapters")
        case .accessoryCircular:
            VStack(spacing: 0) {
                Text("\(snapshot.totalNew)").font(.title2.bold())
                Text("new").font(.caption2)
            }
            .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.totalNew == 0 ? "All caught up" : "\(snapshot.totalNew) new chapters").font(.headline)
                ForEach(snapshot.newChapters.prefix(2)) { item in
                    Text("\(item.title) +\(item.newCount)").font(.caption).lineLimit(1)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(snapshot.totalNew)").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(snapshot.totalNew > 0 ? badgeRed : .secondary)
                    Text("new").font(.subheadline).foregroundStyle(.secondary)
                }
                if snapshot.newChapters.isEmpty {
                    Text("All caught up").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.newChapters.prefix(3)) { item in
                    Link(destination: item.link) {
                        HStack {
                            Text(item.title).font(.caption).lineLimit(1)
                            Spacer(minLength: 2)
                            Text("+\(item.newCount)").font(.caption.bold().monospacedDigit()).foregroundStyle(badgeRed)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Download Live Activity

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.paused ? "pause.circle.fill" : "arrow.down.circle.fill")
                    .font(.title).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.chaptersLeft == 0 ? "Downloads finished" : "Downloading \(context.state.chaptersLeft) chapters")
                        .font(.headline)
                    Text(context.state.paused ? "Paused: a site wants a browser check" : context.state.current)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: context.state.progress).tint(accent)
                }
            }
            .padding()
            .activityBackgroundTint(Color(.systemBackground).opacity(0.9))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.chaptersLeft) left").font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(context.state.current).font(.caption).lineLimit(1)
                        ProgressView(value: context.state.progress).tint(accent)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(accent)
            } compactTrailing: {
                Text("\(context.state.chaptersLeft)").font(.caption.monospacedDigit())
            } minimal: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(accent)
            }
        }
    }
}
