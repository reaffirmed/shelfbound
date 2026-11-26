import Foundation
import ShelfCore
import SourceKit
import WebKit

/// Sends requests from inside a web view that shares the browser check's cookies and
/// identity. Some sites (behind Cloudflare) keep showing their check to the app's own
/// requests even after the person passed it in the browser, because they can tell those
/// requests apart from a browser's. A `fetch()` from a page on the site itself is the
/// browser's own request, so the person's pass works for it.
///
/// Each site gets a blank page with the site's address (nothing is loaded from the site
/// for it), so requests are same-origin and carry the site's cookies. This never fills in
/// or solves a check: when the browser is shown one too, the person is asked to verify.
@MainActor
final class BrowserFetcher: NSObject, WKNavigationDelegate {
    static let shared = BrowserFetcher()

    struct Response {
        var status: Int
        var url: String
        var headers: [String: String]
        var body: Data
    }

    private var views: [String: WKWebView] = [:]
    private var order: [String] = []
    private var loading: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]
    private var ready: Set<ObjectIdentifier> = []
    private let maxViews = 4

    /// Headers a page's fetch() can't set. The browser sends its own.
    private static let browserOwned: Set<String> = [
        "user-agent", "cookie", "referer", "host", "origin", "connection", "content-length",
        "accept-encoding", "accept-charset", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade",
    ]

    private static let script = """
        const init = { method, headers, credentials: "include", redirect: "follow", cache: "no-store" };
        if (body !== null) init.body = body;
        if (referrer) init.referrer = referrer;
        if (typeof AbortSignal !== "undefined" && AbortSignal.timeout) init.signal = AbortSignal.timeout(30000);
        const r = await fetch(url, init);
        const blob = await r.blob();
        const data = await new Promise((ok, fail) => {
          const reader = new FileReader();
          reader.onload = () => ok(String(reader.result));
          reader.onerror = () => fail(reader.error);
          reader.readAsDataURL(blob);
        });
        const out = {};
        r.headers.forEach((v, k) => { out[k] = v; });
        return { status: r.status, url: r.url, headers: out, data };
        """

    /// For `URLSessionNetwork`: the response as a source sees it.
    nonisolated static func hostResponse(for request: URLRequest) async throws -> HostResponse? {
        guard let response = try await shared.fetch(request) else { return nil }
        let body = String(data: response.body, encoding: .utf8) ?? String(decoding: response.body, as: UTF8.self)
        return HostResponse(status: response.status, url: response.url, headers: response.headers, body: body)
    }

    /// Sends `request` from a page on its site. Nil when it isn't a web request.
    func fetch(_ request: URLRequest) async throws -> Response? {
        guard let url = request.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let origin = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
        let view = await page(for: origin)

        var headers: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] where !Self.browserOwned.contains(key.lowercased()) {
            headers[key] = value
        }
        // Only a referrer on the same site is kept, as a browser would.
        let referrer = request.value(forHTTPHeaderField: "Referer").flatMap(URL.init(string:))
            .flatMap { $0.host?.lowercased() == host ? $0.absoluteString : nil } ?? ""
        let body: Any = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? NSNull()
        let result = try await view.callAsyncJavaScript(
            Self.script,
            arguments: [
                "url": url.absoluteString, "method": request.httpMethod ?? "GET", "headers": headers,
                "body": body, "referrer": referrer,
            ],
            in: nil, contentWorld: .defaultClient)
        guard let dict = result as? [String: Any], let status = (dict["status"] as? NSNumber)?.intValue,
              let dataURL = dict["data"] as? String else { return nil }
        let base64 = dataURL.split(separator: ",", maxSplits: 1).last.map(String.init) ?? ""
        let data = Data(base64Encoded: base64) ?? Data()
        var outHeaders: [String: String] = [:]
        for (key, value) in dict["headers"] as? [String: Any] ?? [:] { outHeaders[key.lowercased()] = "\(value)" }
        return Response(status: status, url: dict["url"] as? String ?? url.absoluteString, headers: outHeaders, body: data)
    }

    private func page(for origin: String) async -> WKWebView {
        let view: WKWebView
        if let existing = views[origin] {
            view = existing
            order.removeAll { $0 == origin }
            order.append(origin)
        } else {
            let config = WKWebViewConfiguration()
            // The same cookies and identity as the browser check.
            config.websiteDataStore = .default()
            config.applicationNameForUserAgent = VerificationWebView.applicationName
            view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
            view.navigationDelegate = self
            views[origin] = view
            order.append(origin)
            if order.count > maxViews, let oldest = order.first {
                order.removeFirst()
                if let old = views.removeValue(forKey: oldest) {
                    ready.remove(ObjectIdentifier(old))
                    loading[ObjectIdentifier(old)]?.forEach { $0.resume() }
                    loading[ObjectIdentifier(old)] = nil
                }
            }
            view.loadHTMLString("<!doctype html><title></title>", baseURL: URL(string: origin + "/"))
        }
        let id = ObjectIdentifier(view)
        if !ready.contains(id) {
            await withCheckedContinuation { loading[id, default: []].append($0) }
        }
        return view
    }

    private func finishedLoading(_ view: WKWebView) {
        let id = ObjectIdentifier(view)
        ready.insert(id)
        loading[id]?.forEach { $0.resume() }
        loading[id] = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishedLoading(webView) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishedLoading(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishedLoading(webView)
    }
}
