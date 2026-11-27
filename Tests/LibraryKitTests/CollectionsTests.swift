import Foundation
import ShelfCore
import XCTest
@testable import LibraryKit

final class CollectionsTests: XCTestCase {
    func testSavedSearchCountsOnlyResultsNotSeenBefore() {
        var search = SavedSearch(sourceID: "src", name: "Slow burn", query: "slow burn", filters: [:], seenIDs: ["1", "2", "3"])
        search.checked(["5", "4", "3", "2"])
        XCTAssertEqual(search.newCount, 2)
        XCTAssertEqual(search.newIDs(in: ["5", "4", "3", "2"]), ["5", "4"])
        search.markSeen(["5", "4", "3", "2"])
        XCTAssertEqual(search.newCount, 0)
        XCTAssertEqual(search.seenIDs, ["1", "2", "3", "5", "4"])
        search.checked(["5", "4", "3"])
        XCTAssertEqual(search.newCount, 0)
    }

    func testSavedSearchKeepsOnlyTheMostRecentSeenIDs() {
        var search = SavedSearch(sourceID: "src", name: "n", query: "q", filters: [:])
        search.markSeen((1...10).map(String.init), limit: 4)
        XCTAssertEqual(search.seenIDs, ["7", "8", "9", "10"])
    }

    func testSavedSearchMatchesIgnoringEmptyFiltersAndCase() {
        let search = SavedSearch(sourceID: "src", name: "n", query: "Slow Burn", filters: ["rating": ["12"], "tags": []])
        XCTAssertTrue(search.matches(sourceID: "src", query: " slow burn ", filters: ["rating": ["12"], "sort": [""]]))
        XCTAssertFalse(search.matches(sourceID: "src", query: "slow burn", filters: ["rating": ["13"]]))
        XCTAssertFalse(search.matches(sourceID: "other", query: "slow burn", filters: ["rating": ["12"]]))
    }

    func testSuggestedNameUsesTheTextThenThePickedFilters() {
        XCTAssertEqual(SavedSearch.suggestedName(query: " dragons ", filters: [:]), "dragons")
        XCTAssertEqual(
            SavedSearch.suggestedName(
                query: "", filters: ["genres": ["Romance"], "genres.exclude": ["Horror"], "language": ["en"], "rating": ["12"]],
                defaults: ["language": ["en"]]),
            "Romance, not Horror")
        XCTAssertEqual(SavedSearch.suggestedName(query: "", filters: ["rating": ["12"]]), "Saved search")
    }

    func testShelvesHoldWorksOnceAndFollowAMove() {
        var state = LibraryState()
        let a = WorkKey(sourceID: "src", workID: "a")
        let b = WorkKey(sourceID: "src", workID: "b")
        let shelf = state.addShelf(named: " Favourites ")
        XCTAssertEqual(state.addShelf(named: "favourites"), shelf)
        state.setShelf(shelf, contains: true, [a, b, a])
        XCTAssertEqual(state.allShelves.first?.workIDs, [a.id, b.id])
        state.setShelf(shelf, contains: false, [a])
        XCTAssertEqual(state.allShelves.first?.workIDs, [b.id])

        let moved = WorkKey(sourceID: "other", workID: "b2")
        state.moveShelfMembership(from: b, to: moved)
        XCTAssertEqual(state.allShelves.first?.workIDs, [moved.id])

        state.renameShelf(shelf, to: "Best")
        XCTAssertEqual(state.allShelves.first?.name, "Best")
        state.removeShelf(shelf)
        XCTAssertTrue(state.allShelves.isEmpty)
    }

    func testLibraryFilesFromBeforeShelvesStillLoad() throws {
        let old = #"{"records":{}}"#
        let state = try JSONDecoder().decode(LibraryState.self, from: Data(old.utf8))
        XCTAssertTrue(state.allShelves.isEmpty)
        XCTAssertTrue(state.allSavedSearches.isEmpty)
    }
}
