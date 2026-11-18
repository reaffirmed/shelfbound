#if canImport(Darwin) && !os(Linux)
import Foundation
import ShelfCore

/// Page downloads on background `URLSession`s, so they continue while the app is
/// suspended or closed. There are two sessions: one that never uses cellular data, and
/// one that may. The app forwards `handleEventsForBackgroundURLSession` here.
public final class BackgroundTransfer: NSObject, FileTransfer, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let wifiIdentifier = "app.shelfbound.downloads.wifi"
    public static let anyNetworkIdentifier = "app.shelfbound.downloads.any"

    private let staging: URL
    private let lock = NSLock()
    private var handler: (@Sendable (TransferEvent) -> Void)?
    private var pendingEvents: [TransferEvent] = []
    private var completionHandlers: [String: () -> Void] = [:]
    private var wifiSession: URLSession!
    private var anySession: URLSession!

    public init(staging: URL) {
        self.staging = staging
        super.init()
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        wifiSession = makeSession(Self.wifiIdentifier, cellular: false)
        anySession = makeSession(Self.anyNetworkIdentifier, cellular: true)
    }

    private func makeSession(_ identifier: String, cellular: Bool) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.allowsCellularAccess = cellular
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func handleEvents(forSession identifier: String, completion: @escaping () -> Void) {
        lock.lock()
        completionHandlers[identifier] = completion
        lock.unlock()
    }

    public func setEventHandler(_ handler: @escaping @Sendable (TransferEvent) -> Void) {
        lock.lock()
        self.handler = handler
        let queued = pendingEvents
        pendingEvents.removeAll()
        lock.unlock()
        queued.forEach(handler)
    }

    public func start(_ request: TransferRequest) {
        let session = request.allowsCellular ? anySession! : wifiSession!
        let task: URLSessionDownloadTask
        if let resume = request.resumeData {
            task = session.downloadTask(withResumeData: resume)
        } else {
            var urlRequest = URLRequest(url: request.url)
            for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
            if let browserAgent = ClearanceStore.shared.userAgent(for: request.url) {
                // The host was verified in the browser; its clearance cookie needs the same identity.
                urlRequest.setValue(browserAgent, forHTTPHeaderField: "User-Agent")
            } else if urlRequest.value(forHTTPHeaderField: "User-Agent") == nil {
                urlRequest.setValue("Shelfbound/0.2 (iOS reader)", forHTTPHeaderField: "User-Agent")
            }
            task = session.downloadTask(with: urlRequest)
        }
        task.taskDescription = request.taskID
        task.resume()
    }

    public func cancel(taskIDs: Set<String>) {
        for session in [wifiSession!, anySession!] {
            session.getAllTasks { tasks in
                for task in tasks where taskIDs.contains(task.taskDescription ?? "") { task.cancel() }
            }
        }
    }

    public func runningTaskIDs() async -> Set<String> {
        var ids = Set<String>()
        for session in [wifiSession!, anySession!] {
            let tasks = await session.allTasks
            for task in tasks where task.state == .running || task.state == .suspended {
                if let id = task.taskDescription { ids.insert(id) }
            }
        }
        return ids
    }

    private func emit(_ event: TransferEvent) {
        lock.lock()
        guard let handler else {
            pendingEvents.append(event)
            lock.unlock()
            return
        }
        lock.unlock()
        handler(event)
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
            let body = (try? Data(contentsOf: location)).map { String(decoding: $0.prefix(20_000), as: UTF8.self) } ?? ""
            if let url = downloadTask.originalRequest?.url ?? http.url,
               BrowserChallenge.isChallenge(status: http.statusCode, headers: headers, body: body) {
                emit(.blocked(taskID: id, url: url))
            } else {
                emit(.failed(taskID: id, message: "HTTP \(http.statusCode)", resumeData: nil))
            }
            return
        }
        // The file at `location` is deleted when this method returns, so move it now.
        let staged = staging.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            emit(.finished(taskID: id, file: staged))
        } catch {
            emit(.failed(taskID: id, message: error.localizedDescription, resumeData: nil))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
            && nsError.userInfo[NSURLSessionDownloadTaskResumeData] == nil {
            return // cancelled on purpose (pause or cancel); the manager already knows
        }
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        emit(.failed(taskID: id, message: error.localizedDescription, resumeData: resume))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        lock.lock()
        let completion = completionHandlers.removeValue(forKey: identifier)
        lock.unlock()
        DispatchQueue.main.async { completion?() }
    }
}
#endif
