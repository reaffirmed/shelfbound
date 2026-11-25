import AppIntents
import LibraryKit
import ShelfCore
import SwiftUI

// Shortcuts and Siri. The intents live in the app target, so they run in the app's
// own process and read the same library as the app.

/// A work in the library, for "Open … in Shelfbound" and Shortcuts parameters.
struct WorkEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Work")
    static var defaultQuery = WorkQuery()

    var id: String
    var title: String
    var subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(_ record: WorkRecord) {
        id = record.key.id
        title = record.title
        subtitle = [record.authors.first, record.unreadNewCount > 0 ? "\(record.unreadNewCount) new" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct WorkQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [WorkEntity] {
        let records = AppModel.shared.library.records
        return identifiers.compactMap { records[$0] }.map(WorkEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [WorkEntity] {
        let needle = string.lowercased()
        return AppModel.shared.library.library
            .filter { $0.title.lowercased().contains(needle) || $0.authors.contains { $0.lowercased().contains(needle) } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map(WorkEntity.init)
    }

    /// Recently read first, so the picker opens on what you're reading.
    @MainActor
    func suggestedEntities() async throws -> [WorkEntity] {
        AppModel.shared.library.library
            .sorted { ($0.lastReadAt ?? $0.addedAt ?? .distantPast) > ($1.lastReadAt ?? $1.addedAt ?? .distantPast) }
            .prefix(30).map(WorkEntity.init)
    }
}

struct ContinueReadingIntent: AppIntent {
    static var title: LocalizedStringResource = "Continue Reading"
    static var description = IntentDescription("Opens the work you read last at your place, or a work you pick.")
    static var openAppWhenRun = true

    @Parameter(title: "Work")
    var work: WorkEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        let record: WorkRecord?
        if let work {
            record = model.library.records[work.id]
        } else {
            record = model.library.history.first { $0.inLibrary } ?? model.library.history.first
        }
        guard let record else { throw IntentFailure.nothingToContinue }
        model.pendingContinue = record.key
        return .result()
    }
}

struct OpenWorkIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Work"
    static var description = IntentDescription("Shows a work's page in Shelfbound.")
    static var openAppWhenRun = true

    @Parameter(title: "Work")
    var work: WorkEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$work)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let record = AppModel.shared.library.records[work.id] else { throw IntentFailure.notInLibrary }
        AppModel.shared.pendingOpen = record.key
        return .result()
    }
}

struct CheckForUpdatesIntent: AppIntent {
    static var title: LocalizedStringResource = "Check for New Chapters"
    static var description = IntentDescription("Checks every work in your library for new chapters and says how many it found.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let report = await AppModel.shared.checkForUpdates()
        let chapters = report.found.reduce(0) { $0 + $1.newChapters.count }
        let dialog: IntentDialog
        switch report.found.count {
        case 0: dialog = "No new chapters."
        case 1: dialog = "\(chapters) new \(chapters == 1 ? "chapter" : "chapters") in \(report.found[0].title)."
        default: dialog = "\(chapters) new chapters across \(report.found.count) works."
        }
        return .result(value: chapters, dialog: dialog)
    }
}

struct NewChapterCountIntent: AppIntent {
    static var title: LocalizedStringResource = "Get New Chapter Count"
    static var description = IntentDescription("The number of new chapters you haven't read yet, without checking again.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = AppModel.shared.library.newChapterCount
        return .result(value: count, dialog: count == 0 ? "You're caught up." : "\(count) new \(count == 1 ? "chapter" : "chapters") to read.")
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case nothingToContinue, notInLibrary

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingToContinue: "You haven't started reading anything yet."
        case .notInLibrary: "That work isn't in your library any more."
        }
    }
}

struct ShelfboundShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueReadingIntent(),
            phrases: ["Continue reading in \(.applicationName)", "Resume \(.applicationName)"],
            shortTitle: "Continue Reading", systemImageName: "book")
        AppShortcut(
            intent: CheckForUpdatesIntent(),
            phrases: ["Check \(.applicationName) for new chapters", "Any new chapters in \(.applicationName)"],
            shortTitle: "Check for New Chapters", systemImageName: "bell.badge")
        AppShortcut(
            intent: NewChapterCountIntent(),
            phrases: ["How many new chapters in \(.applicationName)"],
            shortTitle: "New Chapter Count", systemImageName: "number")
        AppShortcut(
            intent: OpenWorkIntent(),
            phrases: ["Open \(\.$work) in \(.applicationName)"],
            shortTitle: "Open Work", systemImageName: "books.vertical")
    }
}
