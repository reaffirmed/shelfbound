import ShelfCore
import SwiftUI
import UIKit

/// Paged manga reader: one page per screen, right to left or left to right, with pinch
/// and double-tap zoom, tap zones, and an end-of-chapter card after the last page.
@MainActor
struct PagedImageReader: UIViewControllerRepresentable {
    let chapterID: String
    let pages: [ImagePage]
    let startPage: Int
    let rightToLeft: Bool
    var panelByPanel = false
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
        controller.load(chapterID: chapterID, pages: pages, start: startPage, rightToLeft: rightToLeft, endTitle: endTitle, nextTitle: nextTitle)
        return controller
    }

    func updateUIViewController(_ controller: PagedImageReaderController, context: Context) {
        controller.callbacks = callbacks(context)
        if controller.chapterID != chapterID {
            controller.load(chapterID: chapterID, pages: pages, start: startPage, rightToLeft: rightToLeft, endTitle: endTitle, nextTitle: nextTitle)
        } else {
            controller.setRightToLeft(rightToLeft)
            controller.setPanelByPanel(panelByPanel)
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
    private(set) var currentIndex = 0
    private var pages: [ImagePage] = []
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

    func load(chapterID: String, pages: [ImagePage], start: Int, rightToLeft: Bool, endTitle: String, nextTitle: String?) {
        loadViewIfNeeded()
        self.chapterID = chapterID
        self.pages = pages
        self.rightToLeft = rightToLeft
        self.endTitle = endTitle
        self.nextTitle = nextTitle
        currentIndex = min(max(0, start), pages.count)
        if let vc = controller(at: currentIndex) {
            pageController.setViewControllers([vc], direction: .forward, animated: false)
        }
        prefetch(around: currentIndex)
    }

    func setRightToLeft(_ value: Bool) {
        guard value != rightToLeft else { return }
        rightToLeft = value
        // Rebuild so swipe directions match.
        if let vc = controller(at: currentIndex) {
            pageController.setViewControllers([vc], direction: .forward, animated: false)
        }
    }

    func setPanelByPanel(_ value: Bool) {
        guard value != panelByPanel else { return }
        panelByPanel = value
        (pageController.viewControllers?.first as? ZoomingPageController)?.setGuided(value, rightToLeft: rightToLeft)
    }

    func updateEnd(title: String, next: String?) {
        guard title != endTitle || next != nextTitle else { return }
        endTitle = title
        nextTitle = next
        if currentIndex == pages.count, let vc = controller(at: currentIndex) {
            pageController.setViewControllers([vc], direction: .forward, animated: false)
        }
    }

    func go(to index: Int, animated: Bool) {
        let target = min(max(0, index), pages.count)
        guard target != currentIndex, let vc = controller(at: target) else { return }
        let forward = target > currentIndex
        let direction: UIPageViewController.NavigationDirection = (forward != rightToLeft) ? .forward : .reverse
        currentIndex = target
        pageController.setViewControllers([vc], direction: direction, animated: animated)
        prefetch(around: target)
        callbacks.pageChanged(target)
    }

    /// Next/previous page in reading order, or the next/previous chapter at the edges.
    func step(_ delta: Int) {
        let target = currentIndex + delta
        if target > pages.count {
            callbacks.nextChapter()
        } else if target < 0 {
            callbacks.previousChapter()
        } else {
            enteringBackward = delta < 0
            go(to: target, animated: true)
            enteringBackward = false
        }
    }

    // Index `pages.count` is the end-of-chapter card.
    private func controller(at index: Int) -> UIViewController? {
        guard index >= 0, index <= pages.count else { return nil }
        if index == pages.count {
            let end = EndCardController(title: endTitle, nextTitle: nextTitle)
            end.index = index
            end.onNext = { [weak self] in self?.callbacks.nextChapter() }
            end.onTap = { [weak self] point, width in self?.handleTap(point, width: width) }
            return end
        }
        let page = ZoomingPageController(page: pages[index])
        page.index = index
        page.guided = panelByPanel
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
        let upcoming = pages.indices.filter { $0 > index && $0 <= index + 3 }.map { pages[$0] }
        ImageLoader.shared.prefetch(upcoming, width: view.bounds.width)
    }

    private func index(of vc: UIViewController) -> Int {
        (vc as? ZoomingPageController)?.index ?? (vc as? EndCardController)?.index ?? 0
    }

    // MARK: Data source. In right-to-left mode the next page sits to the left.

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        controller(at: index(of: vc) + (rightToLeft ? 1 : -1))
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        controller(at: index(of: vc) + (rightToLeft ? -1 : 1))
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let vc = pvc.viewControllers?.first else { return }
        currentIndex = index(of: vc)
        prefetch(around: currentIndex)
        callbacks.pageChanged(currentIndex)
    }
}

/// One page: a zoomable image with a spinner and retry.
final class ZoomingPageController: UIViewController, UIScrollViewDelegate {
    var index = 0
    var onTap: (CGPoint, CGFloat) -> Void = { _, _ in }
    var guided = false
    var rightToLeft = true
    var startAtLastPanel = false
    /// Panels in reading order, once detected; nil until then.
    private var panels: [PanelRect]?
    /// The panel shown, or -1 for the whole page.
    private var panelIndex = -1
    private var detectTask: Task<Void, Never>?
    private let page: ImagePage
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retry = UIButton(type: .system)
    private var task: Task<Void, Never>?

    init(page: ImagePage) {
        self.page = page
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

        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.accessibilityLabel = "Page \(index + 1)"
        imageView.isAccessibilityElement = true
        scrollView.addSubview(imageView)

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

    @objc private func load() {
        retry.isHidden = true
        let width = max(view.bounds.width, UIScreen.main.bounds.width) * 1.5 // decode a little larger for zoom
        if let hit = ImageLoader.shared.cached(page, width: width) {
            imageView.image = hit
            findPanels()
            return
        }
        spinner.startAnimating()
        task = Task { [weak self, page] in
            do {
                let loaded = try await ImageLoader.shared.load(page, width: width)
                self?.imageView.image = loaded.image
                self?.findPanels()
            } catch {
                if !Task.isCancelled { self?.retry.isHidden = false }
            }
            self?.spinner.stopAnimating()
        }
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
        task?.cancel()
        detectTask?.cancel()
    }

    // MARK: Panels

    func setGuided(_ value: Bool, rightToLeft: Bool) {
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
        guard guided, panels == nil, detectTask == nil, let image = imageView.image else { return }
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

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func singleTapped(_ gesture: UITapGestureRecognizer) {
        guard guided || scrollView.zoomScale <= 1.01 else { return }
        onTap(gesture.location(in: view), view.bounds.width)
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

/// Shown after the last page.
final class EndCardController: UIViewController {
    var index = 0
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
