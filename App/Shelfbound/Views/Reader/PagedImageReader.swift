import ShelfCore
import SwiftUI
import UIKit

/// Paged manga reader: one page per screen (or two side by side when the screen is wider
/// than tall), right to left or left to right, with pinch and double-tap zoom, tap zones,
/// and an end-of-chapter card after the last page.
@MainActor
struct PagedImageReader: UIViewControllerRepresentable {
    let chapterID: String
    let pages: [ImagePage]
    let startPage: Int
    let rightToLeft: Bool
    var panelByPanel = false
    /// Two pages side by side when the screen is wider than tall.
    var spread = true
    /// In a spread, the first page stands alone, as a cover does.
    var coverAlone = true
    let endTitle: String
    let nextTitle: String?
    @Binding var page: Int
    var onTapCenter: () -> Void
    var onNextChapter: () -> Void
    var onPreviousChapter: () -> Void

    func makeUIViewController(context: Context) -> PagedImageReaderController {
        let controller = PagedImageReaderController()
        controller.callbacks = callbacks(context)
        controller.panelByPanel = panelByPanel
        controller.setSpread(allowed: spread, coverAlone: coverAlone)
        controller.load(chapterID: chapterID, pages: pages, start: startPage, rightToLeft: rightToLeft, endTitle: endTitle, nextTitle: nextTitle)
        return controller
    }

    func updateUIViewController(_ controller: PagedImageReaderController, context: Context) {
        controller.callbacks = callbacks(context)
        if controller.chapterID != chapterID {
            controller.setSpread(allowed: spread, coverAlone: coverAlone)
            controller.load(chapterID: chapterID, pages: pages, start: startPage, rightToLeft: rightToLeft, endTitle: endTitle, nextTitle: nextTitle)
        } else {
            controller.setRightToLeft(rightToLeft)
            controller.setPanelByPanel(panelByPanel)
            controller.setSpread(allowed: spread, coverAlone: coverAlone)
            controller.updateEnd(title: endTitle, next: nextTitle)
            if controller.currentIndex != page { controller.go(to: page, animated: false) }
        }
    }

    private func callbacks(_ context: Context) -> PagedImageReaderController.Callbacks {
        .init(
            pageChanged: { index in if page != index { page = index } },
            tapCenter: onTapCenter,
            nextChapter: onNextChapter,
            previousChapter: onPreviousChapter)
    }
}

