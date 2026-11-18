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
    let endTitle: String
    let nextTitle: String?
    @Binding var page: Int
    var onTapCenter: () -> Void
    var onNextChapter: () -> Void
    var onPreviousChapter: () -> Void

    func makeUIViewController(context: Context) -> PagedImageReaderController {
        let controller = PagedImageReaderController()
        controller.callbacks = callbacks(context)
        controller.load(chapterID: chapterID, pages: pages, start: startPage, rightToLeft: rightToLeft, endTitle: endTitle, nextTitle: nextTitle)
        return controller
    }

    func updateUIViewController(_ controller: PagedImageReaderController, context: Context) {
        controller.callbacks = callbacks(context)
        if controller.chapterID != chapterID {
            controller.load(chapterID: chapterID, pages: pages, start: startPage, rightToLeft: rightToLeft, endTitle: endTitle, nextTitle: nextTitle)
        } else {
            controller.setRightToLeft(rightToLeft)
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
            go(to: target, animated: true)
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
        page.onTap = { [weak self] point, width in self?.handleTap(point, width: width) }
        return page
    }

    private func handleTap(_ point: CGPoint, width: CGFloat) {
        let zone = point.x / max(width, 1)
        if zone < 0.3 {
            step(rightToLeft ? 1 : -1)
        } else if zone > 0.7 {
            step(rightToLeft ? -1 : 1)
        } else {
            callbacks.tapCenter()
        }
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
            return
        }
        spinner.startAnimating()
        task = Task { [weak self, page] in
            do {
                let loaded = try await ImageLoader.shared.load(page, width: width)
                self?.imageView.image = loaded.image
            } catch {
                if !Task.isCancelled { self?.retry.isHidden = false }
            }
            self?.spinner.stopAnimating()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scrollView.setZoomScale(1, animated: false)
    }

    deinit { task?.cancel() }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func singleTapped(_ gesture: UITapGestureRecognizer) {
        guard scrollView.zoomScale <= 1.01 else { return }
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
