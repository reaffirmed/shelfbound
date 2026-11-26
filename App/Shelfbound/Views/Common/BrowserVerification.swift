import ShelfCore
import SwiftUI
import WebKit

/// A page to open so the person can pass a site's bot check (such as Cloudflare's).
struct VerificationRequest: Identifiable, Hashable {
    let url: URL
    var id: String { url.absoluteString }
    var host: String { url.host?.lowercased() ?? url.absoluteString }

    init(url: URL) { self.url = url }
    init(_ needed: BrowserVerificationNeeded) { url = needed.url }
}

extension Error {
    /// Set when the error is a site's bot check that the person can pass in the browser.
    var verification: VerificationRequest? {
        (self as? BrowserVerificationNeeded).map(VerificationRequest.init)
    }
}

extension View {
    /// Presents the browser check sheet for `item`.
    func browserVerification(_ item: Binding<VerificationRequest?>) -> some View {
        sheet(item: item) { BrowserVerificationSheet(request: $0) }
    }
}

/// "Verify in browser", for places that show a bot-check error.
@MainActor
struct VerifyInBrowserButton: View {
    let request: VerificationRequest
    @State private var showing: VerificationRequest?

    var body: some View {
        Button { showing = request } label: { Label("Verify in browser", systemImage: "checkmark.shield") }
            .browserVerification($showing)
    }
}

/// Opens the site in a normal web view so the person can complete its check themselves.
/// When the site sets its clearance cookie (or the person taps Done), the cookies for that
/// site and the web view's User-Agent are kept, and requests to the host use them until
/// they expire. Shelfbound never fills in or solves the check.
@MainActor
struct BrowserVerificationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: VerificationRequest
    @State private var controller = VerificationController()
    @State private var finishing = false

    var body: some View {
        NavigationStack {
            VerificationWebView(url: request.url, host: request.host, controller: controller) {
                Task { await finish() }
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("\(request.host) checks that visitors are people. Complete the check below, then Shelfbound can read this site until the check expires.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
            .navigationTitle(request.host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await finish() } }.disabled(finishing)
                }
            }
        }
        .interactiveDismissDisabled(finishing)
    }

    private func finish() async {
        guard !finishing else { return }
        finishing = true
        await controller.keepClearance(for: request.host)
        model.didVerify(host: request.host)
        dismiss()
    }
}

@MainActor
final class VerificationController {
    weak var webView: WKWebView?

    /// Copies the site's cookies into the app's cookie store, and remembers the
    /// User-Agent they were issued to.
    func keepClearance(for host: String) async {
        guard let webView else { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        // Not a site's sign-in cookies: those stay in the signed-in source's own jar.
        let model = AppModel.shared
        let signedIn = Set(model.signedInSourceIDs.flatMap { model.accountJars.cookies(for: $0) }.map { "\($0.domain)|\($0.name)" })
        for cookie in cookies where Self.cookie(cookie, appliesTo: host) && !signedIn.contains("\(cookie.domain)|\(cookie.name)") {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        let agent = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String
        if let agent, !agent.isEmpty {
            // Record it for the domain the clearance cookie covers, so subdomains (image
            // CDNs) use the same identity.
            let domain = cookies.first { $0.name == "cf_clearance" && Self.cookie($0, appliesTo: host) }
                .map { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() } ?? host
            ClearanceStore.shared.record(host: domain, userAgent: agent)
        }
    }

    static func cookie(_ cookie: HTTPCookie, appliesTo host: String) -> Bool {
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }
}

@MainActor
struct VerificationWebView: UIViewRepresentable {
    let url: URL
    let host: String
    let controller: VerificationController
    let onCleared: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(host: host, onCleared: onCleared) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // A normal browser, so the site's own check can run. Cookies persist like Safari's.
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1"
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        controller.webView = view
        context.coordinator.watch(view)
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let host: String
        let onCleared: () -> Void
        private var timer: Timer?
        private var done = false

        init(host: String, onCleared: @escaping () -> Void) {
            self.host = host
            self.onCleared = onCleared
        }

        /// Checks once a second for the site's clearance cookie.
        func watch(_ view: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak view] _ in
                Task { @MainActor in
                    guard let self, let view else { return }
                    await self.check(view)
                }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func check(_ view: WKWebView) async {
            guard !done else { return }
            let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
            let cleared = cookies.contains { $0.name == "cf_clearance" && VerificationController.cookie($0, appliesTo: host) }
            guard cleared, !view.isLoading else { return }
            // Wait until the check page has moved on to the real page. A clearance cookie
            // left from an earlier check can already be there while a new check is showing,
            // and the check page's title depends on the phone's language, so look for the
            // check itself.
            let script = "!!(window._cf_chl_opt || document.querySelector('script[src*=\"/cdn-cgi/challenge-platform/h/\"], #challenge-form, #challenge-stage'))"
            let onCheckPage = (try? await view.evaluateJavaScript(script)) as? Bool ?? true
            let title = (view.title ?? "").lowercased()
            guard !onCheckPage, !title.contains("just a moment"), !title.contains("attention required") else { return }
            done = true
            stop()
            onCleared()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Stay on the web; no app links or downloads from here.
            guard let scheme = action.request.url?.scheme, scheme == "https" || scheme == "http" || scheme == "about" else { return .cancel }
            return .allow
        }
    }
}