final class PagedImageReaderController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    struct Callbacks {
        var pageChanged: (Int) -> Void = { _ in }
        var tapCenter: () -> Void = {}
        var nextChapter: () -> Void = {}
        var previousChapter: () -> Void = {}
    }

    var callbacks = Callbacks()
    private(set) var chapterID = ""
    /// The page the reader is on, counting from 0; `pages.count` is the end-of-chapter card.
    /// With two pages on screen it's the later one, so finishing the pair counts both as read.
    private(set) var currentIndex = 0
    private var pages: [ImagePage] = []
    /// What each swipe shows: one page, or two side by side. The last is the end card.
    private var screens: [[Int]] = []
    private var currentScreen = 0
    private var spreadAllowed = true
    private var coverAlone = true
    /// Whether pages are paired right now (allowed, and the screen is wider than tall).
    private var spreadActive = false
    private var rightToLeft = true
    /// Zoom from panel to panel; taps move between panels before pages.
    var panelByPanel = false
    /// Set while stepping back a page, so that page opens on its last panel.
    private var enteringBackward = false
    private var endTitle = ""
    private var nextTitle: String?
    private let pageController = UIPageViewController(
        transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 12])

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        pageController.dataSource = self
        pageController.delegate = self
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Turning the device switches between one page and two.
        if wantsSpread != spreadActive { rebuildScreens() }
    }

    func load(chapterID: String, pages: [ImagePage], start: Int, rightToLeft: Bool, endTitle: String, nextTitle: String?) {
        loadViewIfNeeded()
        self.chapterID = chapterID
        self.pages = pages
        self.rightToLeft = rightToLeft
        self.endTitle = endTitle
        self.nextTitle = nextTitle
        currentIndex = min(max(0, start), pages.count)
        rebuildScreens()
        prefetch(around: currentIndex)
    }

    func setRightToLeft(_ value: Bool) {
        guard value != rightToLeft else { return }
        rightToLeft = value
        // Rebuild so swipe directions match.
        showCurrentScreen()
    }

    // MARK: Screens

    private var wantsSpread: Bool {
        spreadAllowed && !panelByPanel && view.bounds.width > view.bounds.height && view.bounds.width >= 560
    }

    func setSpread(allowed: Bool, coverAlone: Bool) {
        guard allowed != spreadAllowed || coverAlone != self.coverAlone else { return }
        spreadAllowed = allowed
        self.coverAlone = coverAlone
        if isViewLoaded, !chapterID.isEmpty { rebuildScreens() }
    }

    /// A page wider than tall is a double-page scan already, so it gets a screen to itself.
    /// Only known for pages loaded before; the others are taken to be ordinary pages.
    private func isWide(_ index: Int) -> Bool {
        (ImageLoader.shared.knownAspect(pages[index].url) ?? 1.4) < 1
    }

    /// Works out what each screen shows and puts the reader back on the page it was on.
    private func rebuildScreens() {
        spreadActive = wantsSpread
        var out: [[Int]] = []
        if spreadActive {
            var i = 0
            if coverAlone, !pages.isEmpty {
                out.append([0])
                i = 1
            }
            while i < pages.count {
                if i + 1 < pages.count, !isWide(i), !isWide(i + 1) {
                    out.append([i, i + 1])
                    i += 2
                } else {
                    out.append([i])
                    i += 1
                }
            }
        } else {
            out = pages.indices.map { [$0] }
        }
        out.append([pages.count])
        screens = out
        currentScreen = screen(holding: currentIndex)
        showCurrentScreen()
    }

    private func screen(holding index: Int) -> Int {
        screens.firstIndex { $0.contains(index) } ?? max(0, screens.count - 1)
    }

    private func showCurrentScreen() {
        if let vc = controller(at: currentScreen) {
            pageController.setViewControllers([vc], direction: .forward, animated: false)
        }
    }

    // MARK: Keyboard (iPad keyboards and the Mac)

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        let next = UIKeyCommand(title: "Next Page", action: #selector(keyNext), input: " ")
        let left = UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keyLeft))
        let right = UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keyRight))
        let down = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(keyNext))
        let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(keyPrevious))
        for command in [left, right, down, up] { command.wantsPriorityOverSystemBehavior = true }
        return [next, left, right, down, up]
    }

    /// The arrow that points the way the pages go moves forward.
    @objc private func keyLeft() { keyStep(rightToLeft ? 1 : -1) }
    @objc private func keyRight() { keyStep(rightToLeft ? -1 : 1) }
    @objc private func keyNext() { keyStep(1) }
    @objc private func keyPrevious() { keyStep(-1) }

    private func keyStep(_ delta: Int) {
        if panelByPanel, let page = pageController.viewControllers?.first as? ZoomingPageController, page.stepPanel(delta) { return }
        step(delta)
    }

    func setPanelByPanel(_ value: Bool) {
        guard value != panelByPanel else { return }
        panelByPanel = value
        if wantsSpread != spreadActive {
            // Panel by panel reads one page at a time.
            rebuildScreens()
        } else {
            (pageController.viewControllers?.first as? ZoomingPageController)?.setGuided(value, rightToLeft: rightToLeft)
        }
    }

    func updateEnd(title: String, next: String?) {
        guard title != endTitle || next != nextTitle else { return }
        endTitle = title
        nextTitle = next
        if currentScreen == screens.count - 1 { showCurrentScreen() }
    }

    /// Jumps to a page (from the slider, or where the reader left off).
    func go(to index: Int, animated: Bool) {
        let target = min(max(0, index), pages.count)
        let wanted = screen(holding: target)
        guard wanted != currentScreen else {
            // The other page of the pair already on screen.
            currentIndex = target
            return
        }
        show(screen: wanted, reporting: target, animated: animated)
    }

    private func show(screen wanted: Int, reporting index: Int, animated: Bool) {
        guard let vc = controller(at: wanted) else { return }
        let forward = wanted > currentScreen
        let direction: UIPageViewController.NavigationDirection = (forward != rightToLeft) ? .forward : .reverse
        currentScreen = wanted
        currentIndex = index
        pageController.setViewControllers([vc], direction: direction, animated: animated)
        prefetch(around: index)
        callbacks.pageChanged(index)
    }

    /// Next/previous screen in reading order, or the next/previous chapter at the edges.
    func step(_ delta: Int) {
        let target = currentScreen + delta
        if target >= screens.count {
            callbacks.nextChapter()
        } else if target < 0 {
            callbacks.previousChapter()
        } else {
            enteringBackward = delta < 0
            show(screen: target, reporting: screens[target].last ?? 0, animated: true)
            enteringBackward = false
        }
    }

    // The last screen is the end-of-chapter card.
    private func controller(at screen: Int) -> UIViewController? {
        guard screens.indices.contains(screen) else { return nil }
        let indices = screens[screen]
        if indices.first == pages.count {
            let end = EndCardController(title: endTitle, nextTitle: nextTitle)
            end.screen = screen
            end.onNext = { [weak self] in self?.callbacks.nextChapter() }
            end.onTap = { [weak self] point, width in self?.handleTap(point, width: width) }
            return end
        }
        let page = ZoomingPageController(pages: indices.map { pages[$0] }, firstNumber: (indices.first ?? 0) + 1)
        page.screen = screen
        page.guided = panelByPanel && indices.count == 1
        page.rightToLeft = rightToLeft
        page.startAtLastPanel = enteringBackward
        page.onTap = { [weak self] point, width in self?.handleTap(point, width: width) }
        return page
    }

    private func handleTap(_ point: CGPoint, width: CGFloat) {
        let zone = point.x / max(width, 1)
        let delta: Int
        if zone < 0.3 {
            delta = rightToLeft ? 1 : -1
        } else if zone > 0.7 {
            delta = rightToLeft ? -1 : 1
        } else {
            callbacks.tapCenter()
            return
        }
        if panelByPanel, let page = pageController.viewControllers?.first as? ZoomingPageController, page.stepPanel(delta) {
            return
        }
        step(delta)
    }

    private func prefetch(around index: Int) {
        let upcoming = pages.indices.filter { $0 > index && $0 <= index + 4 }.map { pages[$0] }
        ImageLoader.shared.prefetch(upcoming, width: ZoomingPageController.decodeWidth(view.bounds.width))
    }

    private func screen(of vc: UIViewController) -> Int {
        (vc as? ZoomingPageController)?.screen ?? (vc as? EndCardController)?.screen ?? 0
    }

    // MARK: Data source. In right-to-left mode the next page sits to the left.

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        controller(at: screen(of: vc) + (rightToLeft ? 1 : -1))
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        controller(at: screen(of: vc) + (rightToLeft ? -1 : 1))
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let vc = pvc.viewControllers?.first else { return }
        let shown = screen(of: vc)
        guard screens.indices.contains(shown) else { return }
        currentScreen = shown
        currentIndex = screens[shown].last ?? 0
        prefetch(around: currentIndex)
        callbacks.pageChanged(currentIndex)
    }
}

