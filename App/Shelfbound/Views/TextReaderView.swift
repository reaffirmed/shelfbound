import ShelfCore
import SwiftUI
import WebKit

/// Full-screen reader for one work. Text chapters render in a locked-down web view;
/// image chapters get their own reader in the next milestone.
struct ReaderContainer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let sourceID: String
    let workID: String
    let chapters: [Chapter]
    @State var index: Int

    @State private var content: ChapterContent?
    @State private var error: String?
    @State private var showingStyle = false
    @State private var restoreProgress: Double = 0

    init(sourceID: String, workID: String, chapters: [Chapter], startIndex: Int) {
        self.sourceID = sourceID
        self.workID = workID
        self.chapters = chapters
        _index = State(initialValue: startIndex)
    }

    private var chapter: Chapter { chapters[index] }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                switch content {
                case let .text(html, before, after):
                    TextWebView(
                        html: ReaderDocument.html(title: chapter.title, body: html, notesBefore: before, notesAfter: after, style: model.readerStyle),
                        restoreProgress: restoreProgress,
                        onProgress: saveProgress
                    )
                    .ignoresSafeArea(edges: .bottom)
                case .images:
                    ContentUnavailableView("Image reader coming next", systemImage: "photo.stack",
                                           description: Text("This build reads text sources. Paged and webtoon modes are the next milestone."))
                case nil:
                    if let error {
                        ContentUnavailableView {
                            Label("Couldn't load chapter", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try again") { Task { await load() } }
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
            .background(Color(uiColor: readerBackground))
            .navigationTitle(chapter.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingStyle = true } label: { Image(systemName: "textformat.size") }
                        .accessibilityLabel("Reading appearance")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { go(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0)
                        .accessibilityLabel("Previous chapter")
                    Spacer()
                    Text("\(index + 1) of \(chapters.count)").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button { go(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(index >= chapters.count - 1)
                        .accessibilityLabel("Next chapter")
                }
            }
            .sheet(isPresented: $showingStyle) {
                Form { ReaderStyleControls(style: $model.readerStyle) }
                    .presentationDetents([.height(280)])
            }
        }
        .task(id: index) { await load() }
    }

    private var readerBackground: UIColor {
        switch model.readerStyle.theme {
        case .light: .white
        case .sepia: UIColor(red: 0.965, green: 0.937, blue: 0.886, alpha: 1)
        case .dark: UIColor(white: 0.07, alpha: 1)
        }
    }

    private func go(_ delta: Int) {
        let next = index + delta
        guard chapters.indices.contains(next) else { return }
        restoreProgress = 0
        content = nil
        index = next
    }

    private func load() async {
        error = nil
        if let saved = model.position(sourceID: sourceID, workID: workID), saved.chapterID == chapter.id {
            restoreProgress = saved.progress
        }
        do {
            content = try await model.runtime(for: sourceID).getChapterContent(workID: workID, chapterID: chapter.id)
            saveProgress(restoreProgress)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveProgress(_ progress: Double) {
        model.savePosition(
            ReadingPosition(chapterID: chapter.id, chapterTitle: chapter.title, progress: progress, updatedAt: Date()),
            sourceID: sourceID, workID: workID)
    }
}

/// WKWebView with page JavaScript off, a CSP from `ReaderDocument`, and links opened in Safari.
/// Only our own injected script runs, to report and restore the scroll position.
struct TextWebView: UIViewRepresentable {
    let html: String
    let restoreProgress: Double
    let onProgress: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onProgress: onProgress) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let progressScript = """
        (function () {
          let last = -1;
          window.addEventListener("scroll", function () {
            const max = document.documentElement.scrollHeight - window.innerHeight;
            const p = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
            if (Math.abs(p - last) > 0.01) { last = p; window.webkit.messageHandlers.progress.postMessage(p); }
          }, { passive: true });
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: progressScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "progress")

        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onProgress = onProgress
        guard context.coordinator.loadedHTML != html else { return }
        // Keep the reader's place when only the style changes.
        let keep = context.coordinator.loadedHTML == nil ? restoreProgress : context.coordinator.lastProgress
        context.coordinator.loadedHTML = html
        context.coordinator.pendingRestore = keep
        view.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "progress")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onProgress: (Double) -> Void
        var loadedHTML: String?
        var pendingRestore: Double = 0
        var lastProgress: Double = 0

        init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double else { return }
            lastProgress = value
            onProgress(value)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard pendingRestore > 0 else { return }
            let p = pendingRestore
            pendingRestore = 0
            webView.evaluateJavaScript(
                "window.scrollTo(0, (document.documentElement.scrollHeight - window.innerHeight) * \(p));")
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url,
               url.scheme == "https" || url.scheme == "http" {
                _ = await UIApplication.shared.open(url)
                return .cancel
            }
            return action.navigationType == .other ? .allow : .cancel
        }
    }
}
