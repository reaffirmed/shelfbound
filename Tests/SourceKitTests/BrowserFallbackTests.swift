#if !canImport(FoundationNetworking)
import Foundation
import ShelfCore
@testable import SourceKit
import XCTest

/// Answers every request with a Cloudflare check page and counts them.
private final class ChallengeProtocol: URLProtocol {
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var lastCookie: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        Self.lastCookie = request.value(forHTTPHeaderField: "Cookie")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1",
            headerFields: ["Server": "cloudflare", "cf-mitigated": "challenge"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<title>Just a moment...</title>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class BrowserFallbackTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChallengeProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        ChallengeProtocol.requests = 0
        ChallengeProtocol.lastCookie = nil
    }

    func testVerifiedHostStillChallengedGoesThroughTheBrowser() async throws {
        let clearances = ClearanceStore(defaults: nil)
        clearances.record(host: "example.com", userAgent: "Mozilla/5.0 Test")
        let browserCalls = Counter()
        let network = URLSessionNetwork(session: session(), minimumInterval: .zero, clearances: clearances) { request in
            await browserCalls.add()
            return HostResponse(status: 200, url: request.url!.absoluteString, headers: ["Server": "cloudflare"], body: "ok")
        }
        let request = URLRequest(url: URL(string: "https://www.example.com/series/")!)

        let first = try await network.fetch(request, sourceID: "s")
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.body, "ok")
        XCTAssertEqual(ChallengeProtocol.requests, 1)
        let usesBrowser = await network.usesBrowser(for: "www.example.com")
        XCTAssertTrue(usesBrowser)

        // From then on the host goes straight to the browser.
        _ = try await network.fetch(request, sourceID: "s")
        XCTAssertEqual(ChallengeProtocol.requests, 1)
        let calls = await browserCalls.value
        XCTAssertEqual(calls, 2)
    }

    func testNotVerifiedYetAsksThePerson() async {
        let network = URLSessionNetwork(session: session(), minimumInterval: .zero, clearances: ClearanceStore(defaults: nil)) { _ in
            XCTFail("The browser is only used after the person verified")
            return nil
        }
        do {
            _ = try await network.fetch(URLRequest(url: URL(string: "https://example.com/")!), sourceID: "s")
            XCTFail("Expected a verification request")
        } catch {
            XCTAssertTrue(error is BrowserVerificationNeeded)
        }
    }

    func testBrowserShownTheCheckTooAsksThePersonAgain() async {
        let clearances = ClearanceStore(defaults: nil)
        clearances.record(host: "example.com", userAgent: "Mozilla/5.0 Test")
        let network = URLSessionNetwork(session: session(), minimumInterval: .zero, clearances: clearances) { request in
            HostResponse(status: 403, url: request.url!.absoluteString, headers: ["cf-mitigated": "challenge"], body: "")
        }
        do {
            _ = try await network.fetch(URLRequest(url: URL(string: "https://example.com/")!), sourceID: "s")
            XCTFail("Expected a verification request")
        } catch {
            XCTAssertTrue(error is BrowserVerificationNeeded)
        }
        let usesBrowser = await network.usesBrowser(for: "example.com")
        XCTAssertFalse(usesBrowser)
    }

    func testOwnCookieHeaderStillSendsTheClearanceCookie() async throws {
        // The app's source requests use the shared cookie store, where the browser check's
        // cookies are copied.
        let config = URLSessionConfiguration.default
        config.protocolClasses = [ChallengeProtocol.self]
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".shelfbound-test.example", .path: "/", .name: "cf_clearance", .value: "pass",
            .expires: Date().addingTimeInterval(3600),
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        let network = URLSessionNetwork(session: URLSession(configuration: config), minimumInterval: .zero)
        var request = URLRequest(url: URL(string: "https://www.shelfbound-test.example/")!)
        request.setValue("mature=1", forHTTPHeaderField: "Cookie")
        _ = try? await network.fetch(request, sourceID: "s")
        XCTAssertEqual(ChallengeProtocol.lastCookie, "mature=1; cf_clearance=pass")
    }
}

private actor Counter {
    private(set) var value = 0
    func add() { value += 1 }
}
#endif