/// One screen of the reader: a page, or two side by side, zoomable together, with a
/// spinner and retry.
final class ZoomingPageController: UIViewController, UIScrollViewDelegate {
    /// Which of the reader's screens this is.
    var screen = 0
    var onTap: (CGPoint, CGFloat) -> Void = { _, _ in }
    /// Panel by panel. Only for a single page.
    var guided = false
    var rightToLeft = true
    var startAtLastPanel = false
    /// Panels in reading order, once detected; nil until then.
    private var panels: [PanelRect]?
    /// The panel shown, or -1 for the whole page.
    private var panelIndex = -1
    private var detectTask: Task<Void, Never>?
    /// In reading order: with two, the first is read first.
    private let pages: [ImagePage]
    private let firstNumber: Int
    private let scrollView = UIScrollView()
    /// What zooms: it holds the page, or both pages.
    private let content = UIView()
    private var imageViews: [UIImageView] = []
    private var failed: Set<Int> = []
    private var loadingCount = 0
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retry = UIButton(type: .system)
    private var tasks: [Task<Void, Never>] = []

    /// The page that panel by panel works on.
    private var imageView: UIImageView { imageViews[0] }

    /// Width in points to decode pages at. Wider than the screen (never wider than the
    /// source), so a page zoomed in stays sharp. Prefetches must use the same width, or
    /// they land under a different cache key and the page loads again.
    static func decodeWidth(_ viewWidth: CGFloat) -> CGFloat {
        max(viewWidth, UIScreen.main.bounds.width) * 2.5
    }

