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

/// URLSession-backed network with a minimum gap between requests per source,
/// so community sources are gentle with the sites they read. A 429 or 503 with
/// `Retry-After` pushes that source's next request back.
public actor URLSessionNetwork: HostNetwork {
    private let session: URLSession
    private let defaultInterval: Duration
    private var intervals: [String: Duration] = [:]
    private var nextAllowed: [String: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()
    public static let userAgent = "Shelfbound/0.2 (iOS reader)"

    public init(session: URLSession = .shared, minimumInterval: Duration = .milliseconds(1000)) {
        self.session = session
        self.defaultInterval = minimumInterval
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
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
        #if canImport(FoundationNetworking)
        let (data, response) = try await session.data(for: request)
        #else
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard(options: options))
        #endif
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        if let status = http?.statusCode, status == 429 || status == 503 {
            backOff(sourceID, retryAfter: headers["retry-after"])
        }
        let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
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
