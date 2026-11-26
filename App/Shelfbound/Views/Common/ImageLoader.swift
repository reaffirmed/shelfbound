import ImageIO
import ShelfCore
import SwiftUI
import UIKit

/// Loads covers and pages, downsampled to the size they're shown at (never larger than the
/// source), within a pixel budget so a huge strip can't use up memory. Webtoon strips are cut
/// into slices so they're drawn at full sharpness. Keeps a small memory cache, joins
/// duplicate requests, and allows only a few requests per host at a time.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    struct Loaded {
        /// The whole image, or for a sliced strip its first slice.
        var image: UIImage { slices[0] }
        /// The image top to bottom. One slice unless it was loaded `sliced` and is taller
        /// than `sliceHeight`.
        let slices: [UIImage]
        /// Height / width of the original, so readers can size cells before decoding.
        let aspect: CGFloat
    }

    private final class Entry {
        let slices: [UIImage]
        init(_ slices: [UIImage]) { self.slices = slices }
        var cost: Int { slices.reduce(0) { $0 + Int($1.size.width * $1.size.height * $1.scale * $1.scale * 4) } }
    }

    private let cache = NSCache<NSString, Entry>()
    private let aspects = NSCache<NSString, NSNumber>()
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [String: Task<Loaded, Error>] = [:]
    /// Hosts whose pages load only from the browser (see `BrowserFetcher`).
    private var browserHosts: Set<String> = []
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
    /// Largest decoded image, in pixels. Taller images are scaled down to fit.
    private let maxPixels: CGFloat = 12_000_000
    /// The same for webtoon strips, which are cut into slices, so a tall strip keeps its
    /// full width (and sharpness) instead of being shrunk to fit one picture.
    private let maxStripPixels: CGFloat = 24_000_000
    /// Tallest slice, in pixels. Pictures taller than the GPU's largest texture (16,384 on
    /// the iPhones iOS 17 supports) are quietly shrunk when drawn, which blurs them.
    private let sliceHeight = 4096
    /// Screen scale, set once from the main thread at launch.
    var screenScale: CGFloat = 3

    init() {
        cache.totalCostLimit = 160 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = perHost
        session = URLSession(configuration: config)
    }

    func cached(_ page: ImagePage, width: CGFloat) -> UIImage? {
        cache.object(forKey: key(page.url, width, sliced: false) as NSString)?.slices.first
    }

    /// A strip page already loaded with `sliced: true`.
    func cachedSlices(_ page: ImagePage, width: CGFloat) -> [UIImage]? {
        cache.object(forKey: key(page.url, width, sliced: true) as NSString)?.slices
    }

    func knownAspect(_ url: URL) -> CGFloat? {
        aspects.object(forKey: url.absoluteString as NSString).map { CGFloat($0.doubleValue) }
    }

    /// `width` is in points; the image is decoded at screen scale. `urgent` is false for
    /// prefetches, which wait behind pages that are on screen. `sliced` is for webtoon
    /// strips: a taller limit, and the result cut into slices the GPU can draw at full size.
    func load(_ page: ImagePage, width: CGFloat, urgent: Bool = true, sliced: Bool = false) async throws -> Loaded {
        let k = key(page.url, width, sliced: sliced)
        if let entry = cache.object(forKey: k as NSString) {
            let height = entry.slices.reduce(0) { $0 + $1.size.height }
            return Loaded(slices: entry.slices, aspect: knownAspect(page.url) ?? height / max(entry.slices[0].size.width, 1))
        }
        let task: Task<Loaded, Error> = lock.withLock {
            if let existing = inFlight[k] {
                if urgent { promote(k, host: page.url.host ?? "") }
                return existing
            }
            let created = Task(priority: urgent ? .userInitiated : .utility) {
                try await self.fetchAndDecode(page, width: width, key: k, urgent: urgent, sliced: sliced)
            }
            inFlight[k] = created
            return created
        }
        defer { lock.withLock { inFlight[k] = nil } }
        let loaded = try await task.value
        let entry = Entry(loaded.slices)
        cache.setObject(entry, forKey: k as NSString, cost: entry.cost)
        return loaded
    }

    func prefetch(_ pages: [ImagePage], width: CGFloat) {
        for page in pages where cached(page, width: width) == nil {
            Task(priority: .utility) { _ = try? await self.load(page, width: width, urgent: false) }
        }
    }

    private func key(_ url: URL, _ width: CGFloat, sliced: Bool) -> String {
        "\(Int(width))\(sliced ? "s" : "")|\(url.absoluteString)"
    }

    private func fetchAndDecode(_ page: ImagePage, width: CGFloat, key: String, urgent: Bool, sliced: Bool) async throws -> Loaded {
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
            if lock.withLock({ browserHosts.contains(host) }),
               let viaBrowser = try? await BrowserFetcher.shared.fetch(request), (200..<300).contains(viaBrowser.status) {
                try Task.checkCancellation()
                return try decode(viaBrowser.body, url: page.url, width: width, sliced: sliced)
            }
            let (body, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
                if BrowserChallenge.isChallenge(status: http.statusCode, headers: headers, body: String(decoding: body.prefix(20_000), as: UTF8.self)) {
                    // Passed in the browser, but the site still stops the app's own requests:
                    // ask from the browser instead.
                    if ClearanceStore.shared.userAgent(for: page.url) != nil,
                       let viaBrowser = try? await BrowserFetcher.shared.fetch(request),
                       (200..<300).contains(viaBrowser.status) {
                        lock.withLock { _ = browserHosts.insert(host) }
                        try Task.checkCancellation()
                        return try decode(viaBrowser.body, url: page.url, width: width, sliced: sliced)
                    }
                    throw BrowserVerificationNeeded(url: page.url)
                }
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            data = body
        }
        try Task.checkCancellation()
        return try decode(data, url: page.url, width: width, sliced: sliced)
    }

    private func decode(_ data: Data, url: URL, width: CGFloat, sliced: Bool) throws -> Loaded {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            throw URLError(.cannotDecodeContentData)
        }
        var aspect: CGFloat = 1.4
        var pixelWidth: CGFloat = 0
        var upright = false
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0 {
            aspect = h / w
            pixelWidth = w
            upright = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) == 1
            aspects.setObject(NSNumber(value: Double(aspect)), forKey: url.absoluteString as NSString)
        }
        let scale = screenScale
        let limit = sliced ? maxStripPixels : maxPixels
        var targetWidth = width * scale
        if pixelWidth > 0 { targetWidth = min(targetWidth, pixelWidth) }
        if targetWidth * targetWidth * aspect > limit {
            targetWidth = (limit / aspect).squareRoot()
        }
        let cgImage: CGImage?
        if upright, pixelWidth > 0, targetWidth >= pixelWidth {
            // Shown at (or above) its own size: decode the original pixels as they are.
            // A "thumbnail" of the same size goes through a resampling pass that softens it.
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            let longest = max(targetWidth, targetWidth * aspect)
            let thumbOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, Int(longest.rounded(.up))),
            ] as CFDictionary
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions)
        }
        guard let cgImage else { throw URLError(.cannotDecodeContentData) }
        let parts = sliced && cgImage.height > sliceHeight ? slice(cgImage) : [cgImage]
        return Loaded(slices: parts.map { UIImage(cgImage: $0, scale: scale, orientation: .up) }, aspect: aspect)
    }

    /// Cuts a tall picture into slices no taller than `sliceHeight`, each drawn into its own
    /// bitmap here (off the main thread) so showing them needs no more work.
    private func slice(_ image: CGImage) -> [CGImage] {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [image] }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        var slices: [CGImage] = []
        var y = 0
        while y < image.height {
            let h = min(sliceHeight, image.height - y)
            guard let part = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: h)),
                  let context = CGContext(data: nil, width: image.width, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
            else { return [image] }
            context.interpolationQuality = .none
            context.draw(part, in: CGRect(x: 0, y: 0, width: image.width, height: h))
            guard let made = context.makeImage() else { return [image] }
            slices.append(made)
            y += h
        }
        return slices
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