    init(pages: [ImagePage], firstNumber: Int) {
        self.pages = Array(pages.prefix(2))
        self.firstNumber = firstNumber
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        content.frame = scrollView.bounds
        scrollView.addSubview(content)
        for offset in pages.indices {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.accessibilityLabel = "Page \(firstNumber + offset)"
            imageView.isAccessibilityElement = true
            content.addSubview(imageView)
            imageViews.append(imageView)
        }
        layoutPages()

        spinner.color = .lightGray
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        retry.setTitle("Couldn't load page. Tap to retry.", for: .normal)
        retry.tintColor = .lightGray
        retry.isHidden = true
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.addTarget(self, action: #selector(load), for: .touchUpInside)
        view.addSubview(retry)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retry.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retry.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        single.require(toFail: double)
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(single)
        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Zoomed in, the content carries a scale; it's laid out again once back at 1x.
        if abs(scrollView.zoomScale - 1) < 0.001 { layoutPages() }
    }

    /// One page fills the screen. Two sit either side of the middle, each as large as its
    /// half allows and touching the other, the way an open book does.
    private func layoutPages() {
        let bounds = scrollView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        content.frame = CGRect(origin: .zero, size: bounds.size)
        scrollView.contentSize = bounds.size
        guard imageViews.count == 2 else {
            imageViews.first?.frame = content.bounds
            return
        }
        let half = CGSize(width: bounds.width / 2, height: bounds.height)
        for (offset, imageView) in imageViews.enumerated() {
            // The page read first is on the right when reading right to left.
            let onLeft = (offset == 0) != rightToLeft
            var size = half
            if let image = imageView.image, image.size.width > 0, image.size.height > 0 {
                let scale = min(half.width / image.size.width, half.height / image.size.height)
                size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            }
            imageView.frame = CGRect(
                x: onLeft ? half.width - size.width : half.width, y: (half.height - size.height) / 2,
                width: size.width, height: size.height)
        }
    }

    @objc private func load() {
        retry.isHidden = true
        failed = []
        let width = Self.decodeWidth(view.bounds.width)
        for (offset, page) in pages.enumerated() where imageViews[offset].image == nil {
            if let hit = ImageLoader.shared.cached(page, width: width) {
                show(hit, at: offset)
                continue
            }
            loadingCount += 1
            spinner.startAnimating()
            tasks.append(Task { [weak self] in
                do {
                    let loaded = try await ImageLoader.shared.load(page, width: width)
                    self?.show(loaded.image, at: offset)
                } catch {
                    if !Task.isCancelled { self?.failed.insert(offset) }
                }
                self?.finishedOne()
            })
        }
    }

    private func show(_ image: UIImage, at offset: Int) {
        imageViews[offset].image = image
        if abs(scrollView.zoomScale - 1) < 0.001 { layoutPages() }
        if offset == 0 { findPanels() }
    }

    private func finishedOne() {
        loadingCount = max(0, loadingCount - 1)
        guard loadingCount == 0 else { return }
        spinner.stopAnimating()
        retry.isHidden = failed.isEmpty
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showStartPanel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scrollView.setZoomScale(1, animated: false)
        panelIndex = -1
    }

    deinit {
        tasks.forEach { $0.cancel() }
        detectTask?.cancel()
    }

    // MARK: Panels

    func setGuided(_ value: Bool, rightToLeft: Bool) {
        guard pages.count == 1 else { return }
        guided = value
        if rightToLeft != self.rightToLeft { panels = nil }
        self.rightToLeft = rightToLeft
        startAtLastPanel = false
        if value {
            findPanels()
            showStartPanel()
        } else {
            panelIndex = -1
            scrollView.setZoomScale(1, animated: true)
        }
    }

    /// Moves to the next or previous panel. False at the page's edge, so the reader turns the page.
    func stepPanel(_ delta: Int) -> Bool {
        guard guided, let panels, !panels.isEmpty else { return false }
        let next = panelIndex + delta
        // Back from the first panel, or on from the last, turns the page.
        guard next >= 0, next < panels.count else { return false }
        return show(panel: next)
    }

    private func findPanels() {
        guard guided, panels == nil, detectTask == nil, let page = pages.first, let image = imageView.image else { return }
        let key = page.url.absoluteString + (rightToLeft ? "|rtl" : "|ltr")
        if let known = PanelCache.shared[key] {
            panels = known
            showStartPanel()
            return
        }
        let rtl = rightToLeft
        detectTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { PanelCache.detect(image, rightToLeft: rtl) }.value
            guard let self, !Task.isCancelled else { return }
            PanelCache.shared[key] = found
            self.panels = found
            self.detectTask = nil
            self.showStartPanel()
        }
    }

