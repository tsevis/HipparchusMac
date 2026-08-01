import XCTest
@testable import HipparchusRender

/// The page, in inches, and what it comes to in each format.
///
/// The sheet this feature exists for is 24 × 36 at 300 dpi — the size a print
/// shop treats as a standard poster. Everything here is ultimately about
/// whether that one comes out right in all three exporters.
final class PageSizeTests: XCTestCase {

    private let canvas = (width: 2400, height: 1800)

    private func pixels(_ page: PageSpec) -> (width: Int, height: Int) {
        page.pixelSize(canvasWidth: canvas.width, canvasHeight: canvas.height)
    }

    // MARK: - The sheet this was built for

    func testTwentyFourByThirtySixAtThreeHundredIsSevenThousandTwoHundredBy10800() {
        let page = PageSpec(paperName: "24 × 36 in", orientation: "Portrait", dpi: 300)
        let size = pixels(page)
        XCTAssertEqual(size.width, 7200)
        XCTAssertEqual(size.height, 10800)

        // 77.76 megapixels, and the limit has to admit it.
        let cost = page.bitmapCost(canvasWidth: canvas.width, canvasHeight: canvas.height)
        XCTAssertEqual(cost.megapixels, 77.76, accuracy: 0.01)
        XCTAssertFalse(page.exceedsBitmapLimit(canvasWidth: canvas.width, canvasHeight: canvas.height))
    }

    func testTheSameSheetIsTheSameSheetInPoints() {
        let page = PageSpec(paperName: "24 × 36 in", orientation: "Portrait", dpi: 300)
        let points = page.pointSize(canvasWidth: canvas.width, canvasHeight: canvas.height)
        // 72 points to the inch, by definition, and independent of dpi — a PDF
        // carries physical size rather than a resolution.
        XCTAssertEqual(points.width, 24 * 72, accuracy: 1e-9)
        XCTAssertEqual(points.height, 36 * 72, accuracy: 1e-9)

        var finer = page
        finer.dpi = 600
        let atSixHundred = finer.pointSize(canvasWidth: canvas.width, canvasHeight: canvas.height)
        XCTAssertEqual(atSixHundred.width, points.width, accuracy: 1e-9, "dpi must not move a PDF's page size")
        XCTAssertEqual(atSixHundred.height, points.height, accuracy: 1e-9)
    }

    // MARK: - Resolution

    func testResolutionScalesThePixelsAndNothingElse() {
        var page = PageSpec(paperName: "A4", orientation: "Portrait", dpi: 300)
        let at300 = pixels(page)
        page.dpi = 600
        let at600 = pixels(page)
        XCTAssertEqual(at600.width, at300.width * 2, accuracy: 1)
        XCTAssertEqual(at600.height, at300.height * 2, accuracy: 1)

        page.dpi = 72
        let screen = pixels(page)
        XCTAssertEqual(Double(screen.width), Double(at300.width) * 72.0 / 300.0, accuracy: 1.0)
    }

    /// A4 at 300 dpi is 2480 × 3508. The SVG composition has always said so, in
    /// pixels with the 300 left implicit; stating the inches has to reproduce it
    /// exactly, or every existing sheet changes size.
    func testTheInchModelReproducesTheOldPixelPresets() {
        let a4 = PageSpec(paperName: "A4", orientation: "Portrait", dpi: 300)
        XCTAssertEqual(pixels(a4).width, 2480)
        XCTAssertEqual(pixels(a4).height, 3508)

        let a3 = PageSpec(paperName: "A3", orientation: "Portrait", dpi: 300)
        XCTAssertEqual(pixels(a3).width, 3508)
        XCTAssertEqual(pixels(a3).height, 4961)

        // The old "Poster" was 5400 × 7200, which is 18 × 24 at 300 dpi exactly.
        let poster = PageSpec(paperName: "18 × 24 in", orientation: "Portrait", dpi: 300)
        XCTAssertEqual(pixels(poster).width, 5400)
        XCTAssertEqual(pixels(poster).height, 7200)
    }

    // MARK: - Orientation

