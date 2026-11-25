#if canImport(JavaScriptCore)
import Foundation
import ShelfCore
import XCTest
@testable import SourceKit

private struct MockNetwork: HostNetwork {
    var bodies: [String: String]

    func fetch(_ request: URLRequest, sourceID: String) async throws -> HostResponse {
        let url = request.url!.absoluteString
        guard let body = bodies[url] else { return HostResponse(status: 404, url: url, body: "") }
        return HostResponse(status: 200, url: url, body: body)
    }
}

private func package(_ script: String, domains: [String] = ["example.org"]) -> SourcePackage {
    SourcePackage(
        manifest: SourceManifest(
            id: "org.example.test", name: "Test", version: "1.0.0", kind: .text,
            languages: ["en"], contentRating: .safe, domains: domains),
        script: script)
}

private let fullSource = #"""
globalThis.source = {
  async search(query, page) {
    const data = await host.fetchJSON("https://example.org/search?q=" + encodeURIComponent(query));
    return { results: data.items.map((i) => ({ id: String(i.id), title: i.title, authors: [i.by] })), hasMore: false };
  },
  async getWork(id) {
    const res = await host.fetch("https://example.org/works/" + id);
    const title = host.select(res.body, "h2.title")[0].text;
    const tags = host.select(res.body, "ul.tags a").map((a) => a.text);
    return { id, title, authors: [], tags, wordCount: 1200 };
  },
  async getChapters(id) {
    return [{ id: "1", title: "Chapter 1", number: 1, publishedAt: "2024-05-01T00:00:00Z" }];
  },
  async getChapterContent(workId, chapterId) {
    return { type: "text", html: "<p>Once upon a time</p>", notesBefore: host.settings.get("greeting") };
  },
};
"""#

final class SourceRuntimeTests: XCTestCase {
    private let network = MockNetwork(bodies: [
        "https://example.org/search?q=tea": #"{"items":[{"id":7,"title":"Tea Shop AU","by":"anon"}]}"#,
        "https://example.org/works/7": #"<h2 class="title">Tea Shop AU</h2><ul class="tags"><li><a>Fluff</a></li><li><a>Coffee</a></li></ul>"#,
    ])

    func testFullSourceFlow() async throws {
        let runtime = try SourceRuntime(package: package(fullSource), network: network, settings: ["greeting": "hello"])

        let page = try await runtime.search(query: "tea")
        XCTAssertEqual(page.results.first?.title, "Tea Shop AU")

        let work = try await runtime.getWork(id: "7")
        XCTAssertEqual(work.tags, ["Fluff", "Coffee"])
        XCTAssertEqual(work.wordCount, 1200)

        let chapters = try await runtime.getChapters(workID: "7")
        XCTAssertNotNil(chapters.first?.publishedAt)

        let content = try await runtime.getChapterContent(workID: "7", chapterID: "1")
        XCTAssertEqual(content, .text(html: "<p>Once upon a time</p>", notesBefore: "hello", notesAfter: nil))
    }

    func testUndeclaredDomainIsRefused() async throws {
        let script = fullSource.replacingOccurrences(of: "https://example.org/search", with: "https://other.example.com/search")
        let runtime = try SourceRuntime(package: package(script), network: network)
        do {
            _ = try await runtime.search(query: "tea")
            XCTFail("Expected a domain error")
        } catch let SourceError.callFailed(_, message) {
            XCTAssertTrue(message.contains("other.example.com"), message)
        }
    }

    func testMissingFunctionFailsAtLoad() {
        XCTAssertThrowsError(try SourceRuntime(package: package("globalThis.source = { search() {} };"), network: network)) {
            XCTAssertEqual($0 as? SourceError, .missingFunction("getWork"))
        }
    }

    func testSyntaxErrorFailsAtLoad() {
        XCTAssertThrowsError(try SourceRuntime(package: package("globalThis.source = {"), network: network))
    }

    func testHostIsFrozen() async throws {
        let script = fullSource + "\nhost.fetch = () => 1;"
        // Assignment to a frozen object's property is ignored outside strict mode.
        let runtime = try SourceRuntime(package: package(script), network: network)
        let page = try await runtime.search(query: "tea")
        XCTAssertEqual(page.results.count, 1)
    }

    func testCallTimesOut() async throws {
        let script = fullSource.replacingOccurrences(
            of: "async getChapters(id) {", with: "getChapters(id) { return new Promise(() => {});")
        let runtime = try SourceRuntime(package: package(script), network: network, timeout: 0.3)
        do {
            _ = try await runtime.getChapters(workID: "7")
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? SourceError, .timedOut(function: "getChapters"))
        }
    }

    func testBadResultIsReported() async throws {
        let script = fullSource.replacingOccurrences(
            of: "async getChapters(id) {", with: "async getChapters(id) { return 42;")
        let runtime = try SourceRuntime(package: package(script), network: network)
        do {
            _ = try await runtime.getChapters(workID: "7")
            XCTFail("Expected a bad result")
        } catch SourceError.badResult(let function, _) {
            XCTAssertEqual(function, "getChapters")
        }
    }
}
#endif
