#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum RepoError: Error, LocalizedError, Equatable {
    case badPublicKey
    case keyChanged(repo: URL)
    case hashMismatch(sourceID: String)
    case badSignature(sourceID: String)
    case manifestMismatch(sourceID: String)
    case unsupportedFormat(Int)
    case appTooOld(required: String)
    case blocked(repo: URL)
    case http(status: Int, url: URL)

    public var errorDescription: String? {
        switch self {
        case .badPublicKey: "The repo's public key isn't a valid Ed25519 key."
        case let .keyChanged(repo): "The signing key for \(repo.host ?? repo.absoluteString) changed since you added it. Remove and re-add the repo only if you trust the change."
        case let .hashMismatch(id): "\(id) doesn't match the checksum in its repo."
        case let .badSignature(id): "\(id) isn't signed by its repo's key."
        case let .manifestMismatch(id): "\(id)'s package doesn't match its repo listing."
        case let .unsupportedFormat(f): "This repo uses format \(f), which this version of the app can't read."
        case let .appTooOld(v): "This source needs app version \(v) or newer."
        case let .blocked(repo): "\(repo.host ?? repo.absoluteString) has been blocked."
        case let .http(status, url): "HTTP \(status) for \(url.absoluteString)"
        }
    }
}

public enum RepoVerifier {
    public static func publicKey(from string: String) throws -> Curve25519.Signing.PublicKey {
        let prefix = "ed25519:"
        guard string.hasPrefix(prefix),
              let raw = Data(base64Encoded: String(string.dropFirst(prefix.count))),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { throw RepoError.badPublicKey }
        return key
    }

    /// Checks a downloaded package against its index entry: SHA-256, then the signature.
    public static func verify(package data: Data, entry: RepoEntry, publicKey: Curve25519.Signing.PublicKey) throws {
        let digest = Data(SHA256.hash(data: data))
        guard digest.hexString == entry.sha256.lowercased() else {
            throw RepoError.hashMismatch(sourceID: entry.id)
        }
        guard let signature = Data(base64Encoded: entry.signature),
              publicKey.isValidSignature(signature, for: digest)
        else { throw RepoError.badSignature(sourceID: entry.id) }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
