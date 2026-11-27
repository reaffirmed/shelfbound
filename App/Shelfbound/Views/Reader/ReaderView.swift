import LibraryKit
import ShelfCore
import SwiftUI

/// Full-screen reader. Picks the text, paged or vertical reader from the work's reading
/// mode, and switches between them when the reader changes mode.
@MainActor
struct ReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ReaderRequest
    @State private var chapterID: String

    init(request: ReaderRequest) {
        self.request = request
        _chapterID = State(initialValue: request.chapterID)
    }

    var body: some View {
        Group {
            if let record = model.record(request.key), !record.readingOrder.isEmpty {
                switch model.readingMode(record) {
                case .text:
                    TextReaderScreen(key: request.key, chapterID: $chapterID)
                case .vertical:
                    VerticalReaderScreen(key: request.key, chapterID: $chapterID)
                case .pagedLeftToRight, .pagedRightToLeft:
                    PagedReaderScreen(key: request.key, chapterID: $chapterID)
                }
            } else {
                ContentUnavailableView {
                    Label("Nothing to read yet", systemImage: "book.closed")
                } actions: {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = model.settings.keepScreenAwake }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.saveNow()
        }
    }
}

// MARK: - Shared loading

enum ChapterPhase: Equatable {
    case loading
    case loaded(ChapterContent)
    case failed(String)
    case unhandledLink(URL)
    /// The site wants the person to pass a bot check in the browser first.
    case needsVerification(URL)
}

/// Where the reader is in the work's chapter list, and saving progress.
@MainActor
struct ReaderContext {
    let model: AppModel
    let key: WorkKey

    var record: WorkRecord? { model.record(key) }
    var chapters: [Chapter] { record?.readingOrder ?? [] }

    func index(of id: String) -> Int { chapters.firstIndex { $0.id == id } ?? 0 }
    func chapter(_ id: String) -> Chapter? { chapters.first { $0.id == id } }

    func neighbour(of id: String, _ delta: Int) -> Chapter? {
        let i = index(of: id) + delta
        return chapters.indices.contains(i) ? chapters[i] : nil
    }

    func load(_ chapterID: String) async -> ChapterPhase {
        do {
            let content = try await model.content(for: ChapterRef(work: key, chapterID: chapterID), chapter: chapter(chapterID))
            return .loaded(content)
        } catch let error as UnhandledLink {
            return .unhandledLink(error.url)
        } catch let error as BrowserVerificationNeeded {
            return .needsVerification(error.url)
        } catch {
            return .failed(error.readable)
        }
    }

    func save(_ chapterID: String, progress: Double, page: Int? = nil) {
        guard let chapter = chapter(chapterID) else { return }
        model.savePosition(ReadingPosition(chapterID: chapterID, chapterTitle: chapter.title, progress: progress, page: page), for: key)
        if progress >= 0.98, record?.isRead(chapterID) == false {
            model.markRead(chapterID, in: key)
        }
    }

    func savedProgress(_ chapterID: String) -> (progress: Double, page: Int?) {
        guard let position = model.currentPosition(for: key), position.chapterID == chapterID else { return (0, nil) }
        // Re-reading a finished chapter starts from the top.
        return position.progress >= 0.98 ? (0, nil) : (position.progress, position.page)
    }

    func isDownloaded(_ chapterID: String) -> Bool {
        model.downloads.isDownloaded(ChapterRef(work: key, chapterID: chapterID))
    }
}

/// Shown while a chapter loads, when it fails, or when it's a link no source reads.
@MainActor
struct ChapterStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let phase: ChapterPhase
    var dark = false
    let retry: () -> Void
    let useContent: (ChapterContent) -> Void
    @State private var extracting = false
    @State private var extractError: String?
    @State private var verifying: VerificationRequest?

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().controlSize(.large)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn't load chapter", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again", action: retry).buttonStyle(.borderedProminent)
                }
            case let .unhandledLink(url):
                ContentUnavailableView {
                    Label("This chapter is on \(url.host ?? "another site")", systemImage: "link")
                } description: {
                    Text(extractError ?? "No installed source reads that site. Reader mode pulls out the text and shows it with your settings.")
                } actions: {
                    Button(extracting ? "Loading..." : "Reader mode") {
                        Task {
                            extracting = true
                            defer { extracting = false }
                            do {
                                useContent(try await model.readerMode(url))
                            } catch {
                                if let request = error.verification { verifying = request }
                                extractError = error.readable
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(extracting)
                    Button("Open in browser") { openURL(url) }
                }
            case let .needsVerification(url):
                ContentUnavailableView {
                    Label("\(url.host ?? "This site") wants to check you're a person", systemImage: "checkmark.shield")
                } description: {
                    Text("Complete the check in the browser once, and this chapter loads. Shelfbound doesn't solve these checks for you.")
                } actions: {
                    Button("Verify in browser") { verifying = VerificationRequest(url: url) }
                        .buttonStyle(.borderedProminent)
                    Button("Try again", action: retry)
                }
            case .loaded:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, dark ? .dark : .light)
        .browserVerification($verifying)
        .onChange(of: model.verifiedCount) { _, _ in
            if case .needsVerification = phase { retry() } else if extractError != nil { extractError = nil }
        }
    }
}

