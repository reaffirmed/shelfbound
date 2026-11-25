import Foundation

/// A panel on a comic page, as fractions of the page (0...1, origin top left).
public struct PanelRect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
}

/// Finds the panels on a comic page by cutting it along its gutters: the runs of plain
/// background between panels. The page is cut into rows first, then each row into
/// panels, and so on, which gives reading order directly: top to bottom, and right to
/// left for manga. Pages it can't split (splash pages, borderless art) return no
/// panels, and the reader shows the whole page instead.
public enum PanelDetector {
    public struct Options: Sendable {
        /// How far a pixel can be from the background and still count as gutter, 0...255.
        public var tolerance: Int = 48
        /// Ink allowed in a gutter line, as a fraction of its length (stray specks, speech tails).
        public var noise: Double = 0.012
        /// The narrowest gutter, as a fraction of the page's shorter side.
        public var minGutter: Double = 0.008
        /// Panels smaller than this fraction of the page are dropped.
        public var minPanelArea: Double = 0.012
        public var maxDepth = 6

        public init() {}
    }

    /// `gray` holds `width * height` luminance bytes, row by row from the top.
    public static func detect(gray: [UInt8], width: Int, height: Int, rightToLeft: Bool, options: Options = Options()) -> [PanelRect] {
        guard width > 8, height > 8, gray.count >= width * height else { return [] }
        let background = backgroundLevel(gray, width: width, height: height)
        var ink = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) { ink[i] = abs(Int(gray[i]) - background) > options.tolerance }
        let page = Page(ink: ink, width: width, height: height)
        let gutter = max(2, Int(Double(min(width, height)) * options.minGutter))

        var found: [Box] = []
        split(Box(x0: 0, y0: 0, x1: width, y1: height), page: page, gutter: gutter, noise: options.noise,
              rightToLeft: rightToLeft, depth: options.maxDepth, horizontalFirst: true, into: &found)
        let total = Double(width * height)
        let panels = found.filter { Double($0.area) / total >= options.minPanelArea }
        // One panel covering nearly the whole page is just the page.
        if panels.count <= 1 { return [] }
        return panels.map {
            PanelRect(x: Double($0.x0) / Double(width), y: Double($0.y0) / Double(height),
                      width: Double($0.x1 - $0.x0) / Double(width), height: Double($0.y1 - $0.y0) / Double(height))
        }
    }

    // MARK: - Internals

    struct Box: Equatable {
        var x0, y0, x1, y1: Int
        var area: Int { max(0, x1 - x0) * max(0, y1 - y0) }
        var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    }

    struct Page {
        let ink: [Bool]
        let width: Int
        let height: Int

        func rowInk(_ y: Int, _ box: Box) -> Int {
            var n = 0
            let base = y * width
            for x in box.x0..<box.x1 where ink[base + x] { n += 1 }
            return n
        }

        func columnInk(_ x: Int, _ box: Box) -> Int {
            var n = 0
            for y in box.y0..<box.y1 where ink[y * width + x] { n += 1 }
            return n
        }
    }

    /// The page's paper colour: the median of its outer edge, which is almost always margin.
    static func backgroundLevel(_ gray: [UInt8], width: Int, height: Int) -> Int {
        var edge: [UInt8] = []
        for x in 0..<width { edge.append(gray[x]); edge.append(gray[(height - 1) * width + x]) }
        for y in 0..<height { edge.append(gray[y * width]); edge.append(gray[y * width + width - 1]) }
        edge.sort()
        return Int(edge[edge.count / 2])
    }

    /// Shrinks a box to the ink inside it.
    static func trim(_ box: Box, page: Page, noise: Double) -> Box {
        var b = box
        let rowLimit = { (b: Box) in Int(Double(b.x1 - b.x0) * noise) }
        let colLimit = { (b: Box) in Int(Double(b.y1 - b.y0) * noise) }
        while !b.isEmpty, page.rowInk(b.y0, b) <= rowLimit(b) { b.y0 += 1 }
        while !b.isEmpty, page.rowInk(b.y1 - 1, b) <= rowLimit(b) { b.y1 -= 1 }
        while !b.isEmpty, page.columnInk(b.x0, b) <= colLimit(b) { b.x0 += 1 }
        while !b.isEmpty, page.columnInk(b.x1 - 1, b) <= colLimit(b) { b.x1 -= 1 }
        return b
    }

    /// Cuts a box along its gutters in one direction. Returns the pieces in order, or
    /// nil if there's no gutter to cut along.
    static func cut(_ box: Box, page: Page, horizontal: Bool, gutter: Int, noise: Double) -> [Box]? {
        let length = horizontal ? box.x1 - box.x0 : box.y1 - box.y0
        let limit = Int(Double(length) * noise)
        let range = horizontal ? box.y0..<box.y1 : box.x0..<box.x1
        var pieces: [Box] = []
        var start = range.lowerBound
        var gapStart: Int?
        for i in range {
            let empty = (horizontal ? page.rowInk(i, box) : page.columnInk(i, box)) <= limit
            if empty {
                if gapStart == nil { gapStart = i }
            } else if let g = gapStart {
                if i - g >= gutter, g > start {
                    pieces.append(horizontal ? Box(x0: box.x0, y0: start, x1: box.x1, y1: g) : Box(x0: start, y0: box.y0, x1: g, y1: box.y1))
                    start = i
                }
                gapStart = nil
            }
        }
        guard !pieces.isEmpty else { return nil }
        pieces.append(horizontal ? Box(x0: box.x0, y0: start, x1: box.x1, y1: box.y1) : Box(x0: start, y0: box.y0, x1: box.x1, y1: box.y1))
        return pieces
    }

    static func split(_ box: Box, page: Page, gutter: Int, noise: Double, rightToLeft: Bool, depth: Int, horizontalFirst: Bool, into out: inout [Box]) {
        let b = trim(box, page: page, noise: noise)
        guard !b.isEmpty else { return }
        guard depth > 0 else { out.append(b); return }
        for horizontal in horizontalFirst ? [true, false] : [false, true] {
            guard var pieces = cut(b, page: page, horizontal: horizontal, gutter: gutter, noise: noise) else { continue }
            if !horizontal && rightToLeft { pieces.reverse() }
            for piece in pieces {
                split(piece, page: page, gutter: gutter, noise: noise, rightToLeft: rightToLeft,
                      depth: depth - 1, horizontalFirst: !horizontal, into: &out)
            }
            return
        }
        out.append(b)
    }
}