    private func showStartPanel() {
        guard guided, let panels, !panels.isEmpty, panelIndex < 0, view.window != nil else { return }
        _ = show(panel: startAtLastPanel ? panels.count - 1 : 0)
        startAtLastPanel = false
    }

    @discardableResult
    private func show(panel index: Int) -> Bool {
        panelIndex = index
        guard index >= 0, let panels, panels.indices.contains(index), let image = imageView.image else {
            scrollView.setZoomScale(1, animated: true)
            return true
        }
        scrollView.maximumZoomScale = 8
        // Where the image sits inside the image view, which is aspect fit.
        let bounds = imageView.bounds
        let scale = min(bounds.width / max(image.size.width, 1), bounds.height / max(image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        let p = panels[index]
        let rect = CGRect(x: origin.x + p.x * size.width, y: origin.y + p.y * size.height,
                          width: p.width * size.width, height: p.height * size.height).insetBy(dx: -6, dy: -6)
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut]) {
            self.scrollView.zoom(to: rect, animated: false)
        }
        UIAccessibility.post(notification: .announcement, argument: "Panel \(index + 1) of \(panels.count)")
        return true
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    @objc private func singleTapped(_ gesture: UITapGestureRecognizer) {
        guard guided || scrollView.zoomScale <= 1.01 else { return }
        onTap(gesture.location(in: view), view.bounds.width)
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: content)
            let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

/// Shown after the last page.
final class EndCardController: UIViewController {
    var screen = 0
    var onNext: () -> Void = {}
    var onTap: (CGPoint, CGFloat) -> Void = { _, _ in }
    private let titleText: String
    private let nextTitle: String?

    init(title: String, nextTitle: String?) {
        self.titleText = title
        self.nextTitle = nextTitle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let title = UILabel()
        title.text = titleText
        title.textColor = UIColor(white: 0.75, alpha: 1)
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.textAlignment = .center
        title.numberOfLines = 0

        let next = UILabel()
        next.text = nextTitle.map { "Next: \($0)" } ?? "You're caught up. New chapters will show a badge in your library."
        next.textColor = .white
        next.font = .preferredFont(forTextStyle: .headline)
        next.textAlignment = .center
        next.numberOfLines = 0

        var config = UIButton.Configuration.filled()
        config.title = "Read next chapter"
        config.cornerStyle = .large
        config.baseBackgroundColor = UIColor(red: 0.239, green: 0.745, blue: 0.624, alpha: 1)
        config.baseForegroundColor = UIColor(red: 0.012, green: 0.082, blue: 0.059, alpha: 1)
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onNext() })
        button.isHidden = nextTitle == nil

        let stack = UIStackView(arrangedSubviews: [title, next, button])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        onTap(gesture.location(in: view), view.bounds.width)
    }
}

/// Panels found per page, kept while the app runs, and the image work to find them.
@MainActor
final class PanelCache {
    static let shared = PanelCache()
    private var entries: [String: [PanelRect]] = [:]
    private var order: [String] = []

    subscript(key: String) -> [PanelRect]? {
        get { entries[key] }
        set {
            guard let newValue else { return }
            if entries[key] == nil { order.append(key) }
            entries[key] = newValue
            while order.count > 300 { entries.removeValue(forKey: order.removeFirst()) }
        }
    }

    /// Draws the page small and grey and runs the gutter detector over it.
    nonisolated static func detect(_ image: UIImage, rightToLeft: Bool) -> [PanelRect] {
        guard let cg = image.cgImage, cg.width > 0 else { return [] }
        let width = min(320, cg.width)
        let height = max(1, min(1600, Int(Double(cg.height) * Double(width) / Double(cg.width))))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        return PanelDetector.detect(gray: pixels, width: width, height: height, rightToLeft: rightToLeft)
    }
}
