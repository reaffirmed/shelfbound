import Foundation
import LibraryKit
import Observation
import ShelfCore
import SourceKit
import ZIPFoundation

/// Brings works from another app's backup (or a list of links) into the library. Each work
/// is found on an installed source: by its link when a source recognises it, else by
/// searching for its title. Read chapters carry over by chapter number.
@MainActor
@Observable
final class LibraryImport {
    enum Status: Equatable {
        case waiting
        case searching
        case added(WorkKey, sourceName: String)
        case notFound(String)
    }

    struct Item: Identifiable {
        let work: ImportedWork
        var status: Status = .waiting
        var id: String { work.id }
        var displayTitle: String { work.title.isEmpty ? (work.url?.absoluteString ?? "Untitled") : work.title }
    }

    private(set) var origin: ImportBatch.Origin?
    private(set) var items: [Item] = []
    private(set) var running = false
    private var task: Task<Void, Never>?

    var done: Int { items.filter { if case .waiting = $0.status { return false }; if case .searching = $0.status { return false }; return true }.count }
    var added: Int { items.filter { if case .added = $0.status { return true }; return false }.count }

    /// Reads a Paperback backup (zip), an Aidoku backup, or a text file of links.
    func load(fileAt url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        var files = [url.lastPathComponent: data]
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { files = try Self.unzip(url) }
        let batch = try LibraryImporter.parse(files: files)
        set(batch)
    }

    func load(links text: String) throws {
        let batch = LinkList.parse(text)
        guard !batch.works.isEmpty else { throw ImportError.empty }
        set(batch)
    }

    private func set(_ batch: ImportBatch) {
        guard !batch.works.isEmpty else { return }
        origin = batch.origin
        items = batch.works.map { Item(work: $0) }
    }

    func start(model: AppModel) {
        guard !running else { return }
        running = true
        task = Task {
            for index in items.indices {
                guard !Task.isCancelled else { break }
                guard case .waiting = items[index].status else { continue }
                items[index].status = .searching
                items[index].status = await importOne(items[index].work, model: model)
            }
            running = false
            model.saveNow()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
        for index in items.indices where items[index].status == .searching { items[index].status = .waiting }
    }

    // MARK: - One work

    private func importOne(_ work: ImportedWork, model: AppModel) async -> Status {
        if let url = work.url {
            for source in model.searchableSources where DomainPolicy(patterns: source.manifest.domains).allows(url) {
                guard let runtime = try? model.runtime(for: source.id),
                      let id = try? await runtime.workID(forURL: url) else { continue }
                let key = WorkKey(sourceID: source.id, workID: id)
                if await add(work, key: key, summary: WorkSummary(id: id, title: work.title, authors: work.authors), model: model) {
                    return .added(key, sourceName: source.manifest.name)
                }
            }
            if work.title.isEmpty { return .notFound("No installed source reads \(url.host ?? "that site").") }
        }
        for source in candidates(for: work, among: model.searchableSources) {
            guard let runtime = try? model.runtime(for: source.id),
                  let page = try? await runtime.search(query: work.title, page: 1),
                  let match = TitleMatcher.best(for: work.title, authors: work.authors, among: page.results)
            else { continue }
            let key = WorkKey(sourceID: source.id, workID: match.id)
            if await add(work, key: key, summary: match, model: model) {
                return .added(key, sourceName: source.manifest.name)
            }
        }
        return .notFound("Not found on your installed sources.")
    }

    /// The source with the same name as the old app's first, then the rest. Text and image
    /// sources aren't mixed unless nothing else is installed.
    private func candidates(for work: ImportedWork, among sources: [InstalledSource]) -> [InstalledSource] {
        let wanted = TitleMatcher.normalize(work.sourceName ?? "").replacingOccurrences(of: " ", with: "")
        func sameName(_ source: InstalledSource) -> Bool {
            guard !wanted.isEmpty else { return false }
            let name = TitleMatcher.normalize(source.manifest.name).replacingOccurrences(of: " ", with: "")
            return name.contains(wanted) || wanted.contains(name)
        }
        // Paperback and Aidoku are image readers, so prefer image sources for their backups.
        let preferImages = origin == .paperback || origin == .aidoku
        let fitting = sources.filter { !preferImages || $0.manifest.kind == .images }
        let pool = fitting.isEmpty ? sources : fitting
        return pool.filter(sameName) + pool.filter { !sameName($0) }
    }

    private func add(_ work: ImportedWork, key: WorkKey, summary: WorkSummary, model: AppModel) async -> Bool {
        do {
            try await model.refreshWork(key, summary: summary)
        } catch {
            return false
        }
        guard let record = model.record(key) else { return false }
        let readIDs = work.readChapterNumbers.isEmpty
            ? work.lastReadChapterNumber.map { ChapterMatcher.ids(in: record.chapters, through: $0) } ?? []
            : ChapterMatcher.ids(in: record.chapters, numbered: work.readChapterNumbers)
        model.updateRecord(key) { record in
            record.inLibrary = true
            record.addedAt = record.addedAt ?? work.addedAt ?? Date()
            record.readChapterIDs.formUnion(readIDs)
            record.newChapterIDs.removeAll { readIDs.contains($0) }
            if let last = work.lastReadAt, readIDs.count > 0 {
                record.lastReadAt = max(record.lastReadAt ?? last, last)
                if let chapter = record.readingOrder.last(where: { readIDs.contains($0.id) }) {
                    record.position = ReadingPosition(chapterID: chapter.id, chapterTitle: chapter.title, progress: 1, updatedAt: last)
                }
            }
        }
        return true
    }

    // MARK: - Zip

    /// Paperback backups are zips of JSON tables. Capped so a hostile file can't fill memory.
    static func unzip(_ url: URL) throws -> [String: Data] {
        let archive = try Archive(url: url, accessMode: .read)
        var files: [String: Data] = [:]
        var total: UInt64 = 0
        for entry in archive where entry.type == .file {
            total += entry.uncompressedSize
            guard total < 300_000_000 else { throw ImportError.unrecognised }
            var data = Data()
            _ = try archive.extract(entry, skipCRC32: false) { data.append($0) }
            files[entry.path] = data
        }
        return files
    }
}
