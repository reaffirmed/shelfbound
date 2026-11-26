import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShelfCore

/// A request a source makes through `host.fetch`.
public struct HostRequest: Codable, Sendable, Hashable {
    public var url: String
    public var method: String?
    public var headers: [String: String]?
    public var body: String?
    /// `"manual"` returns a 3xx response as is (with its `location` header) instead of following it.
    public var redirect: String?
}

public struct HostResponse: Codable, Sendable, Hashable {
    public var status: Int
    public var url: String
    public var headers: [String: String]
    public var body: String

    public init(status: Int, url: String, headers: [String: String] = [:], body: String) {
        self.status = status
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct FetchOptions: Sendable {
    public var followRedirects: Bool
    /// Checked for every redirect target, so a redirect can't reach a host the source didn't declare.
    public var allowRedirect: @Sendable (URL) -> Bool

    public init(followRedirects: Bool = true, allowRedirect: @escaping @Sendable (URL) -> Bool = { _ in true }) {
        self.followRedirects = followRedirects
        self.allowRedirect = allowRedirect
    }
}

/// The only way a source reaches the network. The runtime checks the domain
/// allow-list before calling this.
public protocol HostNetwork: Sendable {
    func fetch(_ request: URLRequest, sourceID: String) async throws -> HostResponse
    func fetch(_ request: URLRequest, sourceID: String, options: FetchOptions) async throws -> HostResponse
}

extension HostNetwork {
    public func fetch(_ request: URLRequest, sourceID: String, options: FetchOptions) async throws -> HostResponse {
        try await fetch(request, sourceID: sourceID)
    }
}

/// Signed-in sources' cookies, one private jar per source, so a source's sign-in cookies
/// go only with that source's own requests: never with another source's (even one that
/// declares the same site), and never with reader mode, images or downloads, which use
/// the shared cookie store. Safe to use from any thread.
public final class AccountCookieJars: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]
    /// Each jar's cookie store, kept here rather than read back from the session.
    private var stores: [ObjectIdentifier: HTTPCookieStorage] = [:]
    private var fingerprints: [String: Set<String>] = [:]
    private var changed: (@Sendable (String, [HTTPCookie]) -> Void)?

    public init() {}

    /// Gives `sourceID` its own jar holding `cookies`. An empty list removes the jar, so
    /// the source goes back to the shared cookie store.
    public func set(_ cookies: [HTTPCookie], for sourceID: String) {
        let made = cookies.isEmpty ? nil : Self.makeSession(with: cookies)
        lock.lock()
        let old = sessions[sourceID]
        if let old { stores[ObjectIdentifier(old)] = nil }
        sessions[sourceID] = made?.session
        if let made { stores[ObjectIdentifier(made.session)] = made.storage }
        fingerprints[sourceID] = made.map { Self.fingerprint(Self.signInCookies($0.storage)) }
        lock.unlock()
        old?.finishTasksAndInvalidate()
    }

    /// The sign-in cookies in a source's jar now, including any the site has refreshed
    /// since. Empty when the source has no jar.
    public func cookies(for sourceID: String) -> [HTTPCookie] {
        session(for: sourceID).flatMap(storage(for:)).map(Self.signInCookies) ?? []
    }

    /// The cookie store a jar's session uses.
    func storage(for session: URLSession) -> HTTPCookieStorage? {
        lock.lock()
        defer { lock.unlock() }
        return stores[ObjectIdentifier(session)]
    }

    public func hasJar(for sourceID: String) -> Bool { session(for: sourceID) != nil }

    /// Called with a source's cookies whenever a response changes them, so the app can
    /// keep its saved copy current.
    public func onChange(_ handler: @escaping @Sendable (String, [HTTPCookie]) -> Void) {
        lock.lock()
        changed = handler
        lock.unlock()
    }

    func session(for sourceID: String) -> URLSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sourceID]
    }

    /// After a request through `session`: tells the app if the site changed the cookies.
    func noteResponse(for sourceID: String, session: URLSession) {
        guard let storage = storage(for: session) else { return }
        let now = Self.signInCookies(storage)
        let current = Self.fingerprint(now)
        lock.lock()
        guard sessions[sourceID] === session, fingerprints[sourceID] != current else {
            lock.unlock()
            return
        }
        fingerprints[sourceID] = current
        let handler = changed
        lock.unlock()
        handler?(sourceID, now)
    }

    private static func makeSession(with cookies: [HTTPCookie]) -> (session: URLSession, storage: HTTPCookieStorage)? {
        let configuration = URLSessionConfiguration.ephemeral
        // An ephemeral configuration has its own in-memory store. Never use the shared one.
        guard let storage = configuration.httpCookieStorage, storage !== HTTPCookieStorage.shared else { return nil }
        storage.cookieAcceptPolicy = .always
        for cookie in cookies { storage.setCookie(cookie) }
        return (URLSession(configuration: configuration), storage)
    }

    /// The jar's cookies, minus a Cloudflare pass copied in from the shared store.
    private static func signInCookies(_ storage: HTTPCookieStorage) -> [HTTPCookie] {
        (storage.cookies ?? []).filter { $0.name != "cf_clearance" }
    }

    private static func fingerprint(_ cookies: [HTTPCookie]) -> Set<String> {
        Set(cookies.map { "\($0.domain)|\($0.path)|\($0.name)=\($0.value)" })
    }
}

