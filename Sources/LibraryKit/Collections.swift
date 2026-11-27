import Foundation
import ShelfCore

/// A search in one source the person kept: the text and filters, and which results they
/// have already seen, so the app can say how many are new since they last looked.
public struct SavedSearch: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sourceID: String
    public var name: String
    public var query: String
    public var filters: [String: [String]]
    /// IDs of results seen so far, newest last. Capped, see `markSeen`.
    public var seenIDs: [String]
    /// Results on the first page that weren't seen, as of the last check.
    public var newCount: Int
    public var createdAt: Date
    public var checkedAt: Date?

    public init(
        id: UUID = UUID(), sourceID: String, name: String, query: String, filters: [String: [String]],
        seenIDs: [String] = [], createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.query = query
        self.filters = filters
        self.seenIDs = seenIDs
        self.newCount = 0
        self.createdAt = createdAt
    }

    /// Filters without the empty entries, so "nothing picked" compares the same however it's stored.
    public static func normalized(_ filters: [String: [String]]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (key, values) in filters {
            let kept = values.filter { !$0.isEmpty }
            if !kept.isEmpty { out[key] = kept }
        }
        return out
    }

    /// Whether this is the search for `query` with `filters`.
    public func matches(sourceID: String, query: String, filters: [String: [String]]) -> Bool {
        self.sourceID == sourceID
            && self.query.trimmingCharacters(in: .whitespaces).lowercased() == query.trimmingCharacters(in: .whitespaces).lowercased()
            && Self.normalized(self.filters) == Self.normalized(filters)
    }

    /// The results in `ids` that haven't been seen.
    public func newIDs(in ids: [String]) -> [String] {
        let seen = Set(seenIDs)
        return ids.filter { !seen.contains($0) }
    }

    /// A check for new results came back with `ids` on the first page.
    public mutating func checked(_ ids: [String], at date: Date = Date()) {
        newCount = newIDs(in: ids).count
        checkedAt = date
    }

    /// The person looked at `ids`. Keeps the most recent `limit` IDs.
    public mutating func markSeen(_ ids: [String], at date: Date = Date(), limit: Int = 400) {
        var seen = Set(seenIDs)
        for id in ids where seen.insert(id).inserted { seenIDs.append(id) }
        if seenIDs.count > limit { seenIDs.removeFirst(seenIDs.count - limit) }
        newCount = 0
        checkedAt = date
    }

    /// A name for a search nobody named: the text, else the picked filter values.
    public static func suggestedName(query: String, filters: [String: [String]], defaults: [String: [String]] = [:]) -> String {
        let text = query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return text }
        let base = normalized(defaults)
        let picked = normalized(filters)
            .filter { base[$0.key] != $0.value }
            .sorted { $0.key < $1.key }
            .flatMap { entry in entry.key.hasSuffix(".exclude") ? entry.value.map { "not " + $0 } : entry.value }
            // Option IDs that are only numbers or flags say nothing as a name.
            .filter { $0.rangeOfCharacter(from: .letters) != nil && $0 != "true" }
        return picked.isEmpty ? "Saved search" : picked.prefix(3).joined(separator: ", ")
    }
}

/// A shelf the person made, holding any works from the library. A work can sit on several.
public struct CustomShelf: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// `WorkKey.id` of each work, in the order added.
    public var workIDs: [String]

    public init(id: UUID = UUID(), name: String, workIDs: [String] = []) {
        self.id = id
        self.name = name
        self.workIDs = workIDs
    }

    public func contains(_ key: WorkKey) -> Bool { workIDs.contains(key.id) }
}

extension LibraryState {
    public var allSavedSearches: [SavedSearch] { savedSearches ?? [] }
    public var allShelves: [CustomShelf] { shelves ?? [] }

    public mutating func updateSavedSearch(_ id: UUID, _ change: (inout SavedSearch) -> Void) {
        guard var list = savedSearches, let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        savedSearches = list
    }

    public mutating func removeSavedSearch(_ id: UUID) {
        savedSearches?.removeAll { $0.id == id }
    }

    /// Makes a shelf, or returns the one already called that.
    @discardableResult
    public mutating func addShelf(named name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let existing = allShelves.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing.id
        }
        let shelf = CustomShelf(name: trimmed)
        shelves = allShelves + [shelf]
        return shelf.id
    }

    public mutating func renameShelf(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var list = shelves, let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].name = trimmed
        shelves = list
    }

    public mutating func removeShelf(_ id: UUID) {
        shelves?.removeAll { $0.id == id }
    }

    /// Puts works on a shelf, or takes them off.
    public mutating func setShelf(_ id: UUID, contains: Bool, _ keys: [WorkKey]) {
        guard var list = shelves, let index = list.firstIndex(where: { $0.id == id }) else { return }
        let ids = keys.map(\.id)
        if contains {
            var present = Set(list[index].workIDs)
            for workID in ids where present.insert(workID).inserted { list[index].workIDs.append(workID) }
        } else {
            let removing = Set(ids)
            list[index].workIDs.removeAll { removing.contains($0) }
        }
        shelves = list
    }

    /// A work that moved to another source keeps its shelves.
    public mutating func moveShelfMembership(from old: WorkKey, to new: WorkKey) {
        guard var list = shelves else { return }
        for index in list.indices {
            guard let at = list[index].workIDs.firstIndex(of: old.id) else { continue }
            if list[index].workIDs.contains(new.id) {
                list[index].workIDs.remove(at: at)
            } else {
                list[index].workIDs[at] = new.id
            }
        }
        shelves = list
    }
}
