import ShelfCore
import SwiftUI
import UIKit

struct StripChapter: Identifiable, Hashable {
    let id: String
    let title: String
    let pages: [ImagePage]
}

/// Webtoon reader: images stacked edge to edge with no gaps, chapters joined end to end.
/// Images are decoded at screen width, and very tall strips are scaled to a safe size.
@MainActor
struct VerticalImageReader: UIViewControllerRepresentable {
    let chapters: [StripChapter]
    /// Where to start: chapter and 0...1 within it. Applied when the first chapter changes.
    let start: (chapterID: String, progress: Double)
    /// Set to jump within the current chapter (from the slider); cleared after use.
    @Binding var seek: Double?
    var autoScrollSpeed: Double
    /// False when the last loaded chapter is the newest one.
    var moreAfterLast: Bool
    var onPosition: (String, Double) -> Void
    var onNearEnd: () -> Void
    var onTap: () -> Void

    func makeUIViewController(context: Context) -> VerticalImageReaderController {
        let controller = VerticalImageReaderController()
        controller.callbacks = callbacks
        controller.set(chapters: chapters, start: start)
        return controller
    }

    func updateUIViewController(_ controller: VerticalImageReaderController, context: Context) {
        controller.callbacks = callbacks
        controller.set(chapters: chapters, start: start)
        controller.autoScrollSpeed = autoScrollSpeed
        controller.moreAfterLast = moreAfterLast
        if let seek {
            controller.seek(to: seek)
            DispatchQueue.main.async { self.seek = nil }
        }
    }

    private var callbacks: VerticalImageReaderController.Callbacks {
        .init(position: onPosition, nearEnd: onNearEnd, tap: onTap)
    }
}