/// Top bar shared by the readers: close, title and chapter, then trailing buttons.
@MainActor
struct ReaderTopBar<Trailing: View>: View {
    let title: String
    let subtitle: String
    let close: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close reader")
            VStack(spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Text

@MainActor
struct TextReaderScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: WorkKey
    @Binding var chapterID: String

    @State private var phase: ChapterPhase = .loading
    @State private var progress: Double = 0
    @State private var restore: Double = 0
    @State private var seek: Double?
    @State private var chrome = true
    @State private var words = 0
    @State private var showingStyle = false
    @State private var showingChapters = false
    @State private var glossaryEntry: GlossaryEntry?
    @State private var editingHighlight: Highlight?
    @State private var showingTranslation = false
    @State private var paragraphs: [String] = []
    @State private var translated: [String]?
    @State private var translationState: TranslationState = .idle
    @State private var showOriginal = false
    @State private var barsTouched = false
    @State private var htmlCache = ReaderHTMLCache()

    private var context: ReaderContext { ReaderContext(model: model, key: key) }

    private var isLoaded: Bool {
        if case .loaded = phase { return true }
        return false
    }

    var body: some View {
        let style = model.readerStyle(for: key)
        let colors = style.theme.colors
        ZStack {
            Color(hex: colors.background).ignoresSafeArea()
            if case let .loaded(content) = phase {
                TextWebView(
                    html: html(for: content), restoreProgress: restore, glossary: glossaryTerms,
                    highlights: context.record?.highlights(in: chapterID) ?? [],
                    wantsParagraphs: translateTarget != nil,
                    translation: translateTarget == nil || showOriginal ? nil : translated,
                    seek: $seek,
                    pullToAdvance: model.settings.autoAdvance && context.neighbour(of: chapterID, 1) != nil,
                    onProgress: { value in
                        progress = value
                        context.save(chapterID, progress: value)
                    },
                    onTap: {
                        barsTouched = true
                        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
                    },
                    onGlossaryTerm: { index in
                        if let entries = context.record?.glossary, entries.indices.contains(index) { glossaryEntry = entries[index] }
                    },
                    onHighlight: { selection, withNote in
                        let highlight = Highlight(
                            chapterID: chapterID, chapterTitle: context.chapter(chapterID)?.title ?? "",
                            exact: selection.exact, prefix: selection.prefix, suffix: selection.suffix)
                        model.addHighlight(highlight, to: key)
                        if withNote { editingHighlight = highlight }
                    },
                    onHighlightTap: { id in
                        editingHighlight = context.record?.highlights?.first { $0.id == id }
                    },
                    onParagraphs: { paragraphs = $0 },
                    onNext: { go(1) })
                .ignoresSafeArea(edges: .bottom)
            } else {
                ChapterStatusView(phase: phase, dark: style.theme.isDark, retry: { Task { await load() } }) { content in
                    phase = .loaded(content)
                    words = Self.wordCount(content)
                }
            }
        }
        .overlay(alignment: .top) { if chrome { topBar.transition(.move(edge: .top).combined(with: .opacity)) } }
        .overlay(alignment: .bottom) { if chrome { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) } }
        .environment(\.colorScheme, style.theme.isDark ? .dark : .light)
        .statusBarHidden(!chrome)
        .modifier(AutoHideBars(chrome: $chrome, touched: $barsTouched, ready: isLoaded))
        .task(id: chapterID) { await load() }
        .sheet(isPresented: $showingStyle) {
            ReaderStyleSheet(key: key).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingChapters) {
            ChapterListSheet(key: key, current: chapterID) { chapterID = $0 }
        }
        .sheet(item: $glossaryEntry) { entry in
            NavigationStack { GlossaryEditor(key: key, entry: entry) }.presentationDetents([.medium])
        }
        .modifier(ChapterTranslation(
            workID: key.id, chapterID: chapterID, paragraphs: translateTarget == nil ? [] : paragraphs,
            source: context.record?.settings.translateFrom, target: translateTarget,
            translated: $translated, state: $translationState))
        .overlay(alignment: .bottom) { translationBanner.padding(.bottom, chrome ? 150 : 24) }
        .sheet(isPresented: $showingTranslation) {
            NavigationStack { TranslationSettingsSheet(key: key) }.presentationDetents([.medium, .large])
        }
        .sheet(item: $editingHighlight) { highlight in
            NavigationStack { HighlightEditor(key: key, highlight: highlight) }.presentationDetents([.medium, .large])
        }
    }

    private var glossaryTerms: [String] { context.record?.glossary.map(\.term) ?? [] }

    private var translateTarget: String? {
        ChapterTranslation.isAvailable ? context.record?.settings.translateTo : nil
    }

