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
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
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

    /// `width` is in points; the image is decoded at screen scale.
    func load(_ page: ImagePage, width: CGFloat) async throws -> Loaded {
        let k = key(page.url, width)
        if let image = cache.object(forKey: k as NSString) {
            return Loaded(image: image, aspect: knownAspect(page.url) ?? image.size.height / max(image.size.width, 1))
        }
        let task: Task<Loaded, Error> = lock.withLock {
            if let existing = inFlight[k] { return existing }
            let created = Task { try await self.fetchAndDecode(page, width: width) }
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
            Task(priority: .utility) { _ = try? await self.load(page, width: width) }
        }
    }

    private func key(_ url: URL, _ width: CGFloat) -> String { "\(Int(width))|\(url.absoluteString)" }

    private func fetchAndDecode(_ page: ImagePage, width: CGFloat) async throws -> Loaded {
        let data: Data
        if page.url.isFileURL {
            data = try Data(contentsOf: page.url)
        } else {
            let host = page.url.host ?? ""
            await acquire(host)
            defer { release(host) }
            var request = URLRequest(url: page.url)
            for (field, value) in page.headers ?? [:] { request.setValue(value, forHTTPHeaderField: field) }
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue("Shelfbound/0.2 (iOS reader)", forHTTPHeaderField: "User-Agent")
            }
            let (body, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
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

    private func acquire(_ host: String) async {
        if tryAcquire(host) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired: Bool = lock.withLock {
                if hostSlots[host, default: 0] < perHost {
                    hostSlots[host, default: 0] += 1
                    return true
                }
                waiters[host, default: []].append(continuation)
                return false
            }
            if acquired { continuation.resume() }
        }
    }

    private func release(_ host: String) {
        lock.lock()
        if var queue = waiters[host], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[host] = queue
            lock.unlock()
            next.resume() // hand the slot straight to the next waiter
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