final class VerticalImageReaderController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    struct Callbacks {
        var position: (String, Double) -> Void = { _, _ in }
        var nearEnd: () -> Void = {}
        var tap: () -> Void = {}
    }

    var callbacks = Callbacks()
    var autoScrollSpeed: Double = 0 {
        didSet { updateAutoScroll() }
    }
    var moreAfterLast = true {
        didSet {
            guard moreAfterLast != oldValue, !chapters.isEmpty else { return }
            let last = IndexPath(item: 0, section: chapters.count - 1)
            if let footer = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionFooter, at: last) as? ChapterFooter {
                footer.configure(ended: chapters[last.section].title, next: nil, more: moreAfterLast)
            }
        }
    }

    private var chapters: [StripChapter] = []
    private var aspects: [URL: CGFloat] = [:]
    private var pendingStart: (chapterID: String, progress: Double)?
    private var lastReported: (String, Int)?
    private var lastReportTime: CFTimeInterval = 0
    /// When "near the end" was last sent: once a second is plenty to start (or retry) loading
    /// the next chapter, instead of on every frame of scrolling.
    private var nearEndSentAt: CFTimeInterval = 0
    /// Pages whose real shape arrived since the last layout pass; applied together.
    private var pendingAspects: [IndexPath: URL] = [:]
    private var aspectFlushScheduled = false
    /// How many pages ahead to fetch, across chapter ends too.
    private let prefetchAhead = 5
    /// Saving the position updates the whole app, so while scrolling it goes at most this often.
    private let reportInterval: CFTimeInterval = 0.5
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private let footerHeight: CGFloat = 150

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .black
        view.dataSource = self
        view.delegate = self
        view.contentInsetAdjustmentBehavior = .never
        view.showsVerticalScrollIndicator = false
        view.register(StripCell.self, forCellWithReuseIdentifier: "page")
        view.register(ChapterFooter.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: "footer")
        return view
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyPendingStart()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        let position = currentPosition()
        coordinator.animate(alongsideTransition: { _ in
            self.collectionView.collectionViewLayout.invalidateLayout()
        }, completion: { _ in
            if let position { self.scroll(toChapter: position.0, progress: position.1) }
        })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateAutoScroll()
    }

    // The display link holds on to this controller, so stop it when the reader closes.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
    }

    func set(chapters new: [StripChapter], start: (chapterID: String, progress: Double)) {
        loadViewIfNeeded()
        if new.map(\.id) == chapters.map(\.id) { return }
        let isAppend = !chapters.isEmpty && new.count > chapters.count && Array(new.prefix(chapters.count).map(\.id)) == chapters.map(\.id)
        if isAppend {
            let added = IndexSet(chapters.count..<new.count)
            chapters = new
            UIView.performWithoutAnimation { collectionView.insertSections(added) }
        } else {
            chapters = new
            pendingAspects = [:]
            nearEndSentAt = 0
            collectionView.reloadData()
            pendingStart = start
            view.setNeedsLayout()
        }
    }

    func seek(to progress: Double) {
        guard let position = currentPosition() else { return }
        scroll(toChapter: position.0, progress: progress)
    }

    private func applyPendingStart() {
        guard let start = pendingStart, collectionView.bounds.width > 0, !chapters.isEmpty else { return }
        pendingStart = nil
        collectionView.layoutIfNeeded()
        scroll(toChapter: start.chapterID, progress: start.progress)
    }

    // MARK: Geometry

    private func sectionRange(_ section: Int) -> ClosedRange<CGFloat>? {
        guard section < chapters.count, !chapters[section].pages.isEmpty else { return nil }
        let layout = collectionView.collectionViewLayout
        guard let first = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: section)),
              let footer = layout.layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionFooter, at: IndexPath(item: 0, section: section))
        else { return nil }
        return first.frame.minY...max(first.frame.minY + 1, footer.frame.minY)
    }

    private func scroll(toChapter id: String, progress: Double) {
        guard let section = chapters.firstIndex(where: { $0.id == id }), let range = sectionRange(section) else { return }
        let span = max(1, range.upperBound - range.lowerBound - collectionView.bounds.height)
        let y = range.lowerBound + span * CGFloat(progress)
        let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.setContentOffset(CGPoint(x: 0, y: min(maxY, max(0, y))), animated: false)
        reportPosition(force: true)
    }

    /// The chapter at the middle of the screen and how far through it we are.
    private func currentPosition() -> (String, Double)? {
        let probe = collectionView.contentOffset.y + collectionView.bounds.height * 0.5
        for section in chapters.indices {
            guard let range = sectionRange(section) else { continue }
            if probe <= range.upperBound + footerHeight || section == chapters.count - 1 {
                let progress = (collectionView.contentOffset.y - range.lowerBound) / max(1, range.upperBound - range.lowerBound - collectionView.bounds.height)
                return (chapters[section].id, Double(min(1, max(0, progress))))
            }
        }
        return nil
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportPosition(force: false)
        if scrollView.contentOffset.y + scrollView.bounds.height * 3 > scrollView.contentSize.height {
            let now = CACurrentMediaTime()
            if now - nearEndSentAt >= 1 {
                nearEndSentAt = now
                callbacks.nearEnd()
            }
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportPosition(force: true) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reportPosition(force: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        reportPosition(force: true)
    }

    /// Tells the reader where we are. Each report saves the position and redraws the reader's
    /// bars, so while the finger or momentum is moving it's sent at most every half second
    /// (or right away when a new chapter starts), and once more when scrolling stops.
    private func reportPosition(force: Bool) {
        guard let position = currentPosition() else { return }
        let bucket = Int(position.1 * 200)
        guard lastReported?.0 != position.0 || lastReported?.1 != bucket else { return }
        let now = CACurrentMediaTime()
        let newChapter = lastReported?.0 != position.0
        guard force || newChapter || now - lastReportTime >= reportInterval else { return }
        lastReported = (position.0, bucket)
        lastReportTime = now
        callbacks.position(position.0, position.1)
    }

    @objc private func tapped() {
        if displayLink != nil {
            autoScrollSpeed = 0
        }
        callbacks.tap()
    }

    private func updateAutoScroll() {
        if autoScrollSpeed > 0, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTick = 0
        } else if autoScrollSpeed <= 0, displayLink != nil {
            displayLink?.invalidate()
            displayLink = nil
            reportPosition(force: true)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTick = link.timestamp }
        guard lastTick > 0, !collectionView.isDragging else { return }
        let dt = link.timestamp - lastTick
        let maxY = collectionView.contentSize.height - collectionView.bounds.height
        let y = min(maxY, collectionView.contentOffset.y + CGFloat(autoScrollSpeed * dt))
        collectionView.contentOffset.y = max(0, y)
    }

    // MARK: Data source

    func numberOfSections(in collectionView: UICollectionView) -> Int { chapters.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        chapters[section].pages.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! StripCell
        let page = chapters[indexPath.section].pages[indexPath.item]
        let width = collectionView.bounds.width
        cell.show(page, width: width) { [weak self] aspect in
            self?.learned(aspect: aspect, for: page.url, at: indexPath)
        }
        prefetch(after: indexPath, width: width)
        return cell
    }

    /// Loads the next few pages, into the next chapter too, before they're on screen. Each
    /// one's real height is applied as soon as it arrives, while it's still off screen, so
    /// the page doesn't change size (and shove what's below it) as it scrolls into view.
    private func prefetch(after indexPath: IndexPath, width: CGFloat) {
        var section = indexPath.section
        var item = indexPath.item + 1
        var count = 0
        while count < prefetchAhead, section < chapters.count {
            let pages = chapters[section].pages
            if item >= pages.count {
                section += 1
                item = 0
                continue
            }
            let page = pages[item]
            let target = IndexPath(item: item, section: section)
            if ImageLoader.shared.cached(page, width: width) == nil {
                Task(priority: .utility) { [weak self] in
                    guard let loaded = try? await ImageLoader.shared.load(page, width: width, urgent: false) else { return }
                    self?.learned(aspect: loaded.aspect, for: page.url, at: target)
                }
            }
            item += 1
            count += 1
        }
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let footer = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "footer", for: indexPath) as! ChapterFooter
        let next = indexPath.section + 1 < chapters.count ? chapters[indexPath.section + 1].title : nil
        footer.configure(ended: chapters[indexPath.section].title, next: next, more: moreAfterLast)
        return footer
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let page = chapters[indexPath.section].pages[indexPath.item]
        let width = collectionView.bounds.width
        let aspect = aspects[page.url] ?? ImageLoader.shared.knownAspect(page.url) ?? 1.4
        return CGSize(width: width, height: max(1, (width * aspect).rounded()))
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: footerHeight)
    }

    /// When an image's real size arrives, resize its cell without making the page jump.
    /// It compares against the cell's laid-out height, not a remembered aspect: the loader
    /// records the real aspect before this runs, so comparing aspects found no change and
    /// left tall manhwa strips squeezed into the 1.4 guess.
    ///
    /// Several pages often arrive in the same moment (prefetches finishing together), so the
    /// changes are gathered and applied in one layout pass instead of one per page.
    private func learned(aspect: CGFloat, for url: URL, at indexPath: IndexPath) {
        aspects[url] = aspect
        pendingAspects[indexPath] = url
        guard !aspectFlushScheduled else { return }
        aspectFlushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.applyLearnedAspects() }
    }

    private func applyLearnedAspects() {
        aspectFlushScheduled = false
        let pending = pendingAspects
        pendingAspects = [:]
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let top = collectionView.contentOffset.y
        var changed = false
        var shiftAbove: CGFloat = 0
        for (indexPath, url) in pending {
            guard indexPath.section < chapters.count,
                  indexPath.item < chapters[indexPath.section].pages.count,
                  chapters[indexPath.section].pages[indexPath.item].url == url,
                  let aspect = aspects[url],
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { continue }
            let delta = max(1, (width * aspect).rounded()) - frame.height
            guard abs(delta) > 0.5 else { continue }
            changed = true
            // Pages wholly above the screen grow or shrink the content above us; move with
            // them so the page being read stays put.
            if frame.maxY <= top + 1 { shiftAbove += delta }
        }
        guard changed else { return }
        UIView.performWithoutAnimation {
            let context = UICollectionViewFlowLayoutInvalidationContext()
            context.invalidateFlowLayoutDelegateMetrics = true
            collectionView.collectionViewLayout.invalidateLayout(with: context)
            collectionView.layoutIfNeeded()
            if shiftAbove != 0 { collectionView.contentOffset.y += shiftAbove }
        }
    }
}