    @ViewBuilder
    private var translationBanner: some View {
        if let target = translateTarget {
            Group {
                switch translationState {
                case .translating:
                    Label("Translating into \(TranslationSettingsSheet.name(target))", systemImage: "translate")
                case .done:
                    Button {
                        showOriginal.toggle()
                    } label: {
                        Label(showOriginal ? "Show translation" : "Translated on device · Show original", systemImage: "translate")
                    }
                case let .failed(message):
                    Button { showingTranslation = true } label: { Label(message, systemImage: "exclamationmark.triangle") }
                case .idle:
                    EmptyView()
                }
            }
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .opacity(chrome || translationState == .translating ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: chrome)
        }
    }

    /// The chapter's page, built once and kept until the chapter or its look changes.
    private func html(for content: ChapterContent) -> String {
        let next = context.neighbour(of: chapterID, 1)
        let cacheKey = ReaderHTMLCache.Key(
            chapterID: chapterID, content: content, style: model.readerStyle(for: key),
            skipNotes: context.record?.settings.skipNotes ?? false,
            title: context.chapter(chapterID)?.title ?? "", index: context.index(of: chapterID),
            nextTitle: next?.title, hasNext: next != nil)
        return htmlCache.html(for: cacheKey) { buildHTML(for: content) }
    }

    private func buildHTML(for content: ChapterContent) -> String {
        let chapter = context.chapter(chapterID)
        let index = context.index(of: chapterID)
        let next = context.neighbour(of: chapterID, 1)
        let skipNotes = context.record?.settings.skipNotes ?? false
        let end = ReaderDocument.EndOfChapter(
            message: next == nil ? "You're caught up. You'll get a badge when the next chapter is posted." : "End of chapter \(index + 1).",
            nextTitle: next?.title)
        switch content {
        case let .text(body, before, after):
            return ReaderDocument.html(
                title: chapter?.title ?? "", kicker: "Chapter \(index + 1)", body: body,
                notesBefore: skipNotes ? nil : before, notesAfter: skipNotes ? nil : after,
                style: model.readerStyle(for: key), end: end)
        case let .images(pages):
            // A text source returned pictures: show them inline.
            let body = pages.map { "<p><img src=\"\(ReaderDocument.escape($0.url.absoluteString))\"></p>" }.joined()
            return ReaderDocument.html(title: chapter?.title ?? "", body: body, style: model.readerStyle(for: key), end: end)
        case let .link(url):
            return ReaderDocument.html(title: chapter?.title ?? "", body: "<p>This chapter is at <a href=\"\(ReaderDocument.escape(url.absoluteString))\">\(ReaderDocument.escape(url.host ?? "another site"))</a>.</p>", style: model.readerStyle(for: key), end: end)
        }
    }

    private func load() async {
        phase = .loading
        paragraphs = []
        translated = nil
        showOriginal = false
        let loading = chapterID
        let saved = context.savedProgress(loading)
        restore = saved.progress
        progress = saved.progress
        let result = await context.load(loading)
        // Source calls don't stop when the task is cancelled. If the person moved to another
        // chapter while this one loaded, its content and position belong to that chapter's load.
        guard !Task.isCancelled, loading == chapterID else { return }
        if case let .loaded(content) = result { words = Self.wordCount(content) }
        phase = result
        context.save(loading, progress: saved.progress)
    }

    private func go(_ delta: Int) {
        guard let next = context.neighbour(of: chapterID, delta) else { return }
        if delta > 0 { context.save(chapterID, progress: 1) }
        Haptics.light()
        chapterID = next.id
    }

    static func wordCount(_ content: ChapterContent) -> Int {
        guard case let .text(html, _, _) = content else { return 0 }
        return html.strippingHTML.split(whereSeparator: { $0.isWhitespace }).count
    }

