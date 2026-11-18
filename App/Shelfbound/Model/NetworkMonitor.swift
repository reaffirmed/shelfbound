import DownloadKit
import Foundation
import Network

/// Tells the download queue whether we're on Wi-Fi, cellular or offline.
/// Expensive or constrained paths (cellular, personal hotspot, Low Data Mode) count as cellular.
final class NetworkMonitor: NetworkConditions, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var kind: NetworkKind = .wifi
    var onChange: (@Sendable (NetworkKind) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let next: NetworkKind
            if path.status != .satisfied {
                next = .offline
            } else if path.isExpensive || path.isConstrained {
                next = .cellular
            } else {
                next = .wifi
            }
            self.lock.lock()
            let changed = next != self.kind
            self.kind = next
            self.lock.unlock()
            if changed { self.onChange?(next) }
        }
        monitor.start(queue: DispatchQueue(label: "shelfbound.network"))
    }

    var current: NetworkKind {
        lock.lock()
        defer { lock.unlock() }
        return kind
    }
}
