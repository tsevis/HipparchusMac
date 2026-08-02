import XCTest
@testable import HipparchusData
@testable import HipparchusGeometry

/// The GeoTIFF subset a coverage service actually answers with.
///
/// Two kinds of check, for the same reason the other readers here have two.
/// Files are built byte by byte so a failure points at the reader rather than at
/// a blob nobody can inspect — and then one **real** coverage is read, because a
/// synthesised file only proves the reader agrees with my reading of the
/// specification. The fixture is 200×150 of EMODnet's `mean` over Cyprus,
/// fetched from their WCS: big-endian, tiled 208×144, uncompressed float32.
final class GeoTIFFTests: XCTestCase {

    // MARK: - A real coverage

    private func cyprus() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "emodnet-cyprus", withExtension: "tif"),
            "emodnet-cyprus.tif is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    func testItReadsARealCoverage() throws {
        let grid = try GeoTIFF.read(try cyprus())
        XCTAssertEqual(grid.field.columns, 200)
        XCTAssertEqual(grid.field.rows, 150)
    }

    /// The corners the service was asked for. Getting this wrong puts a valid
    /// map of somewhere else on the sheet, which is the failure mode that does
    /// not announce itself.
    func testItLandsWhereItWasAskedFor() throws {
        let grid = try GeoTIFF.read(try cyprus())
        XCTAssertEqual(grid.bounds.minLon, 32.9, accuracy: 1e-6)
        XCTAssertEqual(grid.bounds.maxLon, 33.3, accuracy: 1e-6)
        XCTAssertEqual(grid.bounds.minLat, 34.5, accuracy: 1e-6)
        XCTAssertEqual(grid.bounds.maxLat, 34.8, accuracy: 1e-6)
    }

    /// South of Cyprus is the Levantine Sea, which is deep. Whatever the file
    /// says, it must be depths rather than a colour ramp — a service can be
    /// asked for a picture of bathymetry as easily as for bathymetry, and the
    /// two are the same size and shape.
    func testItReadsDepthsRatherThanAPicture() throws {
        let grid = try GeoTIFF.read(try cyprus())
        let finite = grid.field.values.filter(\.isFinite)
        XCTAssertGreaterThan(finite.count, 1000, "almost every cell should carry a value")

        let deepest = finite.min()!
        XCTAssertLessThan(deepest, -100, "the Levantine Sea is not a shelf")
        XCTAssertGreaterThan(deepest, -5000, "and it is not the Mariana Trench")
        // A colour ramp comes back as 0…255 and would fail both of the above.
        XCTAssertFalse(
            finite.allSatisfy { $0 >= 0 && $0 <= 255 },
            "these are 0…255, so the service answered with a picture of bathymetry rather than bathymetry"
        )
    }

    /// **The coverage carries land as well as sea**, which the frame proved
    /// rather than the documentation: southern Cyprus reaches 688 m in it.
    ///
    /// That decides how it may be blended. Taking every finite cell would put
    /// EMODnet's land over the terrain mosaic's, which is a coarser answer to a
    /// question this already had a better one for. Below the waterline only.
    func testTheCoverageCarriesLandTooWhichIsWhyTheBlendIsSeaOnly() throws {
        let grid = try GeoTIFF.read(try cyprus())
        let finite = grid.field.values.filter(\.isFinite)
        XCTAssertGreaterThan(finite.max()!, 100, "this frame includes the Cypriot hills")
        XCTAssertLessThan(finite.min()!, -100, "and the sea south of them")
    }

    /// Row 0 is north everywhere else in this codebase, and a grid read upside
    /// down produces a plausible map of the wrong ground.
    func testRowZeroIsNorth() throws {
        let grid = try GeoTIFF.read(try cyprus())
        func meanDepth(row: Int) -> Double {
            let values = (0..<grid.field.columns)
                .map { grid.field[row, $0] }.filter(\.isFinite)
            return values.reduce(0, +) / Double(max(1, values.count))
        }
        // The frame runs from the Cypriot coast down into the Levantine basin,
        // so the southern edge is markedly deeper than the northern one.
        XCTAssertLessThan(meanDepth(row: grid.field.rows - 1), meanDepth(row: 0))
    }

    // MARK: - Files built byte by byte

    /// The other endianness and the other layout, which the real fixture cannot
    /// exercise because a service answers with one of each.
    func testALittleEndianStrippedImage() throws {
        let data = TIFFBuilder(bigEndian: false)
            .image(rows: 2, columns: 3, values: [
                1.5, 2.5, 3.5,
                4.5, 5.5, 6.5,
            ], origin: (10.0, 50.0), scale: (0.5, 0.5))
            .build()

        let grid = try GeoTIFF.read(data)
        XCTAssertEqual(grid.field.rows, 2)
        XCTAssertEqual(grid.field.columns, 3)
        XCTAssertEqual(grid.field[0, 0], 1.5)
        XCTAssertEqual(grid.field[1, 2], 6.5)
        XCTAssertEqual(grid.bounds.minLon, 10.0, accuracy: 1e-9)
        XCTAssertEqual(grid.bounds.maxLon, 11.5, accuracy: 1e-9)
        XCTAssertEqual(grid.bounds.maxLat, 50.0, accuracy: 1e-9)
        XCTAssertEqual(grid.bounds.minLat, 49.0, accuracy: 1e-9)
    }

    // MARK: - Refusals

    func testSomethingThatIsNotATIFFSaysSo() {
        XCTAssertThrowsError(try GeoTIFF.read(Data([0x89, 0x50, 0x4E, 0x47]))) { error in
            XCTAssertEqual(error as? GeoTIFFError, .notATIFF)
        }
    }

    func testACompressedImageIsRefusedByName() throws {
        let data = TIFFBuilder(bigEndian: false)
            .image(rows: 1, columns: 1, values: [1], origin: (0, 0), scale: (1, 1))
            .compression(5)
            .build()
        XCTAssertThrowsError(try GeoTIFF.read(data)) { error in
            guard case .unsupported(let what)? = error as? GeoTIFFError else {
                return XCTFail("expected an unsupported error, got \(error)")
            }
            XCTAssertTrue(what.contains("compression"), what)
        }
    }

    /// Refused rather than assumed north-up: a rotated grid read as if it were
    /// square is a map of somewhere else, drawn confidently.
    func testARotatedGridIsRefused() {
        XCTAssertThrowsError(
            try GeoTIFF.georeference(
                transformation: [0.1, 0.02, 0, 10, 0.02, -0.1, 0, 50, 0, 0, 0, 0, 0, 0, 0, 1],
                pixelScale: [], tiepoint: [], rows: 10, columns: 10
            )
        )
    }

    func testAnImageWithNoGeoreferenceSaysSo() {
        XCTAssertThrowsError(
            try GeoTIFF.georeference(transformation: [], pixelScale: [], tiepoint: [], rows: 4, columns: 4)
        ) { error in
            XCTAssertEqual(error as? GeoTIFFError, .noGeoreference)
        }
    }

    /// A sentinel left in place draws a trench thirty-two kilometres deep along
    /// every coastline, and every band and contour downstream believes it.
    func testASentinelBecomesAHoleRatherThanADepth() {
        XCTAssertTrue(GeoTIFF.clean(-32767, noData: -32767).isNaN)
        XCTAssertTrue(GeoTIFF.clean(-32767, noData: nil).isNaN, "and without being told, if it is absurd")
        XCTAssertTrue(GeoTIFF.clean(.nan, noData: nil).isNaN)
        XCTAssertEqual(GeoTIFF.clean(-1310, noData: -32767), -1310, "a real depth survives")
    }

    /// Pixel scale plus a tie point says the same thing as a transformation, and
    /// a service may use either.
    func testATiePointGeoreferencesAsWellAsATransformation() throws {
        let fromTiepoint = try GeoTIFF.georeference(
            transformation: [], pixelScale: [0.5, 0.5, 0],
            tiepoint: [0, 0, 0, 10, 50, 0], rows: 2, columns: 3
        )
        let fromTransformation = try GeoTIFF.georeference(
            transformation: [0.5, 0, 0, 10, 0, -0.5, 0, 50, 0, 0, 0, 0, 0, 0, 0, 1],
            pixelScale: [], tiepoint: [], rows: 2, columns: 3
        )
        XCTAssertEqual(fromTiepoint.minLon, fromTransformation.minLon, accuracy: 1e-9)
        XCTAssertEqual(fromTiepoint.maxLat, fromTransformation.maxLat, accuracy: 1e-9)
        XCTAssertEqual(fromTiepoint.minLat, fromTransformation.minLat, accuracy: 1e-9)
    }
}

