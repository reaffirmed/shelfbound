import LibraryKit
import ShelfCore
import SwiftUI
import WebKit

/// WKWebView with page JavaScript off, a CSP from `ReaderDocument`, and links opened in
/// Safari. Only our own injected script runs: it reports scroll progress and taps,
/// underlines glossary terms and marks highlights. Selecting text adds "Highlight" and
/// "Add Note" to the edit menu.
@MainActor
struct TextWebView: UIViewRepresentable {
    let html: String
    let restoreProgress: Double
    let glossary: [String]
    var highlights: [Highlight] = []
    /// Ask the page for its paragraphs, to translate them.
    var wantsParagraphs = false
    /// Translated paragraphs to show in place of the original; nil shows the original.
    var translation: [String]?
    /// Set to jump to a position (0...1); cleared after use.
    @Binding var seek: Double?
    var pullToAdvance: Bool
    var onProgress: (Double) -> Void
    var onTap: () -> Void
    var onGlossaryTerm: (Int) -> Void
    /// A passage was selected and highlighted; the flag is true when the reader asked to add a note.
    var onHighlight: (TextSelection, Bool) -> Void = { _, _ in }
    var onHighlightTap: (UUID) -> Void = { _ in }
    var onParagraphs: ([String]) -> Void = { _ in }
    var onNext: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.dataDetectorTypes = []
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: ReaderDocument.readerScript + Self.tapScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        for name in Self.handlers {
            controller.add(context.coordinator, name: name)
        }

        let view = ReaderWebView(frame: .zero, configuration: config)
        view.onMenuAction = { [weak coordinator = context.coordinator, weak view] withNote in
            guard let coordinator, let view else { return }
            coordinator.highlightSelection(in: view, withNote: withNote)
        }
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
            coordinator.appliedHighlights = []
            coordinator.appliedTranslation = nil
            coordinator.sentParagraphs = false
            coordinator.loaded = false
            view.loadHTMLString(html, baseURL: nil)
        } else if coordinator.loaded {
            coordinator.syncPage(view)
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
        for name in handlers {
            view.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        coordinator.stopObserving()
    }

    private static let handlers = ["progress", "glossary", "tap", "highlight"]

    /// A tap anywhere that isn't a link, glossary term or highlight toggles the reader's bars.
    private static let tapScript = """
    document.addEventListener("click", function (e) {
      if (!window.getSelection().isCollapsed) return;
      if (e.target.closest && (e.target.closest("a") || e.target.closest(".gl") || e.target.closest("mark.hl") || e.target.closest("summary"))) return;
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
        var loaded = false
        /// Highlight IDs currently marked in the page.
        var appliedHighlights: Set<UUID> = []
        var appliedTranslation: [String]?
        var sentParagraphs = false
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
            case "highlight":
                if let id = (message.body as? String).flatMap(UUID.init(uuidString:)) { parent?.onHighlightTap(id) }
            default:
                break
            }
        }

        /// Brings the page in line with the view: paragraphs for translation, the
        /// translation itself, then glossary terms and highlights over the text shown.
        func syncPage(_ view: WKWebView) {
            guard let parent else { return }
            if parent.wantsParagraphs, !sentParagraphs {
                sentParagraphs = true
                view.evaluateJavaScript("window.__shelfParagraphs();") { [weak self] result, _ in
                    guard let json = result as? String, let data = json.data(using: .utf8),
                          let list = try? JSONDecoder().decode([String].self, from: data) else { return }
                    Task { @MainActor in self?.parent?.onParagraphs(list) }
                }
            }
            if parent.translation != appliedTranslation {
                appliedTranslation = parent.translation
                if let list = parent.translation,
                   let data = try? JSONSerialization.data(withJSONObject: list), let json = String(data: data, encoding: .utf8) {
                    view.evaluateJavaScript("window.__shelfTranslate(\(json));")
                } else {
                    view.evaluateJavaScript("window.__shelfOriginal();")
                }
                // Swapping the text removed the glossary underlines and highlight marks.
                applyGlossary(view)
                appliedHighlights = []
            }
            syncHighlights(view)
        }

        private func applyGlossary(_ view: WKWebView) {
            if let terms = parent?.glossary, !terms.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: terms), let json = String(data: data, encoding: .utf8) {
                view.evaluateJavaScript("window.__shelfGlossary(\(json));")
            }
        }

        /// Marks new highlights and unmarks deleted ones, without reloading the page.
        func syncHighlights(_ view: WKWebView) {
            let current = parent?.highlights ?? []
            let ids = Set(current.map(\.id))
            for id in appliedHighlights.subtracting(ids) {
                view.evaluateJavaScript("window.__shelfUnhighlight(\"\(id.uuidString)\");")
            }
            let added = current.filter { !appliedHighlights.contains($0.id) }
            appliedHighlights = ids
            guard !added.isEmpty else { return }
            let marks = added.map { ["id": $0.id.uuidString, "exact": $0.exact, "prefix": $0.prefix, "suffix": $0.suffix] }
            if let data = try? JSONSerialization.data(withJSONObject: marks), let json = String(data: data, encoding: .utf8) {
                view.evaluateJavaScript("window.__shelfHighlights(\(json));")
            }
        }

        func highlightSelection(in view: WKWebView, withNote: Bool) {
            view.evaluateJavaScript("window.__shelfSelection();") { [weak self] result, _ in
                guard let json = result as? String, let data = json.data(using: .utf8),
                      let selection = try? JSONDecoder().decode(TextSelection.self, from: data) else { return }
                Task { @MainActor in self?.parent?.onHighlight(selection, withNote) }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyGlossary(webView)
            loaded = true
            syncPage(webView)
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

/// The passage selected in the text reader, with the text either side of it.
struct TextSelection: Decodable, Sendable {
    var exact: String
    var prefix: String
    var suffix: String
}

/// Adds the highlight actions to the menu shown over selected text.
final class ReaderWebView: WKWebView {
    var onMenuAction: ((Bool) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let highlight = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
            self?.onMenuAction?(false)
        }
        let note = UIAction(title: "Add Note", image: UIImage(systemName: "note.text.badge.plus")) { [weak self] _ in
            self?.onMenuAction?(true)
        }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [highlight, note]), atStartOfMenu: .standardEdit)
    }
}
