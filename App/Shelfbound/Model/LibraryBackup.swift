import Foundation
import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything needed to rebuild Shelfbound on a reinstall or a new phone: the library with
/// reading positions, highlights and per-work settings, the app's settings, and which repos
/// and sources were installed. Sign-ins aren't included, since cookies are secrets.
struct LibraryBackup: Codable {
    static let currentFormat = 1

    var format = LibraryBackup.currentFormat
    var createdAt = Date()
    var appVersion = AppModel.appVersion
    var library: LibraryState
    var settings: AppSettings?
    var repos: [SavedRepo]
    /// IDs of the sources that were installed.
    var sources: [String]

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decode(_ data: Data) throws -> LibraryBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LibraryBackup.self, from: data)
        guard backup.format <= currentFormat else { throw BackupError.newerFormat }
        return backup
    }

    var fileName: String {
        "Shelfbound backup \(createdAt.formatted(.iso8601.year().month().day())).json"
    }
}

enum BackupError: LocalizedError {
    case newerFormat

    var errorDescription: String? {
        "This backup is from a newer version of Shelfbound. Update the app, then restore it."
    }
}

/// The backup as a file for the share sheet and Files.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// What a restore did, for the confirmation message.
struct RestoreReport {
    var works = 0
    var repos = 0
    var sourcesInstalled = 0
    var sourcesMissing: [String] = []

    var summary: String {
        var parts = ["Restored \(works) works"]
        if repos > 0 { parts.append("\(repos) repositories") }
        if sourcesInstalled > 0 { parts.append("\(sourcesInstalled) sources") }
        var text = parts.joined(separator: ", ") + "."
        if !sourcesMissing.isEmpty {
            text += " Couldn't reinstall \(sourcesMissing.count) source(s); add their repository again and install them."
        }
        return text + " Sign in to your accounts again in Settings > Accounts."
    }
}
