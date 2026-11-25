#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import ShelfCore
import SwiftSoup

/// Runs one source package in its own JavaScript virtual machine.
///
/// Sandboxing:
/// - Each source gets a separate `JSVirtualMachine`, so sources share no objects.
/// - JavaScriptCore has no network, file, or timer APIs of its own. The only way out is
///   the `host` object from `Prelude`, and `host.fetch` only reaches the domains in the
///   manifest, through `HostNetwork` (which adds rate limits).
/// - Every call has a timeout. A synchronous infinite loop still blocks this source's
///   queue (JavaScriptCore has no public execution time limit); other sources keep working.
/// - Results are JSON, decoded into `ShelfCore` types before the UI sees them.
public final class SourceRuntime: @unchecked Sendable {
    public let manifest: SourceManifest

    private let queue: DispatchQueue
    private let context: JSContext
    private let network: HostNetwork
    private let policy: DomainPolicy
    private let settings: [String: String]
    private let timeout: TimeInterval
    private let logger: @Sendable (String) -> Void

    // Touched only on `queue`.
    private var calls: [Int: CheckedContinuation<String, Error>] = [:]
    private var nextCallID = 0
    private var lastException: String?
    private var isClosed = false
    private var optionalFunctions: Set<String> = []
    /// Set when a fetch hit a bot check, or the source said a host needs one. The call
    /// that's running then fails with `BrowserVerificationNeeded`, whatever the script threw.
    private var verificationNeeded: BrowserVerificationNeeded?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom(SourceDates.decode)
        return d
    }()

    public init(
        package: SourcePackage,
        network: HostNetwork,
        settings: [String: String] = [:],
        timeout: TimeInterval = 30,
        logger: @escaping @Sendable (String) -> Void = { print($0) }
    ) throws {
        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else {
            throw SourceError.scriptFailed("Could not create a JavaScript context.")
        }
        self.manifest = package.manifest
        self.context = context
        self.network = network
        self.policy = DomainPolicy(patterns: package.manifest.domains)
        self.settings = settings
        self.timeout = timeout
        self.logger = logger
        self.queue = DispatchQueue(label: "shelfbound.source.\(package.manifest.id)")
        context.name = package.manifest.id

        try queue.sync { try self.load(script: package.script) }
    }

    deinit {
        for (_, continuation) in calls { continuation.resume(throwing: SourceError.unavailable) }
    }

    // MARK: - Source API

    public func search(query: String, page: Int = 1, filters: [String: [String]] = [:]) async throws -> SearchPage {
        try await invoke("search", [query, page, filters])
    }

    /// Filters from the optional `getFilters()`. Empty when the source has none.
    public func getFilters() async throws -> [SearchFilter] {
        guard implements("getFilters") else { return [] }
        return try await invoke("getFilters", [])
    }

    /// Reads a chapter link another source handed over. Needs the "links" capability.
    public func resolveLink(_ url: URL) async throws -> ChapterContent {
        guard implements("resolveLink") else { throw SourceError.missingFunction("resolveLink") }
        return try await invoke("resolveLink", [url.absoluteString])
    }

    /// Whether the script defines an optional function.
    public func implements(_ function: String) -> Bool { optionalFunctions.contains(function) }

    public func getWork(id: String) async throws -> Work {
        try await invoke("getWork", [id])
    }

    public func getChapters(workID: String) async throws -> [Chapter] {
        try await invoke("getChapters", [workID])
    }

    public func getChapterContent(workID: String, chapterID: String) async throws -> ChapterContent {
        try await invoke("getChapterContent", [workID, chapterID])
    }

    /// Stops the source. Pending calls fail with `SourceError.unavailable`.
    public func close() {
        queue.async {
            self.isClosed = true
            let pending = self.calls
            self.calls.removeAll()
            for (_, continuation) in pending { continuation.resume(throwing: SourceError.unavailable) }
        }
    }

    // MARK: - Calling into JavaScript

    private func invoke<T: Decodable>(_ function: String, _ args: [Any]) async throws -> T {
        let json = try await call(function, args)
        do {
            return try decoder.decode(T.self, from: Data(json.utf8))
        } catch {
            throw SourceError.badResult(function: function, message: String(describing: error))
        }
    }

    private func call(_ function: String, _ args: [Any]) async throws -> String {
        let argsJSON = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.isClosed else {
                    continuation.resume(throwing: SourceError.unavailable)
                    return
                }
                self.nextCallID += 1
                let id = self.nextCallID
                self.calls[id] = continuation
                self.context.objectForKeyedSubscript("__call")
                    .call(withArguments: [id, function, argsJSON])
                if let message = self.lastException {
                    self.lastException = nil
                    self.finish(id, .failure(SourceError.callFailed(function: function, message: message)))
                    return
                }
                self.queue.asyncAfter(deadline: .now() + self.timeout) {
                    self.finish(id, .failure(SourceError.timedOut(function: function)))
                }
            }
        }
    }

    /// Must run on `queue`.
    private func finish(_ id: Int, _ result: Result<String, Error>) {
        guard let continuation = calls.removeValue(forKey: id) else { return }
        let verification = verificationNeeded
        verificationNeeded = nil
        if case .failure = result, let verification {
            continuation.resume(throwing: verification)
        } else {
            continuation.resume(with: result)
        }
    }

    // MARK: - Setup

    /// Must run on `queue`.
    private func load(script: String) throws {
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "Unknown JavaScript error"
        }

        let native = JSValue(newObjectIn: context)!

        let fetch: @convention(block) (JSValue, JSValue) -> Void = { [weak self] id, json in
            self?.handleFetch(id: Int(id.toInt32()), json: json.toString())
        }
        let select: @convention(block) (JSValue, JSValue) -> String = { html, selector in
            do {
                return try Self.select(html: html.toString(), selector: selector.toString())
            } catch {
                if let ctx = JSContext.current() {
                    ctx.exception = JSValue(newErrorFromMessage: "select failed: \(error)", in: ctx)
                }
                return "[]"
            }
        }
        let log: @convention(block) (JSValue) -> Void = { [weak self] message in
            guard let self else { return }
            self.logger("[\(self.manifest.id)] \(message.toString() ?? "")")
        }
        let setting: @convention(block) (JSValue) -> JSValue = { [weak self] key in
            let ctx = JSContext.current()!
            guard let self, let value = self.settings[key.toString()] else {
                return JSValue(undefinedIn: ctx)
            }
            return JSValue(object: value, in: ctx)
        }
        let done: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] id, ok, payload in
            guard let self else { return }
            let callID = Int(id.toInt32())
            let message = payload.toString() ?? ""
            if ok.toBool() {
                self.finish(callID, .success(message))
            } else {
                self.finish(callID, .failure(SourceError.callFailed(function: "source", message: message)))
            }
        }

        native.setObject(unsafeBitCast(fetch, to: AnyObject.self), forKeyedSubscript: "fetch" as NSString)
        native.setObject(unsafeBitCast(select, to: AnyObject.self), forKeyedSubscript: "select" as NSString)
        native.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
        native.setObject(unsafeBitCast(setting, to: AnyObject.self), forKeyedSubscript: "setting" as NSString)
        let verify: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, let url = URL(string: value.toString() ?? ""), url.scheme == "https", self.policy.allows(url) else { return }
            self.verificationNeeded = BrowserVerificationNeeded(url: url)
        }

        native.setObject(unsafeBitCast(done, to: AnyObject.self), forKeyedSubscript: "done" as NSString)
        native.setObject(unsafeBitCast(verify, to: AnyObject.self), forKeyedSubscript: "verify" as NSString)
        context.setObject(native, forKeyedSubscript: "__native" as NSString)

        context.evaluateScript(Prelude.script, withSourceURL: URL(string: "shelfbound://prelude.js"))
        if let message = lastException {
            throw SourceError.scriptFailed("prelude: \(message)")
        }

        context.evaluateScript(script, withSourceURL: URL(string: "shelfbound://\(manifest.id)/main.js"))
        if let message = lastException {
            lastException = nil
            throw SourceError.scriptFailed(message)
        }

        guard let source = context.objectForKeyedSubscript("source"), source.isObject else {
            throw SourceError.scriptFailed("The script must assign globalThis.source = { ... }.")
        }
        for name in ["search", "getWork", "getChapters", "getChapterContent"] {
            guard let fn = source.objectForKeyedSubscript(name), !fn.isUndefined else {
                throw SourceError.missingFunction(name)
            }
        }
        for name in ["getFilters", "resolveLink", "getLatest"] {
            if let fn = source.objectForKeyedSubscript(name), !fn.isUndefined, !fn.isNull {
                optionalFunctions.insert(name)
            }
        }
    }

    // MARK: - Host functions

    /// Called on `queue` from JavaScript.
    private func handleFetch(id: Int, json: String?) {
        let request: URLRequest
        let options: FetchOptions
        do {
            (request, options) = try makeRequest(json)
        } catch {
            resolveFetch(id: id, ok: false, payload: error.localizedDescription)
            return
        }
        let network = self.network
        let sourceID = manifest.id
        Task {
            do {
                let response = try await network.fetch(request, sourceID: sourceID, options: options)
                let payload = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
                self.queue.async { self.resolveFetch(id: id, ok: true, payload: payload) }
            } catch {
                let message = error.localizedDescription
                let verification = error as? BrowserVerificationNeeded
                self.queue.async {
                    if let verification { self.verificationNeeded = verification }
                    self.resolveFetch(id: id, ok: false, payload: message)
                }
            }
        }
    }

    private func makeRequest(_ json: String?) throws -> (URLRequest, FetchOptions) {
        guard let json, let hostRequest = try? JSONDecoder().decode(HostRequest.self, from: Data(json.utf8)) else {
            throw SourceError.badRequest("fetch needs a URL string or { url, method, headers, body }.")
        }
        guard let url = URL(string: hostRequest.url) else {
            throw SourceError.badRequest("Invalid URL \(hostRequest.url)")
        }
        guard policy.allows(url) else {
            throw SourceError.domainNotAllowed(url.host ?? hostRequest.url)
        }
        var request = URLRequest(url: url, timeoutInterval: min(timeout, 30))
        request.httpMethod = hostRequest.method ?? "GET"
        for (key, value) in hostRequest.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = hostRequest.body.map { Data($0.utf8) }
        let policy = self.policy
        let options = FetchOptions(
            followRedirects: hostRequest.redirect != "manual",
            allowRedirect: { policy.allows($0) })
        return (request, options)
    }

    /// Must run on `queue`.
    private func resolveFetch(id: Int, ok: Bool, payload: String) {
        guard !isClosed else { return }
        context.objectForKeyedSubscript("__resolveFetch").call(withArguments: [id, ok, payload])
    }

    static func select(html: String?, selector: String?) throws -> String {
        let document = try SwiftSoup.parse(html ?? "")
        var out: [[String: Any]] = []
        for element in try document.select(selector ?? "").array() {
            var attrs: [String: String] = [:]
            if let attributes = element.getAttributes() {
                for attribute in attributes {
                    attrs[attribute.getKey()] = attribute.getValue()
                }
            }
            out.append([
                "text": try element.text(),
                "html": try element.html(),
                "outerHTML": try element.outerHtml(),
                "attrs": attrs,
            ])
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self)
    }
}
#endif