// MARK: - A TIFF, one byte at a time

/// Builds a minimal single-strip float32 GeoTIFF.
///
/// The point of writing the bytes rather than committing a blob is that a
/// failure says which field the reader misread.
private struct TIFFBuilder {
    let bigEndian: Bool
    private var rows = 0, columns = 0
    private var values: [Double] = []
    private var origin: (Double, Double) = (0, 0)
    private var scale: (Double, Double) = (1, 1)
    private var compressionValue = 1

    init(bigEndian: Bool) { self.bigEndian = bigEndian }

    func image(
        rows: Int, columns: Int, values: [Double],
        origin: (Double, Double), scale: (Double, Double)
    ) -> TIFFBuilder {
        var copy = self
        copy.rows = rows; copy.columns = columns; copy.values = values
        copy.origin = origin; copy.scale = scale
        return copy
    }

    func compression(_ value: Int) -> TIFFBuilder {
        var copy = self
        copy.compressionValue = value
        return copy
    }

    func build() -> Data {
        var out = Data()
        func put16(_ value: UInt16) {
            out.append(contentsOf: bigEndian ? [UInt8(value >> 8), UInt8(value & 0xFF)]
                                             : [UInt8(value & 0xFF), UInt8(value >> 8)])
        }
        func put32(_ value: UInt32) {
            let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
                         UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
            out.append(contentsOf: bigEndian ? bytes : bytes.reversed())
        }
        func putDouble(_ value: Double) {
            let bits = value.bitPattern
            let bytes = (0..<8).map { UInt8((bits >> (56 - 8 * $0)) & 0xFF) }
            out.append(contentsOf: bigEndian ? bytes : bytes.reversed())
        }

        // Header.
        out.append(contentsOf: bigEndian ? [0x4D, 0x4D] : [0x49, 0x49])
        put16(42)
        put32(8)

        let entryCount = 10
        // Directory, then the values that do not fit in it, then the pixels.
        let directoryBytes = 2 + entryCount * 12 + 4
        let transformationOffset = 8 + directoryBytes
        let pixelOffset = transformationOffset + 16 * 8

        put16(UInt16(entryCount))
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ payload: UInt32) {
            put16(tag); put16(type); put32(count)
            // A SHORT that fits sits in the high half of the four bytes on a
            // big-endian file and the low half on a little-endian one.
            if type == 3, count == 1 {
                if bigEndian { put32(payload << 16) } else { put32(payload) }
            } else {
                put32(payload)
            }
        }
        entry(256, 3, 1, UInt32(columns))            // ImageWidth
        entry(257, 3, 1, UInt32(rows))               // ImageLength
        entry(258, 3, 1, 32)                         // BitsPerSample
        entry(259, 3, 1, UInt32(compressionValue))   // Compression
        entry(262, 3, 1, 1)                          // Photometric
        entry(273, 4, 1, UInt32(pixelOffset))        // StripOffsets
        entry(277, 3, 1, 1)                          // SamplesPerPixel
        entry(278, 3, 1, UInt32(rows))               // RowsPerStrip
        entry(339, 3, 1, 3)                          // SampleFormat: float
        entry(34264, 12, 16, UInt32(transformationOffset))  // ModelTransformation
        put32(0)                                     // no next directory

        for value in [
            scale.0, 0, 0, origin.0,
            0, -scale.1, 0, origin.1,
            0, 0, 0, 0,
            0, 0, 0, 1,
        ] { putDouble(value) }

        for value in values {
            let bits = Float(value).bitPattern
            let bytes = [UInt8(bits >> 24 & 0xFF), UInt8(bits >> 16 & 0xFF),
                         UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
            out.append(contentsOf: bigEndian ? bytes : bytes.reversed())
        }
        return out
    }
}
