import XCTest
@testable import ShelfCore

final class PanelDetectorTests: XCTestCase {
    /// A white page with black-bordered, grey-filled panels at the given pixel rects.
    private func page(_ w: Int, _ h: Int, _ rects: [(Int, Int, Int, Int)], background: UInt8 = 255) -> [UInt8] {
        var px = [UInt8](repeating: background, count: w * h)
        for (x, y, rw, rh) in rects {
            for yy in y..<(y + rh) {
                for xx in x..<(x + rw) {
                    let border = xx < x + 2 || xx >= x + rw - 2 || yy < y + 2 || yy >= y + rh - 2
                    px[yy * w + xx] = border ? (background > 128 ? 0 : 255) : 120
                }
            }
        }
        return px
    }

    func testRowsThenPanelsInMangaOrder() {
        // Top row: two panels side by side. Bottom: one wide panel.
        let gray = page(200, 300, [(10, 10, 85, 130), (105, 10, 85, 130), (10, 155, 180, 135)])
        let panels = PanelDetector.detect(gray: gray, width: 200, height: 300, rightToLeft: true)
        XCTAssertEqual(panels.count, 3)
        XCTAssertGreaterThan(panels[0].x, 0.5, "manga reads the right panel first")
        XCTAssertLessThan(panels[1].x, 0.5)
        XCTAssertGreaterThan(panels[2].y, 0.5)
        XCTAssertEqual(panels[2].width, 0.9, accuracy: 0.01)
    }

    func testLeftToRightOrder() {
        let gray = page(200, 300, [(10, 10, 85, 130), (105, 10, 85, 130), (10, 155, 180, 135)])
        let panels = PanelDetector.detect(gray: gray, width: 200, height: 300, rightToLeft: false)
        XCTAssertLessThan(panels[0].x, 0.5)
    }

    func testNestedSplitInsideAColumn() {
        // Left: one tall panel. Right: two stacked panels.
        let gray = page(200, 300, [(10, 10, 85, 280), (105, 10, 85, 130), (105, 155, 85, 135)])
        let panels = PanelDetector.detect(gray: gray, width: 200, height: 300, rightToLeft: true)
        XCTAssertEqual(panels.count, 3)
        // Right column first, top to bottom, then the tall left panel.
        XCTAssertGreaterThan(panels[0].x, 0.5)
        XCTAssertLessThan(panels[0].y, 0.5)
        XCTAssertGreaterThan(panels[1].y, 0.5)
        XCTAssertLessThan(panels[2].x, 0.5)
    }

    func testBlackGutters() {
        let gray = page(200, 300, [(10, 10, 180, 130), (10, 155, 180, 135)], background: 0)
        XCTAssertEqual(PanelDetector.detect(gray: gray, width: 200, height: 300, rightToLeft: true).count, 2)
    }

    func testSplashPageHasNoPanels() {
        let gray = page(200, 300, [(10, 10, 180, 280)])
        XCTAssertTrue(PanelDetector.detect(gray: gray, width: 200, height: 300, rightToLeft: true).isEmpty)
    }

    func testSpeckInGutterDoesNotMergePanels() {
        var gray = page(200, 300, [(10, 10, 180, 130), (10, 155, 180, 135)])
        gray[147 * 200 + 50] = 0
        XCTAssertEqual(PanelDetector.detect(gray: gray, width: 200, height: 300, rightToLeft: true).count, 2)
    }
}
