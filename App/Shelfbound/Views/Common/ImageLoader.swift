import ImageIO
import ShelfCore
import SwiftUI
import UIKit

/// Loads covers and pages, downsampled to the size they're shown at, so a 20,000 pixel
/// webtoon strip never sits in memory at full size. Keeps a small memory cache, joins
/// duplicate requests, and allows only a few requests per host at a time.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    struct Loaded {
        let image: UIImage
        /// Height / width of the original, so readers can size cells before decoding.
        let aspect: CGFloat
    }

    private let cache = NSCache<NSString, UIImage>()
    private let aspects = NSCache<NSString, NSNumber>()
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [String: Task<Loaded, Error>] = [:]
    private var hostSlots: [String: Int] = [:]
    /// Requests waiting for a free slot on a host. Pages on screen go before prefetches,
    /// so a fast scroll never leaves the page you're looking at stuck behind ones you passed.
    private var waiters: [String: HostQueue] = [:]
    /// Keys of loads still waiting for a slot as prefetches, so a page that comes on screen
    /// can move its own load to the front.
    private var waitingInBackground: Set<String> = []

    private struct Waiter {
        let key: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct HostQueue {
        var urgent: [Waiter] = []
        var background: [Waiter] = []
        var isEmpty: Bool { urgent.isEmpty && background.isEmpty }
        mutating func next() -> Waiter? {
            if !urgent.isEmpty { return urgent.removeFirst() }
            if !background.isEmpty { return background.removeFirst() }
            return nil
        }
    }
    private let perHost = 4
    /// Largest decoded image, in pixels. Taller strips are scaled down to fit.
    private let maxPixels: CGFloat = 12_000_000
    /// Screen scale, set once from the main thread at launch.
    var screenScale: CGFloat = 3

    init() {
        cache.totalCostLimit = 120 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = perHost
        session = URLSession(configuration: config)
    }

    func cached(_ page: ImagePage, width: CGFloat) -> UIImage? {
        cache.object(forKey: key(page.url, width) as NSString)
    }

    func knownAspect(_ url: URL) -> CGFloat? {
        aspects.object(forKey: url.absoluteString as NSString).map { CGFloat($0.doubleValue) }
    }

    /// `width` is in points; the image is decoded at screen scale. `urgent` is false for
    /// prefetches, which wait behind pages that are on screen.
    func load(_ page: ImagePage, width: CGFloat, urgent: Bool = true) async throws -> Loaded {
        let k = key(page.url, width)
        if let image = cache.object(forKey: k as NSString) {
            return Loaded(image: image, aspect: knownAspect(page.url) ?? image.size.height / max(image.size.width, 1))
        }
        let task: Task<Loaded, Error> = lock.withLock {
            if let existing = inFlight[k] {
                if urgent { promote(k, host: page.url.host ?? "") }
                return existing
            }
            let created = Task(priority: urgent ? .userInitiated : .utility) {
                try await self.fetchAndDecode(page, width: width, key: k, urgent: urgent)
            }
            inFlight[k] = created
            return created
        }
        defer { lock.withLock { inFlight[k] = nil } }
        let loaded = try await task.value
        cache.setObject(loaded.image, forKey: k as NSString, cost: Int(loaded.image.size.width * loaded.image.size.height * loaded.image.scale * loaded.image.scale * 4))
        return loaded
    }

    func prefetch(_ pages: [ImagePage], width: CGFloat) {
        for page in pages where cached(page, width: width) == nil {
            Task(priority: .utility) { _ = try? await self.load(page, width: width, urgent: false) }
        }
    }

    private func key(_ url: URL, _ width: CGFloat) -> String { "\(Int(width))|\(url.absoluteString)" }

    private func fetchAndDecode(_ page: ImagePage, width: CGFloat, key: String, urgent: Bool) async throws -> Loaded {
        let data: Data
        if page.url.isFileURL {
            data = try Data(contentsOf: page.url)
        } else {
            let host = page.url.host ?? ""
            await acquire(host, key: key, urgent: urgent)
            defer { release(host) }
            var request = URLRequest(url: page.url)
            for (field, value) in page.headers ?? [:] { request.setValue(value, forHTTPHeaderField: field) }
            request.includeStoredCookies(from: session.configuration.httpCookieStorage ?? .shared)
            if let browserAgent = ClearanceStore.shared.userAgent(for: page.url) {
                request.setValue(browserAgent, forHTTPHeaderField: "User-Agent")
            } else if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue("Shelfbound/0.2 (iOS reader)", forHTTPHeaderField: "User-Agent")
            }
            let (body, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
                if BrowserChallenge.isChallenge(status: http.statusCode, headers: headers, body: String(decoding: body.prefix(20_000), as: UTF8.self)) {
                    throw BrowserVerificationNeeded(url: page.url)
                }
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            data = body
        }
        try Task.checkCancellation()
        return try decode(data, url: page.url, width: width)
    }

    private func decode(_ data: Data, url: URL, width: CGFloat) throws -> Loaded {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            throw URLError(.cannotDecodeContentData)
        }
        var aspect: CGFloat = 1.4
        var pixelWidth: CGFloat = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0 {
            aspect = h / w
            pixelWidth = w
            aspects.setObject(NSNumber(value: Double(aspect)), forKey: url.absoluteString as NSString)
        }
        let scale = screenScale
        var targetWidth = width * scale
        if pixelWidth > 0 { targetWidth = min(targetWidth, pixelWidth) }
        if targetWidth * targetWidth * aspect > maxPixels {
            targetWidth = (maxPixels / aspect).squareRoot()
        }
        let longest = max(targetWidth, targetWidth * aspect)
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(longest.rounded(.up))),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        return Loaded(image: UIImage(cgImage: cgImage, scale: scale, orientation: .up), aspect: aspect)
    }

    private func tryAcquire(_ host: String) -> Bool {
        lock.withLock {
            guard hostSlots[host, default: 0] < perHost else { return false }
            hostSlots[host, default: 0] += 1
            return true
        }
    }

    private func acquire(_ host: String, key: String, urgent: Bool) async {
        if tryAcquire(host) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired: Bool = lock.withLock {
                if hostSlots[host, default: 0] < perHost {
                    hostSlots[host, default: 0] += 1
                    return true
                }
                let waiter = Waiter(key: key, continuation: continuation)
                if urgent {
                    waiters[host, default: HostQueue()].urgent.append(waiter)
                } else {
                    waiters[host, default: HostQueue()].background.append(waiter)
                    waitingInBackground.insert(key)
                }
                return false
            }
            if acquired { continuation.resume() }
        }
    }

    /// Call with `lock` held: moves a waiting prefetch to the front of its host's queue.
    private func promote(_ key: String, host: String) {
        guard waitingInBackground.contains(key), var queue = waiters[host],
              let index = queue.background.firstIndex(where: { $0.key == key }) else { return }
        queue.urgent.append(queue.background.remove(at: index))
        waiters[host] = queue
        waitingInBackground.remove(key)
    }

    private func release(_ host: String) {
        lock.lock()
        if var queue = waiters[host], let next = queue.next() {
            waiters[host] = queue.isEmpty ? nil : queue
            waitingInBackground.remove(next.key)
            lock.unlock()
            next.continuation.resume() // hand the slot straight to the next waiter
        } else {
            hostSlots[host] = max(0, hostSlots[host, default: 0] - 1)
            lock.unlock()
        }
    }
}

/// A remote or local image for SwiftUI (covers), using `ImageLoader`.
@MainActor
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var headers: [String: String]? = nil
    let width: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { return }
            let page = ImagePage(url: url, headers: headers)
            if let hit = ImageLoader.shared.cached(page, width: width) {
                image = hit
                return
            }
            image = try? await ImageLoader.shared.load(page, width: width).image
        }
    }
}
