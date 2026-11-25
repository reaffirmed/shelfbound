import XCTest
@testable import ShelfCore

final class ShelfCoreTests: XCTestCase {
    func testAccountManifestAndWorkState() throws {
        let json = #"""
        {"id":"org.example.ao3","name":"AO3","version":"1.2.0","kind":"text","languages":["en"],
         "contentRating":"explicit","domains":["archiveofourown.org"],
         "capabilities":["filters","account"],"account":{"loginURL":"https://archiveofourown.org/users/login"}}
        """#
        let manifest = try JSONDecoder().decode(SourceManifest.self, from: Data(json.utf8))
        XCTAssertTrue(manifest.has(.account))
        XCTAssertEqual(manifest.account?.loginURL.absoluteString, "https://archiveofourown.org/users/login")

        // Sources from before accounts still decode, without the field.
        let old = try JSONDecoder().decode(SourceManifest.self, from: Data(json.replacingOccurrences(of: #","account":{"loginURL":"https://archiveofourown.org/users/login"}"#, with: "").utf8))
        XCTAssertNil(old.account)

        let work = try JSONDecoder().decode(Work.self, from: Data(#"{"id":"1","title":"T","authors":[],"account":{"markedForLater":true,"subscribed":false}}"#.utf8))
        XCTAssertEqual(work.account, WorkAccountState(markedForLater: true, subscribed: false, kudos: nil))
    }

    func testDomainPolicy() {
        let policy = DomainPolicy(patterns: ["example.org", "*.cdn.example.net"])
        XCTAssertTrue(policy.allows(URL(string: "https://example.org/works/1")!))
        XCTAssertFalse(policy.allows(URL(string: "https://evil-example.org/")!))
        XCTAssertTrue(policy.allows(URL(string: "https://img.cdn.example.net/a.png")!))
        XCTAssertTrue(policy.allows(URL(string: "https://cdn.example.net/a.png")!))
        XCTAssertFalse(policy.allows(URL(string: "file:///etc/passwd")!))
    }

    func testChapterContentRoundTrip() throws {
        let content = ChapterContent.text(html: "<p>Hi</p>", notesBefore: "n", notesAfter: nil)
        let data = try JSONEncoder().encode(content)
        XCTAssertEqual(try JSONDecoder().decode(ChapterContent.self, from: data), content)
    }

    func testReaderDocumentEscapesTitleAndBlocksScripts() {
        let html = ReaderDocument.html(title: "<script>", body: "<p>x</p>", style: ReaderStyle())
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("default-src 'none'"))
    }

    func testRatingOrder() {
        XCTAssertTrue(ContentRating.safe < .explicit)
    }
}

final class BrowserVerificationTests: XCTestCase {
    func testDetectsCloudflareChallenges() {
        XCTAssertTrue(BrowserChallenge.isChallenge(status: 403, headers: ["cf-mitigated": "challenge"], body: ""))
        XCTAssertTrue(BrowserChallenge.isChallenge(
            status: 503, headers: ["server": "cloudflare"],
            body: "<!DOCTYPE html><html><head><title>Just a moment...</title>"))
        XCTAssertTrue(BrowserChallenge.isChallenge(
            status: 403, headers: ["cf-ray": "8a1"], body: #"<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script>"#))
    }

    func testIgnoresOrdinaryErrorsAndPages() {
        XCTAssertFalse(BrowserChallenge.isChallenge(status: 200, headers: ["server": "cloudflare"], body: "<title>Just a moment</title>"))
        XCTAssertFalse(BrowserChallenge.isChallenge(status: 403, headers: ["server": "nginx"], body: "<title>Just a moment</title>"))
        XCTAssertFalse(BrowserChallenge.isChallenge(status: 404, headers: ["server": "cloudflare"], body: "Not found"))
        XCTAssertFalse(BrowserChallenge.isChallenge(status: 403, headers: ["server": "cloudflare"], body: "Forbidden"))
    }

    func testClearanceAppliesToSubdomainsOfTheVerifiedDomain() {
        let store = ClearanceStore(defaults: nil)
        store.record(host: "Example.org", userAgent: "UA-1")
        XCTAssertEqual(store.userAgent(for: URL(string: "https://example.org/a")!), "UA-1")
        XCTAssertEqual(store.userAgent(for: URL(string: "https://cdn.example.org/a.jpg")!), "UA-1")
        XCTAssertNil(store.userAgent(for: URL(string: "https://org/")!))
        XCTAssertNil(store.userAgent(for: URL(string: "https://example.com/")!))
        store.remove(host: "example.org")
        XCTAssertNil(store.userAgent(for: URL(string: "https://example.org/a")!))
    }
}

final class WidgetSnapshotTests: XCTestCase {
    func testLinksRoundTripOddIDs() {
        let key = WorkKey(sourceID: "org.example.ao3", workID: "series/42?x=1&y=2")
        XCTAssertEqual(WidgetSnapshot.workKey(from: WidgetSnapshot.link(to: key)), key)
        XCTAssertNil(WidgetSnapshot.workKey(from: URL(string: "shelfbound://add-repo?url=x")!))
    }
}