    func testOrientationTurnsTheSheetAndNotTheMap() {
        let portrait = PageSpec(paperName: "A4", orientation: "Portrait", dpi: 300)
        let landscape = PageSpec(paperName: "A4", orientation: "Landscape", dpi: 300)
        XCTAssertEqual(pixels(portrait).width, pixels(landscape).height)
        XCTAssertEqual(pixels(portrait).height, pixels(landscape).width)
        XCTAssertGreaterThan(pixels(landscape).width, pixels(landscape).height)
        XCTAssertGreaterThan(pixels(portrait).height, pixels(portrait).width)
    }

    func testASquareSheetIsUnmovedByOrientation() {
        let portrait = PageSpec(paperName: "Square", orientation: "Portrait", dpi: 150)
        let landscape = PageSpec(paperName: "Square", orientation: "Landscape", dpi: 150)
        XCTAssertEqual(pixels(portrait).width, pixels(portrait).height)
        XCTAssertEqual(pixels(portrait).width, pixels(landscape).width)
    }

    // MARK: - Canvas

    func testCanvasKeepsWhateverSizeTheCallerHad() {
        let page = PageSpec(paperName: "Canvas", orientation: "Landscape", dpi: 600)
        let size = pixels(page)
        XCTAssertEqual(size.width, canvas.width, "Canvas must ignore dpi, not multiply by it")
        XCTAssertEqual(size.height, canvas.height)
        XCTAssertNil(page.inches(canvasAspect: 1), "Canvas has no physical size to report")
    }

    /// A canvas PDF reads its pixels as CSS pixels at 96 to the inch. Treating
    /// them as points instead would call a 2400-pixel canvas a 33-inch sheet.
    func testACanvasPDFIsASensiblePhysicalSize() {
        let page = PageSpec(paperName: "Canvas")
        let points = page.pointSize(canvasWidth: 2400, canvasHeight: 1800)
        XCTAssertEqual(points.width / 72.0, 25.0, accuracy: 0.01)
        XCTAssertEqual(points.height / 72.0, 18.75, accuracy: 0.01)
    }

    /// A sheet a later build renamed must not export as a zero-size page.
    func testAnUnknownSheetBehavesAsCanvas() {
        let page = PageSpec(paperName: "Origami", orientation: "Portrait", dpi: 300)
        XCTAssertTrue(page.paper.isCanvas)
        XCTAssertEqual(pixels(page).width, canvas.width)
    }

    // MARK: - The limit

    func testTheLimitRefusesWhatCoreGraphicsWouldRefuseSilently() {
        // 24 × 36 at 600 dpi: 311 megapixels, 1.2 GB of premultiplied RGBA.
        let page = PageSpec(paperName: "24 × 36 in", orientation: "Portrait", dpi: 600)
        let cost = page.bitmapCost(canvasWidth: canvas.width, canvasHeight: canvas.height)
        XCTAssertEqual(cost.megapixels, 311.04, accuracy: 0.01)
        XCTAssertEqual(cost.megabytes, 1244.16, accuracy: 0.1)
        XCTAssertTrue(page.exceedsBitmapLimit(canvasWidth: canvas.width, canvasHeight: canvas.height))
    }

    /// Every offered sheet at 300 dpi has to be exportable as a bitmap —
    /// otherwise the picker offers a size the PNG export refuses.
    func testEveryOfferedSheetIsExportableAtPrintResolution() {
        for paper in PaperSize.all {
            for orientation in PageSpec.orientations {
                let page = PageSpec(paperName: paper.name, orientation: orientation, dpi: 300)
                XCTAssertFalse(
                    page.exceedsBitmapLimit(canvasWidth: canvas.width, canvasHeight: canvas.height),
                    "\(paper.name) \(orientation) at 300 dpi is past the bitmap limit"
                )
            }
        }
    }

    func testTheSheetsAreOfferedPortraitWithTheLongEdgeAsHeight() {
        for paper in PaperSize.all where !paper.isCanvas {
            XCTAssertLessThanOrEqual(
                paper.widthInches, paper.heightInches,
                "\(paper.name) is declared landscape; orientation is what turns a sheet"
            )
        }
    }
}
