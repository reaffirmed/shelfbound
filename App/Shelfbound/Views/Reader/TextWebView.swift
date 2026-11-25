import ShelfCore
import SwiftUI
import WebKit

/// WKWebView with page JavaScript off, a CSP from `ReaderDocument`, and links opened in
/// Safari. Only our own injected script runs: it reports scroll progress and taps, and
/// underlines glossary terms.
@MainActor
struct TextWebView: UIViewRepresentable {
    let html: String
    let restoreProgress: Double
    let glossary: [String]
    /// Set to jump to a position (0...1); cleared after use.
    @Binding var seek: Double?
    var pullToAdvance: Bool
    var onProgress: (Double) -> Void
    var onTap: () -> Void
    var onGlossaryTerm: (Int) -> Void
    var onNext: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.dataDetectorTypes = []
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: ReaderDocument.readerScript + Self.tapScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        for name in ["progress", "glossary", "tap"] {
            controller.add(context.coordinator, name: name)
        }

        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.loadedHTML != html {
            // Keep the reader's place when only the style changes.
            let keep = coordinator.loadedHTML == nil || coordinator.loadedChapterHTML != chapterKey ? restoreProgress : coordinator.lastProgress
            coordinator.loadedHTML = html
            coordinator.loadedChapterHTML = chapterKey
            coordinator.pendingRestore = keep
            view.loadHTMLString(html, baseURL: nil)
        }
        if let seek {
            coordinator.scroll(view, to: seek)
            DispatchQueue.main.async { self.seek = nil }
        }
    }

    /// Identifies the chapter regardless of styling, so a theme change keeps the position
    /// but a new chapter starts at its own saved place.
    private var chapterKey: String {
        guard let start = html.range(of: "<article>"), let end = html.range(of: "</article>") else { return html }
        return String(html[start.upperBound..<end.lowerBound].prefix(2000))
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        for name in ["progress", "glossary", "tap"] {
            view.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        coordinator.stopObserving()
    }

    /// A tap anywhere that isn't a link or glossary term toggles the reader's bars.
    private static let tapScript = """
    document.addEventListener("click", function (e) {
      if (e.target.closest && (e.target.closest("a") || e.target.closest(".gl") || e.target.closest("summary"))) return;
      window.webkit.messageHandlers.tap.postMessage(1);
    });
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: TextWebView?
        var loadedHTML: String?
        var loadedChapterHTML: String?
        var pendingRestore: Double = 0
        var lastProgress: Double = 0
        private var offsetObservation: NSKeyValueObservation?
        private var advanceArmed = true

        func observe(_ view: WKWebView) {
            // Pulling up past the end of the chapter opens the next one.
            offsetObservation = view.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                Task { @MainActor in self?.checkPull(scrollView) }
            }
        }

        func stopObserving() {
            offsetObservation?.invalidate()
            offsetObservation = nil
        }

        private func checkPull(_ scrollView: UIScrollView) {
            guard let parent, parent.pullToAdvance, scrollView.isDragging else {
                if !scrollView.isDragging { advanceArmed = true }
                return
            }
            let overscroll = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.contentSize.height
            if overscroll > 90, advanceArmed, scrollView.contentSize.height > scrollView.bounds.height {
                advanceArmed = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                parent.onNext()
            }
        }

        func scroll(_ view: WKWebView, to progress: Double) {
            view.evaluateJavaScript("window.scrollTo(0, (document.documentElement.scrollHeight - window.innerHeight) * \(progress));")
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "progress":
                guard let value = message.body as? Double else { return }
                lastProgress = value
                parent?.onProgress(value)
            case "glossary":
                if let index = message.body as? Int { parent?.onGlossaryTerm(index) }
                else if let index = message.body as? Double { parent?.onGlossaryTerm(Int(index)) }
            case "tap":
                parent?.onTap()
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let terms = parent?.glossary, !terms.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: terms), let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("window.__shelfGlossary(\(json));")
            }
            let p = pendingRestore
            pendingRestore = 0
            if p > 0 { scroll(webView, to: p) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == ReaderDocument.actionScheme {
                if url.host == "next" { parent?.onNext() }
                return .cancel
            }
            if action.navigationType == .linkActivated, url.scheme == "https" || url.scheme == "http" {
                _ = await UIApplication.shared.open(url)
                return .cancel
            }
            return action.navigationType == .other ? .allow : .cancel
        }
    }
}
