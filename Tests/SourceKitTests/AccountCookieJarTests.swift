import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SourceKit

final class AccountCookieJarTests: XCTestCase {
    private func cookie(_ name: String, _ value: String, domain: String = ".archiveofourown.org") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"])!
    }

    func testSignInCookiesStayInTheSourcesOwnJar() throws {
        let jars = AccountCookieJars()
        jars.set([cookie("_otwarchive_session", "secret")], for: "ao3")

        let session = try XCTUnwrap(jars.session(for: "ao3"))
        XCTAssertFalse(jars.storage(for: session) === HTTPCookieStorage.shared)
        XCTAssertEqual(jars.cookies(for: "ao3").map(\.value), ["secret"])
        // Another source, even one for the same site, has no jar and never sees them.
        XCTAssertNil(jars.session(for: "other-ao3"))
        XCTAssertTrue(jars.cookies(for: "other-ao3").isEmpty)
        let url = URL(string: "https://archiveofourown.org/works/1")!
        XCTAssertFalse((HTTPCookieStorage.shared.cookies(for: url) ?? []).contains { $0.value == "secret" })

        jars.set([], for: "ao3")
        XCTAssertNil(jars.session(for: "ao3"))
    }

    func testReportsRefreshedCookiesButNotACloudflarePass() throws {
        let jars = AccountCookieJars()
        jars.set([cookie("_otwarchive_session", "one")], for: "ao3")
        let session = try XCTUnwrap(jars.session(for: "ao3"))
        let seen = Locked<[[String]]>([])
        jars.onChange { _, cookies in seen.mutate { $0.append(cookies.map(\.value).sorted()) } }

        jars.noteResponse(for: "ao3", session: session)
        XCTAssertTrue(seen.value.isEmpty, "nothing changed yet")

        jars.storage(for: session)?.setCookie(cookie("cf_clearance", "pass"))
        jars.noteResponse(for: "ao3", session: session)
        XCTAssertTrue(seen.value.isEmpty, "a Cloudflare pass isn't a sign-in cookie")

        jars.storage(for: session)?.setCookie(cookie("_otwarchive_session", "two"))
        jars.noteResponse(for: "ao3", session: session)
        XCTAssertEqual(seen.value, [["two"]])
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