final class StripCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var task: Task<Void, Never>?
    private var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        // Never stretch: if a cell's height is ever off, the page shows letterboxed, not squashed.
        imageView.contentMode = .scaleAspectFit
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        spinner.color = .gray
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        imageView.image = nil
        url = nil
    }

    func show(_ page: ImagePage, width: CGFloat, learned: @escaping (CGFloat) -> Void) {
        url = page.url
        if let hit = ImageLoader.shared.cached(page, width: width) {
            imageView.image = hit
            spinner.stopAnimating()
            let aspect = ImageLoader.shared.knownAspect(page.url) ?? hit.size.height / max(hit.size.width, 1)
            // Sizes the cell if it was laid out before the image's shape was known
            // (applied after this cell is handed back, together with any others).
            learned(aspect)
            return
        }
        spinner.startAnimating()
        task = Task { [weak self] in
            let loaded = try? await ImageLoader.shared.load(page, width: width)
            guard let self, self.url == page.url, !Task.isCancelled else { return }
            self.spinner.stopAnimating()
            if let loaded {
                self.imageView.image = loaded.image
                learned(loaded.aspect)
            }
        }
    }
}

final class ChapterFooter: UICollectionReusableView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.06, alpha: 1)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = UIColor(white: 0.7, alpha: 1)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(ended: String, next: String?, more: Bool) {
        let after = next.map { "\n\nNext: \($0)" }
            ?? (more ? "\n\nLoading the next chapter…" : "\n\nYou're caught up. New chapters will show a badge in your library.")
        label.text = "End of \(ended)" + after
    }
}
