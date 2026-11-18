import Foundation
import XCTest
@testable import ShelfCore

final class TranslationCacheTests: XCTestCase {
    func testKeyDependsOnTextAndLanguages() {
        let a = TranslationCache.key(work: "w", chapter: "c", source: nil, target: "en", paragraphs: ["一", "二"])
        XCTAssertEqual(a, TranslationCache.key(work: "w", chapter: "c", source: nil, target: "en", paragraphs: ["一", "二"]))
        XCTAssertNotEqual(a, TranslationCache.key(work: "w", chapter: "c", source: nil, target: "fr", paragraphs: ["一", "二"]))
        XCTAssertNotEqual(a, TranslationCache.key(work: "w", chapter: "c", source: nil, target: "en", paragraphs: ["一二"]))
    }

    func testSaveLoadAndPrune() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = TranslationCache(directory: dir, limit: 2)
        cache.save("a", ["one"])
        XCTAssertEqual(cache.load("a", count: 1), ["one"])
        XCTAssertNil(cache.load("a", count: 2), "a cached list that doesn't line up with the paragraphs is ignored")
        cache.save("b", ["two"])
        cache.save("c", ["three"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
    }
}