    private var topBar: some View {
        let chapter = context.chapter(chapterID)
        return ReaderTopBar(
            title: context.record?.title ?? "",
            subtitle: ChapterLabel.subtitle(number: context.index(of: chapterID) + 1, title: chapter?.title),
            close: { dismiss() }
        ) {
            Button { showingChapters = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                .accessibilityLabel("Chapters")
            if ChapterTranslation.isAvailable {
                Button { showingTranslation = true } label: {
                    Image(systemName: translateTarget == nil ? "translate" : "character.bubble.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Translate")
            }
            Button { showingStyle = true } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }
                .accessibilityLabel("Text and theme")
        }
    }

    private var bottomBar: some View {
        let index = context.index(of: chapterID)
        let count = context.chapters.count
        let minutes = Int((Double(words) * (1 - progress) / 230).rounded(.up))
        return VStack(spacing: 6) {
            HStack {
                Text("\(Int(progress * 100))%")
                Spacer()
                Text(minutes <= 1 ? "Less than a minute left" : "\(minutes) min left in chapter")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Slider(value: Binding(get: { progress }, set: { progress = $0; seek = $0 }), in: 0...1)
                .accessibilityLabel("Position in chapter")
            ChapterStepper(index: index, count: count) { go($0) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Paged

@MainActor
struct PagedReaderScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: WorkKey
    @Binding var chapterID: String

    @State private var phase: ChapterPhase = .loading
    @State private var page = 0
    @State private var startPage = 0
    @State private var chrome = true
    @State private var showHint = true
    @State private var showingChapters = false
    @State private var startAtEnd = false
    @State private var prefetched: Set<String> = []
    @State private var barsTouched = false
    @State private var showingTint = false
    /// How many times the page-turn hint has been shown; after a few, it stays away.
    @AppStorage("reader.pagedHintShown") private var hintShown = 0

    private var isLoaded: Bool {
        if case .loaded = phase { return true }
        return false
    }

    private var context: ReaderContext { ReaderContext(model: model, key: key) }
    private var rightToLeft: Bool { context.record.map { model.readingMode($0) } != .pagedLeftToRight }
    private var panelByPanel: Bool { context.record?.settings.panelByPanel ?? false }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if case let .loaded(.images(pages)) = phase {
                PagedImageReader(
                    chapterID: chapterID, pages: pages, startPage: startPage, rightToLeft: rightToLeft,
                    panelByPanel: panelByPanel,
                    spread: context.record?.settings.twoPageSpread ?? true,
                    coverAlone: context.record?.settings.spreadCoverAlone ?? true,
                    endTitle: "End of \(context.chapter(chapterID)?.title ?? "chapter")",
                    nextTitle: context.neighbour(of: chapterID, 1)?.title,
                    page: $page,
                    onTapCenter: {
                        barsTouched = true
                        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
                    },
                    onNextChapter: { go(1) },
                    onPreviousChapter: { go(-1, atEnd: true) })
                .ignoresSafeArea()
                .onChange(of: page) { _, value in pageChanged(value, of: pages.count) }
            } else if case .loaded = phase {
                ChapterStatusView(phase: .failed("This chapter has text, not pages. Switch the work to the text reader from its page."), dark: true, retry: {}, useContent: { _ in })
            } else {
                ChapterStatusView(phase: phase, dark: true, retry: { Task { await load() } }) { phase = .loaded($0) }
            }
            PageTint()
            if showHint, hintShown < 3, case .loaded = phase {
                Text(rightToLeft ? "Tap the left side for the next page (right to left)" : "Tap the right side for the next page")
                    .font(.footnote).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation { showHint = false }
                        hintShown += 1
                    }
            }
        }
        .overlay(alignment: .top) { if chrome { topBar.transition(.opacity) } }
        .overlay(alignment: .bottom) { if chrome { bottomBar.transition(.opacity) } }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!chrome)
        .modifier(AutoHideBars(chrome: $chrome, touched: $barsTouched, ready: isLoaded))
        .task(id: chapterID) { await load() }
        .sheet(isPresented: $showingChapters) {
            ChapterListSheet(key: key, current: chapterID) { chapterID = $0 }
        }
        .sheet(isPresented: $showingTint) { PageTintSheet() }
    }

    private var pageCount: Int {
        if case let .loaded(.images(pages)) = phase { return pages.count }
        return 0
    }

    private func load() async {
        phase = .loading
        let loading = chapterID
        let saved = context.savedProgress(loading)
        let result = await context.load(loading)
        // A late result for a chapter the person already left must not replace the new one.
        guard !Task.isCancelled, loading == chapterID else { return }
        if case let .loaded(.images(pages)) = result {
            let start = startAtEnd ? max(0, pages.count - 1) : min(saved.page ?? 0, max(0, pages.count - 1))
            startPage = start
            page = start
        }
        startAtEnd = false
        phase = result
        if case let .loaded(.images(pages)) = result { pageChanged(page, of: pages.count) }
    }

    private func pageChanged(_ value: Int, of count: Int) {
        guard count > 0 else { return }
        let current = min(value, count - 1)
        context.save(chapterID, progress: Double(current + 1) / Double(count), page: current)
        // Warm up the next chapter's first pages near the end.
        if value >= count - 3, let next = context.neighbour(of: chapterID, 1), !prefetched.contains(next.id) {
            prefetched.insert(next.id)
            Task {
                if case let .loaded(.images(pages)) = await context.load(next.id) {
                    ImageLoader.shared.prefetch(Array(pages.prefix(3)), width: ZoomingPageController.decodeWidth(UIScreen.main.bounds.width))
                }
            }
        }
    }

    private func go(_ delta: Int, atEnd: Bool = false) {
        guard let next = context.neighbour(of: chapterID, delta) else { return }
        if delta > 0 { context.save(chapterID, progress: 1, page: max(0, pageCount - 1)) }
        Haptics.light()
        startAtEnd = atEnd
        chapterID = next.id
    }

    private var topBar: some View {
        ReaderTopBar(
            title: context.record?.title ?? "",
            subtitle: ChapterLabel.subtitle(number: context.index(of: chapterID) + 1, title: context.chapter(chapterID)?.title),
            close: { dismiss() }
        ) {
            Button {
                let on = !panelByPanel
                model.updateRecord(key) { $0.settings.panelByPanel = on }
            } label: {
                Image(systemName: panelByPanel ? "rectangle.split.2x2.fill" : "rectangle.split.2x2").frame(width: 44, height: 44)
            }
            .accessibilityLabel(panelByPanel ? "Show whole pages" : "Read panel by panel")
            Button { showingChapters = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                .accessibilityLabel("Chapters")
            ReadingModeMenu(key: key, showingTint: $showingTint)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text(page >= pageCount ? "End of chapter" : "Page \(page + 1) of \(pageCount)")
                Spacer()
                if context.isDownloaded(chapterID) { Label("Downloaded", systemImage: "arrow.down.circle.fill") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if pageCount > 1 {
                Slider(
                    value: Binding(get: { Double(min(page, pageCount - 1)) }, set: { page = Int($0.rounded()) }),
                    in: 0...Double(pageCount - 1), step: 1)
                .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                .accessibilityLabel("Page")
            }
            ChapterStepper(index: context.index(of: chapterID), count: context.chapters.count) { go($0) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Vertical

@MainActor
struct VerticalReaderScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: WorkKey
    @Binding var chapterID: String

    @State private var strip: [StripChapter] = []
    @State private var start: (chapterID: String, progress: Double) = ("", 0)
    @State private var phase: ChapterPhase = .loading
    @State private var progress: Double = 0
    @State private var loadingNext = false
    @State private var loadingPrevious = false
    /// The chapter before the strip couldn't be added; it isn't tried again until the strip starts over.
    @State private var previousUnavailable = false
    /// Why the next chapter couldn't be added to the strip. Loading it isn't tried again
    /// until the person asks, or passes the site's check.
    @State private var nextFailure: ChapterPhase?
    @State private var verifying: VerificationRequest?
    @State private var seek: Double?
    @State private var chrome = true
    @State private var barsTouched = false
    @State private var showingChapters = false
    @State private var visibleChapter = ""
    /// Auto-scroll stopped by a tap. The speed stays chosen, so it can pick up again.
    @State private var autoScrollPaused = false
    @State private var showingTint = false

    private var context: ReaderContext { ReaderContext(model: model, key: key) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !strip.isEmpty {
                VerticalImageReader(
                    chapters: strip, start: start, seek: $seek,
                    autoScrollSpeed: autoScrollPaused ? 0 : model.autoScrollSpeed(for: key),
                    moreAfterLast: strip.last.flatMap { context.neighbour(of: $0.id, 1) } != nil,
                    nextFailed: nextFailure != nil,
                    onPosition: { id, value in positionChanged(id, value) },
                    onNearEnd: { Task { await appendNext() } },
                    onNearStart: { Task { await prependPrevious() } },
                    onTap: {
                        barsTouched = true
                        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
                    },
                    onAutoScrollStopped: {
                        // A tap while auto-scrolling pauses it and brings up the bars, where it resumes.
                        barsTouched = true
                        autoScrollPaused = true
                        withAnimation(.easeInOut(duration: 0.2)) { chrome = true }
                    })
                .ignoresSafeArea()
            } else {
                ChapterStatusView(phase: phase, dark: true, retry: { Task { await restart() } }) { content in
                    if case let .images(pages) = content { startStrip(with: pages) }
                }
            }
            PageTint()
        }
        .overlay(alignment: .top) { if chrome { topBar.transition(.opacity) } }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                nextFailureBanner
                if chrome { bottomBar.transition(.opacity) }
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!chrome)
        .modifier(AutoHideBars(chrome: $chrome, touched: $barsTouched, ready: !strip.isEmpty))
        .task { await restart() }
        .onChange(of: chapterID) { _, id in
            // Picked from the chapter list (not from scrolling): start over there.
            if id != visibleChapter { Task { await restart() } }
        }
        .onChange(of: model.verifiedCount) { _, _ in
            if nextFailure != nil { retryNext() }
        }
        .browserVerification($verifying)
        .sheet(isPresented: $showingChapters) {
            ChapterListSheet(key: key, current: chapterID) { chapterID = $0 }
        }
        .sheet(isPresented: $showingTint) { PageTintSheet() }
    }

    private func restart() async {
        strip = []
        phase = .loading
        nextFailure = nil
        previousUnavailable = false
        let loading = chapterID
        let result = await context.load(loading)
        // Picking two chapters quickly starts two restarts; only the newest one's result counts.
        guard loading == chapterID else { return }
        switch result {
        case let .loaded(.images(pages)):
            startStrip(with: pages)
        case .loaded:
            phase = .failed("This chapter has text, not pages. Switch the work to the text reader from its page.")
        default:
            phase = result
        }
    }

    private func startStrip(with pages: [ImagePage]) {
        let saved = context.savedProgress(chapterID)
        visibleChapter = chapterID
        start = (chapterID, saved.progress)
        progress = saved.progress
        strip = [StripChapter(id: chapterID, title: context.chapter(chapterID)?.title ?? "", pages: pages)]
        phase = .loading
    }

    private func appendNext() async {
        guard !loadingNext, nextFailure == nil, let last = strip.last,
              let next = context.neighbour(of: last.id, 1) else { return }
        loadingNext = true
        defer { loadingNext = false }
        let result = await context.load(next.id)
        // The strip may have been started over at another chapter while this loaded.
        guard strip.last?.id == last.id else { return }
        switch result {
        case let .loaded(.images(pages)):
            strip.append(StripChapter(id: next.id, title: next.title, pages: pages))
        case .loaded:
            nextFailure = .failed("It has text, not pages.")
        default:
            nextFailure = result
        }
    }

    /// Scrolling up past the top of the strip continues into the chapter before, the same
    /// way scrolling down continues into the next.
    private func prependPrevious() async {
        guard !loadingPrevious, !previousUnavailable, let first = strip.first,
              let previous = context.neighbour(of: first.id, -1) else { return }
        loadingPrevious = true
        defer { loadingPrevious = false }
        let result = await context.load(previous.id)
        // The strip may have been started over at another chapter while this loaded.
        guard strip.first?.id == first.id else { return }
        if case let .loaded(.images(pages)) = result, !pages.isEmpty {
            strip.insert(StripChapter(id: previous.id, title: previous.title, pages: pages), at: 0)
        } else {
            previousUnavailable = true
        }
    }

    private func retryNext() {
        nextFailure = nil
        Task { await appendNext() }
    }

    /// Shown over the end of the strip when the next chapter couldn't be loaded, so the
    /// reader isn't left at "Loading the next chapter…" with no way on.
    @ViewBuilder
    private var nextFailureBanner: some View {
        if let nextFailure {
            HStack(spacing: 12) {
                Text(nextFailureText(nextFailure))
                    .font(.footnote).foregroundStyle(.white).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case let .needsVerification(url) = nextFailure {
                    Button("Verify") { verifying = VerificationRequest(url: url) }
                }
                Button("Try again") { retryNext() }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.15)))
            .padding(.horizontal, 16)
            .padding(.bottom, chrome ? 0 : 28)
        }
    }

    private func nextFailureText(_ failure: ChapterPhase) -> String {
        switch failure {
        case let .failed(message): return "Couldn't load the next chapter. \(message)"
        case let .needsVerification(url): return "\(url.host ?? "The site") wants a browser check before the next chapter."
        case let .unhandledLink(url): return "The next chapter is on \(url.host ?? "another site")."
        default: return "Couldn't load the next chapter."
        }
    }

    private func positionChanged(_ id: String, _ value: Double) {
        if id != visibleChapter {
            // Scrolled into the next chapter: the one before is done.
            if context.index(of: id) > context.index(of: visibleChapter) {
                context.save(visibleChapter, progress: 1)
                Haptics.light()
            }
            visibleChapter = id
            chapterID = id
        }
        progress = value
        context.save(id, progress: value)
    }

    /// The previous or next chapter from the bottom bar: the strip starts over there.
    private func go(_ delta: Int) {
        guard let next = context.neighbour(of: chapterID, delta) else { return }
        if delta > 0 { context.save(chapterID, progress: 1) }
        Haptics.light()
        chapterID = next.id
    }

    private var topBar: some View {
        @Bindable var model = model
        let speed = model.autoScrollSpeed(for: key)
        return ReaderTopBar(
            title: context.record?.title ?? "",
            subtitle: ChapterLabel.subtitle(number: context.index(of: chapterID) + 1, title: context.chapter(chapterID)?.title),
            close: { dismiss() }
        ) {
            if speed > 0 {
                Button { autoScrollPaused.toggle() } label: {
                    Image(systemName: autoScrollPaused ? "play.fill" : "pause.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel(autoScrollPaused ? "Resume auto-scroll" : "Pause auto-scroll")
            }
            Button { showingChapters = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                .accessibilityLabel("Chapters")
            Menu {
                // Remembered per series: a slow-paced strip and a fast one want different speeds.
                Picker("Auto-scroll", selection: Binding(
                    get: { model.autoScrollSpeed(for: key) },
                    set: { speed in
                        model.updateRecord(key) { $0.settings.autoScrollSpeed = speed }
                        model.settings.autoScrollSpeed = speed
                        autoScrollPaused = false
                    }
                )) {
                    Text("Auto-scroll off").tag(0.0)
                    Text("Slow").tag(40.0)
                    Text("Medium").tag(90.0)
                    Text("Fast").tag(160.0)
                }
                ReadingModePicker(key: key)
                Button { showingTint = true } label: { Label("Dim and warmth", systemImage: "moon") }
            } label: {
                Image(systemName: speed > 0 ? "play.circle.fill" : "slider.horizontal.3").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Auto-scroll and reading mode")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(Int(progress * 100))% of chapter")
                Spacer()
                if context.isDownloaded(chapterID) {
                    Label("Downloaded", systemImage: "arrow.down.circle.fill")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Slider(value: Binding(get: { progress }, set: { progress = $0; seek = $0 }), in: 0...1)
                .accessibilityLabel("Position in chapter")
            ChapterStepper(index: context.index(of: chapterID), count: context.chapters.count) { go($0) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
    }
}

/// Right to left / Left to right / Vertical, saved per work. Lives inside a menu: it's
/// set once per series, so it doesn't take a row of the reader's bottom bar.
@MainActor
struct ReadingModePicker: View {
    @Environment(AppModel.self) private var model
    let key: WorkKey

    var body: some View {
        Picker("Reading mode", selection: Binding(
            get: { model.record(key).map { model.readingMode($0) } ?? .pagedRightToLeft },
            set: { mode in model.updateRecord(key) { $0.settings.readingMode = mode } }
        )) {
            ForEach([ReadingMode.pagedRightToLeft, .pagedLeftToRight, .vertical]) { Text($0.label).tag($0) }
        }
    }
}

/// The paged reader's top bar button: reading mode, two-page spreads, and dimming.
@MainActor
struct ReadingModeMenu: View {
    @Environment(AppModel.self) private var model
    let key: WorkKey
    @Binding var showingTint: Bool

    var body: some View {
        let settings = model.record(key)?.settings
        let spread = settings?.twoPageSpread ?? true
        Menu {
            ReadingModePicker(key: key)
            Section("When the screen is turned sideways") {
                Toggle(isOn: Binding(
                    get: { spread },
                    set: { on in model.updateRecord(key) { $0.settings.twoPageSpread = on } }
                )) {
                    Label("Two pages side by side", systemImage: "book")
                }
                if spread {
                    // Off shifts every pair by one page, for when the two halves of a spread don't line up.
                    Toggle(isOn: Binding(
                        get: { settings?.spreadCoverAlone ?? true },
                        set: { on in model.updateRecord(key) { $0.settings.spreadCoverAlone = on } }
                    )) {
                        Label("First page on its own", systemImage: "rectangle.portrait")
                    }
                }
            }
            Button { showingTint = true } label: { Label("Dim and warmth", systemImage: "moon") }
        } label: {
            Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Reading mode and display")
    }
}

/// Darkens and warms the pages of the image readers, for reading at night. It sits over
/// the pages and under the reader's bars, and lets every touch through.
@MainActor
struct PageTint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let warmth = model.settings.pageWarmth
        let dim = model.settings.pageDim
        ZStack {
            if warmth > 0 {
                // Multiplied in, so white turns amber and black stays black.
                Color(red: 1, green: 0.6, blue: 0.22).opacity(warmth).blendMode(.multiply)
            }
            if dim > 0 { Color.black.opacity(dim) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The two sliders for `PageTint`. Short, and without the usual grey over what's behind
/// it, so the pages show the change as the sliders move.
@MainActor
struct PageTintSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Dim") {
                        Slider(value: $model.settings.pageDim, in: 0...AppSettings.maxPageTint)
                            .accessibilityLabel("Dim")
                    }
                    LabeledContent("Warmth") {
                        Slider(value: $model.settings.pageWarmth, in: 0...AppSettings.maxPageTint)
                            .accessibilityLabel("Warmth")
                    }
                } footer: {
                    Text("For reading in the dark. It applies to manga and manhwa pages in every work.")
                }
                if model.settings.pageDim > 0 || model.settings.pageWarmth > 0 {
                    Button("Turn off") {
                        model.settings.pageDim = 0
                        model.settings.pageWarmth = 0
                    }
                }
            }
            .navigationTitle("Dim and warmth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.height(320)])
        .presentationBackgroundInteraction(.enabled(upThrough: .height(320)))
    }
}

/// Previous chapter, "3 of 40", next chapter: the last row of every reader's bottom bar.
@MainActor
struct ChapterStepper: View {
    /// The current chapter's place in reading order, from 0.
    let index: Int
    let count: Int
    let go: (Int) -> Void

    var body: some View {
        HStack {
            Button { go(-1) } label: { Label { Text(verbatim: "Ch. \(index)") } icon: { Image(systemName: "chevron.left") } }
                .disabled(index == 0)
                .accessibilityLabel("Previous chapter")
            Spacer()
            Text(verbatim: "\(index + 1) of \(count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { go(1) } label: {
                HStack(spacing: 4) { Text(verbatim: "Ch. \(index + 2)"); Image(systemName: "chevron.right") }
            }
            .disabled(index >= count - 1)
            .accessibilityLabel("Next chapter")
        }
        .font(.subheadline)
        .labelStyle(.titleAndIcon)
    }
}

/// Hides the reader's bars a moment after the first chapter shows, so the page isn't
/// covered until a tap. Only once per reading session, and not if the person has already
/// tapped, or uses VoiceOver (which needs the bars to stay findable).
struct AutoHideBars: ViewModifier {
    @Binding var chrome: Bool
    @Binding var touched: Bool
    let ready: Bool
    @State private var done = false

    func body(content: Content) -> some View {
        content.task(id: ready) {
            guard ready, !done else { return }
            done = true
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, chrome, !touched, !UIAccessibility.isVoiceOverRunning else { return }
            withAnimation(.easeInOut(duration: 0.2)) { chrome = false }
        }
    }
}

/// Short taps of feedback for things that just happened.
@MainActor
enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

/// Keeps the text reader's page between redraws. Scrolling reports progress many times a
/// second and each report redraws the reader; building a long chapter's page again every
/// time (and comparing it with the one loaded) is what made long fics stutter.
@MainActor
final class ReaderHTMLCache {
    struct Key: Equatable {
        var chapterID: String
        var content: ChapterContent
        var style: ReaderStyle
        var skipNotes: Bool
        var title: String
        var index: Int
        var nextTitle: String?
        var hasNext: Bool
    }

    private var key: Key?
    private var html = ""

    func html(for key: Key, build: () -> String) -> String {
        if self.key == key { return html }
        html = build()
        self.key = key
        return html
    }
}

// MARK: - Sheets

@MainActor
struct ChapterListSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: WorkKey
    let current: String
    let pick: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let record = model.record(key) {
                        ForEach(Array(record.readingOrder.enumerated()), id: \.element.id) { index, chapter in
                            Button {
                                pick(chapter.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(verbatim: String(index + 1)).monospacedDigit().foregroundStyle(.secondary)
                                        .lineLimit(1).fixedSize().frame(minWidth: 36, alignment: .trailing)
                                    Text(chapter.title).foregroundStyle(record.isRead(chapter.id) ? Color.secondary : Color.primary)
                                    Spacer()
                                    if chapter.id == current { Image(systemName: "bookmark.fill").foregroundStyle(Color.shelfAccent) }
                                    if model.downloads.isDownloaded(ChapterRef(work: key, chapterID: chapter.id)) {
                                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .id(chapter.id)
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Text & theme, as in the mockup: four themes, size, font, spacing, justify.
@MainActor
struct ReaderStyleSheet: View {
    @Environment(AppModel.self) private var model
    /// From the reader: the work being read, which can have a style of its own.
    var key: WorkKey? = nil

    private var style: Binding<ReaderStyle> {
        Binding(get: { model.readerStyle(for: key) }, set: { model.setReaderStyle($0, for: key) })
    }

    private var ownStyle: Binding<Bool>? {
        guard let key, model.record(key) != nil else { return nil }
        return Binding(
            get: { model.record(key)?.settings.readerStyle != nil },
            set: { on in
                let current = model.readerStyle(for: key)
                model.updateRecord(key) { $0.settings.readerStyle = on ? current : nil }
            })
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                if let ownStyle {
                    Section {
                        Toggle("Only for this work", isOn: ownStyle)
                    } footer: {
                        Text(ownStyle.wrappedValue
                             ? "Changes here apply to this work only. Turn off to go back to your usual style."
                             : "Changes here apply to every fic and novel. Turn on to give this work its own look.")
                    }
                }
                Section {
                    HStack(spacing: 10) {
                        ForEach(ReaderTheme.allCases) { theme in
                            let c = theme.colors
                            Button {
                                style.wrappedValue.theme = theme
                            } label: {
                                VStack(spacing: 6) {
                                    Text("Aa")
                                        .font(.system(size: 20, design: .serif))
                                        .foregroundStyle(Color(hex: c.text))
                                        .frame(maxWidth: .infinity, minHeight: 52)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: c.background)))
                                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                                            style.wrappedValue.theme == theme ? Color.shelfAccent : Color(.separator),
                                            lineWidth: style.wrappedValue.theme == theme ? 2.5 : 1))
                                    Text(theme.label).font(.caption).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(style.wrappedValue.theme == theme ? .isSelected : [])
                        }
                    }
                }
                Section {
                    Stepper("Size \(Int(style.wrappedValue.fontSize)) pt", value: style.fontSize, in: 14...30, step: 1)
                    Picker("Font", selection: style.font) {
                        ForEach(ReaderFont.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Line spacing", selection: style.lineSpacing) {
                        ForEach(LineSpacing.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper("Margins \(Int(style.wrappedValue.margin))", value: style.margin, in: 8...48, step: 4)
                    Toggle("Justify text", isOn: style.justify)
                }
                Section {
                    Toggle("Pull up for the next chapter", isOn: $model.settings.autoAdvance)
                }
            }
            .navigationTitle("Text & theme")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The reader header's "Chapter N · Title" line, leaving out a title that only
/// repeats the number ("Chapter 1075", "Ch. 1075", "1075") or is empty.
enum ChapterLabel {
    static func subtitle(number: Int, title: String?) -> String {
        let label = "Chapter \(number)"
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              !repeatsNumber(title, number) else { return label }
        return "\(label) · \(title)"
    }

    static func repeatsNumber(_ title: String, _ number: Int) -> Bool {
        var rest = Substring(title.lowercased())
        for prefix in ["chapter", "chap.", "chap", "ch."] where rest.hasPrefix(prefix) {
            rest = rest.dropFirst(prefix.count)
            break
        }
        let digits = rest.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "#:.")))
        return Int(digits) == number
    }
}