/// URLSession-backed network with a minimum gap between requests per source,
/// so community sources are gentle with the sites they read. A 429 or 503 with
/// `Retry-After` pushes that source's next request back.
///
/// A bot-check page (such as a Cloudflare challenge) throws `BrowserVerificationNeeded`
/// so the app can ask the person to pass it in a browser. Hosts they've verified are
/// sent the browser's User-Agent, which their clearance cookie is tied to.
public actor URLSessionNetwork: HostNetwork {
    private let session: URLSession
    private let defaultInterval: Duration
    private var intervals: [String: Duration] = [:]
    private var nextAllowed: [String: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()
    public static let userAgent = "Shelfbound/0.2 (iOS reader)"

    private let clearances: ClearanceStore?
    private let accounts: AccountCookieJars?

    public init(
        session: URLSession = .shared, minimumInterval: Duration = .milliseconds(1000),
        clearances: ClearanceStore? = nil, accounts: AccountCookieJars? = nil
    ) {
        self.session = session
        self.defaultInterval = minimumInterval
        self.clearances = clearances
        self.accounts = accounts
    }

    /// Uses a longer gap for one source, from its manifest's `rateLimit`. Never shorter than the default.
    public func setMinimumInterval(_ interval: Duration, for sourceID: String) {
        intervals[sourceID] = max(interval, defaultInterval)
    }

    public func fetch(_ request: URLRequest, sourceID: String) async throws -> HostResponse {
        try await fetch(request, sourceID: sourceID, options: FetchOptions())
    }

    public func fetch(_ request: URLRequest, sourceID: String, options: FetchOptions) async throws -> HostResponse {
        try await waitForSlot(sourceID)

        var request = request
        if let url = request.url, let browserAgent = clearances?.userAgent(for: url) {
            request.setValue(browserAgent, forHTTPHeaderField: "User-Agent")
        } else if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
        // A signed-in source uses its own jar; everything else uses the shared store.
        let accountSession = accounts?.session(for: sourceID)
        if let accountSession, let url = request.url, let jar = accounts?.storage(for: accountSession) {
            // A Cloudflare pass the person got in the browser still applies to this site.
            for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] where cookie.name == "cf_clearance" {
                jar.setCookie(cookie)
            }
        }
        let session = accountSession ?? self.session
        // A source that sends its own Cookie header still needs the stored ones, above all
        // the browser check's clearance cookie.
        let cookieStore = accountSession.flatMap { accounts?.storage(for: $0) }
            ?? session.configuration.httpCookieStorage ?? .shared
        let manualCookies = request.includeStoredCookies(from: cookieStore)
        #if canImport(FoundationNetworking)
        let (data, response) = try await session.data(for: request)
        #else
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard(options: options))
        #endif
        if manualCookies { cookieStore.keepCookies(from: response) }
        if let accountSession { accounts?.noteResponse(for: sourceID, session: accountSession) }
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        if let status = http?.statusCode, status == 429 || status == 503 {
            backOff(sourceID, retryAfter: headers["retry-after"])
        }
        let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if let url = request.url, BrowserChallenge.isChallenge(status: http?.statusCode ?? 0, headers: headers, body: body) {
            throw BrowserVerificationNeeded(url: url)
        }
        return HostResponse(
            status: http?.statusCode ?? 0,
            url: response.url?.absoluteString ?? request.url?.absoluteString ?? "",
            headers: headers,
            body: body
        )
    }

    private func waitForSlot(_ sourceID: String) async throws {
        let now = clock.now
        let slot = max(now, nextAllowed[sourceID] ?? now)
        nextAllowed[sourceID] = slot + (intervals[sourceID] ?? defaultInterval)
        if slot > now { try await clock.sleep(until: slot) }
    }

    private func backOff(_ sourceID: String, retryAfter: String?) {
        let seconds = retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 30
        let until = clock.now + .seconds(min(max(seconds, 5), 300))
        nextAllowed[sourceID] = max(nextAllowed[sourceID] ?? until, until)
    }
}

#if !canImport(FoundationNetworking)
/// Stops redirects to undeclared hosts, or all redirects for `redirect: "manual"`.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let options: FetchOptions

    init(options: FetchOptions) { self.options = options }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard options.followRedirects, let url = request.url, options.allowRedirect(url) else { return nil }
        return request
    }
}
#endif
