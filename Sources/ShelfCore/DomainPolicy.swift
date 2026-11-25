import Foundation

/// Decides whether a source may contact a URL, from the `domains` in its manifest.
public struct DomainPolicy: Sendable, Hashable {
    public let patterns: [String]

    public init(patterns: [String]) {
        self.patterns = patterns.map { $0.lowercased() }
    }

    public func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased()
        else { return false }
        return patterns.contains { pattern in
            if pattern.hasPrefix("*.") {
                let base = String(pattern.dropFirst(2))
                return host == base || host.hasSuffix("." + base)
            }
            return host == pattern
        }
    }
}
