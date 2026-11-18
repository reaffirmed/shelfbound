import Foundation

/// Spaces out page downloads so one site never gets hammered: at most `maxPerHost`
/// transfers at once per host, a minimum gap between starts on the same host, and a
/// cap on transfers overall.
public struct HostThrottle: Sendable {
    public var maxPerHost: Int
    public var minInterval: TimeInterval
    public var maxTotal: Int

    private var running: [String: Int] = [:]
    private var lastStart: [String: Date] = [:]

    public init(maxPerHost: Int = 2, minInterval: TimeInterval = 0.4, maxTotal: Int = 6) {
        self.maxPerHost = maxPerHost
        self.minInterval = minInterval
        self.maxTotal = maxTotal
    }

    public var totalRunning: Int { running.values.reduce(0, +) }

    public enum Decision: Equatable {
        case start
        /// Try again at this time.
        case wait(Date)
        /// Full; something has to finish first.
        case busy
    }

    public func decide(host: String, now: Date) -> Decision {
        if totalRunning >= maxTotal || running[host, default: 0] >= maxPerHost { return .busy }
        if let last = lastStart[host], now.timeIntervalSince(last) < minInterval {
            return .wait(last.addingTimeInterval(minInterval))
        }
        return .start
    }

    public mutating func didStart(host: String, now: Date) {
        running[host, default: 0] += 1
        lastStart[host] = now
    }

    public mutating func didFinish(host: String) {
        running[host] = max(0, running[host, default: 0] - 1)
    }

    public mutating func reset() {
        running = [:]
    }
}
