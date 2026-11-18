import Foundation

/// A site answered with a bot check (such as a Cloudflare challenge) that only a person
/// can pass. The app opens the page in a browser sheet so the person can complete it
/// themselves, then keeps the site's cookie and browser identity for that host.
///
/// Shelfbound never tries to solve these checks itself.
public struct BrowserVerificationNeeded: Error, LocalizedError, Hashable, Sendable {
    public var url: URL

    public init(url: URL) { self.url = url }

    public var host: String { url.host?.lowercased() ?? url.absoluteString }

    public var errorDescription: String? {
        "\(host) wants to check that you're a person. Verify in the browser to keep reading."
    }
}

public enum BrowserChallenge {
    /// Whether a response is a bot check page rather than the content asked for.
    /// `headers` keys must be lowercased.
    public static func isChallenge(status: Int, headers: [String: String], body: String) -> Bool {
        if headers["cf-mitigated"]?.lowercased() == "challenge" { return true }
        guard status == 403 || status == 503 || status == 429 else { return false }
        let server = headers["server"]?.lowercased() ?? ""
        guard server.contains("cloudflare") || headers["cf-ray"] != nil else { return false }
        let head = body.prefix(20_000).lowercased()
        return head.contains("/cdn-cgi/challenge-platform/")
            || head.contains("cf-chl-")
            || head.contains("<title>just a moment")
            || head.contains("cf_chl_opt")
            || head.contains("cf-turnstile")
    }
}

/// Hosts the person has verified in the browser, and the browser identity (User-Agent)
/// that was used. A site's clearance cookie only works with the same User-Agent, so every
/// request to that host uses it. The cookies themselves live in the shared cookie store.
public final class ClearanceStore: @unchecked Sendable {
    public static let shared = ClearanceStore()

    public struct Entry: Codable, Sendable, Hashable {
        public var userAgent: String
        public var verifiedAt: Date
    }

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let key: String
    private var entries: [String: Entry]

    /// Pass `defaults: nil` for a store that isn't saved (tests).
    public init(defaults: UserDefaults? = .standard, key: String = "clearances") {
        self.defaults = defaults
        self.key = key
        if let data = defaults?.data(forKey: key), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        } else {
            entries = [:]
        }
    }

    /// The User-Agent to use for `url`: an exact host match, or a parent domain the
    /// clearance cookie was set for.
    public func userAgent(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return locked { Self.lookup(host, in: entries)?.userAgent }
    }

    public func entry(for host: String) -> Entry? {
        locked { Self.lookup(host.lowercased(), in: entries) }
    }

    public func record(host: String, userAgent: String, at date: Date = Date()) {
        locked {
            entries[host.lowercased()] = Entry(userAgent: userAgent, verifiedAt: date)
            save()
        }
    }

    public func remove(host: String) {
        locked {
            entries[host.lowercased()] = nil
            save()
        }
    }

    public var hosts: [String] { locked { entries.keys.sorted() } }

    private static func lookup(_ host: String, in entries: [String: Entry]) -> Entry? {
        var candidate = Substring(host)
        while true {
            if let entry = entries[String(candidate)] { return entry }
            guard let dot = candidate.firstIndex(of: "."), candidate[candidate.index(after: dot)...].contains(".") else { return nil }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Call with the lock held.
    private func save() {
        defaults?.set(try? JSONEncoder().encode(entries), forKey: key)
    }
}
