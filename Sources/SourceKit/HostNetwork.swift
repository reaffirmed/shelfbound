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

/// The only way a source reaches the network. The runtime checks the domain
/// allow-list before calling this.
public protocol HostNetwork: Sendable {
    func fetch(_ request: URLRequest, sourceID: String) async throws -> HostResponse
}

/// URLSession-backed network with a minimum gap between requests per source,
/// so community sources are gentle with the sites they read.
public actor URLSessionNetwork: HostNetwork {
    private let session: URLSession
    private let minimumInterval: Duration
    private var nextAllowed: [String: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()

    public init(session: URLSession = .shared, minimumInterval: Duration = .milliseconds(1000)) {
        self.session = session
        self.minimumInterval = minimumInterval
    }

    public func fetch(_ request: URLRequest, sourceID: String) async throws -> HostResponse {
        let now = clock.now
        let slot = max(now, nextAllowed[sourceID] ?? now)
        nextAllowed[sourceID] = slot + minimumInterval
        if slot > now { try await clock.sleep(until: slot) }

        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Shelfbound/0.1 (iOS reader)", forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return HostResponse(
            status: http?.statusCode ?? 0,
            url: response.url?.absoluteString ?? request.url?.absoluteString ?? "",
            headers: headers,
            body: body
        )
    }
}

