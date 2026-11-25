import Foundation
import ShelfCore
import XCTest
@testable import RepoKit

// Vectors produced by `sdk/shelf-repo` (Node's Ed25519), so this also checks that the
// CLI and the app agree on the signing format.
private enum Vector {
    static let publicKey = "ed25519:U9hz7NXJLskeoSxaNu25ARDFzLBL6bcb5krDBZ/26to="
    static let package = Data(base64Encoded: "eyJmb3JtYXQiOjEsIm1hbmlmZXN0Ijp7ImlkIjoib3JnLmV4YW1wbGUudGVzdCIsIm5hbWUiOiJUZXN0IiwidmVyc2lvbiI6IjEuMC4wIiwia2luZCI6InRleHQiLCJsYW5ndWFnZXMiOlsiZW4iXSwiY29udGVudFJhdGluZyI6InNhZmUiLCJkb21haW5zIjpbImV4YW1wbGUub3JnIl19LCJzY3JpcHQiOiJnbG9iYWxUaGlzLnNvdXJjZSA9IHt9OyJ9")!
    static let sha256 = "7e338ef162887815377633a3c934395e18dc9a8ad873b6d9041ba5a813220ba2"
    static let signature = "hUDZG3of78LY7YGwKg1Yf7R0j/OHcDAkJdZr3Lbnr4aTrgXHcnFmbpD/oBvPtqxncNOI+zqokD26gIxSfxr0Dg=="

    static let entry = RepoEntry(
        id: "org.example.test", name: "Test", version: "1.0.0", kind: .text, contentRating: .safe,
        languages: ["en"], minAppVersion: nil, package: "packages/org.example.test-1.0.0.srcpkg.json",
        sha256: sha256, signature: signature, icon: nil)

    static let index = RepoIndex(
        format: 1, name: "Test Repo", maintainer: "me", homepage: nil, publicKey: publicKey, sources: [entry])
}

private struct MockTransport: RepoTransport {
    var files: [String: Data]
    func data(from url: URL) async throws -> Data {
        guard let data = files[url.absoluteString] else { throw RepoError.http(status: 404, url: url) }
        return data
    }
}

private final class MemoryPins: KeyPinStore, @unchecked Sendable {
    var pins: [URL: String] = [:]
    func pinnedKey(for repo: URL) -> String? { pins[repo] }
    func pin(_ key: String, for repo: URL) { pins[repo] = key }
    func removePin(for repo: URL) { pins[repo] = nil }
}

final class RepoKitTests: XCTestCase {
    let indexURL = URL(string: "https://repo.example.org/index.json")!

    func client(index: RepoIndex = Vector.index, package: Data = Vector.package, pins: MemoryPins = MemoryPins()) throws -> RepoClient {
        RepoClient(
            transport: MockTransport(files: [
                "https://repo.example.org/index.json": try JSONEncoder().encode(index),
                "https://repo.example.org/packages/org.example.test-1.0.0.srcpkg.json": package,
            ]),
            pins: pins, appVersion: "0.1.0")
    }

    func testVerifiesNodeSignedPackage() throws {
        let key = try RepoVerifier.publicKey(from: Vector.publicKey)
        XCTAssertNoThrow(try RepoVerifier.verify(package: Vector.package, entry: Vector.entry, publicKey: key))
    }

    func testRejectsTamperedPackage() throws {
        var data = Vector.package
        data[data.count - 3] ^= 0x01
        let key = try RepoVerifier.publicKey(from: Vector.publicKey)
        XCTAssertThrowsError(try RepoVerifier.verify(package: data, entry: Vector.entry, publicKey: key)) {
            XCTAssertEqual($0 as? RepoError, .hashMismatch(sourceID: "org.example.test"))
        }
    }

    func testRejectsWrongSignature() throws {
        var entry = Vector.entry
        entry.signature = Data(repeating: 1, count: 64).base64EncodedString()
        let key = try RepoVerifier.publicKey(from: Vector.publicKey)
        XCTAssertThrowsError(try RepoVerifier.verify(package: Vector.package, entry: entry, publicKey: key)) {
            XCTAssertEqual($0 as? RepoError, .badSignature(sourceID: "org.example.test"))
        }
    }

    func testDownloadsAndDecodesPackage() async throws {
        let client = try client()
        let index = try await client.fetchIndex(indexURL)
        let (package, _) = try await client.downloadPackage(index.sources[0], index: index, indexURL: indexURL)
        XCTAssertEqual(package.manifest.id, "org.example.test")
        XCTAssertEqual(package.script, "globalThis.source = {};")
    }

    func testKeyChangeIsRefused() async throws {
        let pins = MemoryPins()
        pins.pin("ed25519:" + Data(repeating: 9, count: 32).base64EncodedString(), for: indexURL)
        do {
            _ = try await client(pins: pins).fetchIndex(indexURL)
            XCTFail("Expected key change error")
        } catch {
            XCTAssertEqual(error as? RepoError, .keyChanged(repo: indexURL))
        }
    }

    func testFirstUsePinsKey() async throws {
        let pins = MemoryPins()
        _ = try await client(pins: pins).fetchIndex(indexURL)
        XCTAssertEqual(pins.pinnedKey(for: indexURL), Vector.publicKey)
    }

    func testIndexURLNormalisation() {
        XCTAssertEqual(RepoClient.indexURL(for: "someone.github.io/repo")?.absoluteString, "https://someone.github.io/repo/index.json")
        XCTAssertEqual(RepoClient.indexURL(for: "https://x.org/a/index.json")?.absoluteString, "https://x.org/a/index.json")
        XCTAssertNil(RepoClient.indexURL(for: "http://insecure.org"))
    }

    func testVersionCompare() {
        XCTAssertTrue(SemanticVersion("1.9.2") < SemanticVersion("1.10.0"))
        XCTAssertTrue(SemanticVersion("1.0") == SemanticVersion("1.0.0"))
    }

    func testStoreInstallsAndFindsUpdates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try SourceStore(directory: dir)
        let package = try JSONDecoder().decode(SourcePackage.self, from: Vector.package)
        try store.install(package, data: Vector.package, from: indexURL)
        XCTAssertEqual(store.installed().map(\.id), ["org.example.test"])
        XCTAssertEqual(try store.package(for: "org.example.test").manifest.version, "1.0.0")

        var newer = Vector.index
        newer.sources[0].version = "1.1.0"
        XCTAssertEqual(store.updates(in: newer, repo: indexURL).map(\.version), ["1.1.0"])

        try store.remove("org.example.test")
        XCTAssertTrue(store.installed().isEmpty)
    }
}
