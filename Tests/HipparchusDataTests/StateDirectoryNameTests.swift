import XCTest
@testable import HipparchusData

/// Which directory a launch owns.
///
/// This exists because a UI test run is a second copy of the application, and
/// before the flag existed it wrote its session, preferences, saved styles and
/// cache straight over the real ones. The flag that redirects it names a
/// directory, so the checks here are mostly about what a directory name is *not*
/// allowed to be.
final class StateDirectoryNameTests: XCTestCase {

    private func resolve(_ arguments: [String]) -> String {
        StateDirectoryName.resolve(from: arguments)
    }

    // MARK: - The ordinary path

    /// No flag means the real state, which is the case that must never break.
    func testWithoutTheFlagItIsTheRealDirectory() {
        XCTAssertEqual(resolve([]), "Hipparchus")
        XCTAssertEqual(resolve(["--preset", "Coastal Survey"]), "Hipparchus")
    }

    func testTheFlagNamesTheDirectory() {
        XCTAssertEqual(resolve(["--state-directory", "HipparchusUITests-1"]), "HipparchusUITests-1")
    }

    func testItIsFoundAmongOtherArguments() {
        let arguments = ["--preset", "Blueprint", "--state-directory", "scratch", "--locator"]
        XCTAssertEqual(resolve(arguments), "scratch")
    }

    func testSurroundingSpaceIsIgnored() {
        XCTAssertEqual(resolve(["--state-directory", "  scratch  "]), "scratch")
    }

    // MARK: - What a directory name may not be

    /// A separator would let the flag write anywhere on disk.
    func testAPathIsRefused() {
        XCTAssertEqual(resolve(["--state-directory", "a/b"]), "Hipparchus")
        XCTAssertEqual(resolve(["--state-directory", "/etc"]), "Hipparchus")
        XCTAssertEqual(resolve(["--state-directory", "a\\b"]), "Hipparchus")
    }

    /// `..` is the same problem spelled differently, and it is the one somebody
    /// reaches for deliberately.
    func testTraversalIsRefused() {
        XCTAssertEqual(resolve(["--state-directory", ".."]), "Hipparchus")
        XCTAssertEqual(resolve(["--state-directory", "..foo"]), "Hipparchus")
        XCTAssertEqual(resolve(["--state-directory", "foo..bar"]), "Hipparchus")
    }

    /// An empty name would mean Application Support *itself*, which holds every
    /// other application's data.
    func testAnEmptyNameIsRefused() {
        XCTAssertEqual(resolve(["--state-directory", ""]), "Hipparchus")
        XCTAssertEqual(resolve(["--state-directory", "   "]), "Hipparchus")
    }

    /// A leading dot only hides the directory from the person who would
    /// otherwise notice it.
    func testAHiddenNameIsRefused() {
        XCTAssertEqual(resolve(["--state-directory", ".hidden"]), "Hipparchus")
        XCTAssertEqual(resolve(["--state-directory", "."]), "Hipparchus")
    }

    func testANullByteIsRefused() {
        XCTAssertEqual(resolve(["--state-directory", "a\0b"]), "Hipparchus")
    }

    /// A flag with nothing after it is a typo, not an instruction.
    func testAFlagWithNoValueFallsBack() {
        XCTAssertEqual(resolve(["--state-directory"]), "Hipparchus")
    }

    // MARK: - Knowing which one you are in

    /// The UI tests assert this before anything else runs: a suite that
    /// silently lost its isolation would eat the user's work on the next run
    /// rather than failing.
    func testIsolationIsRecognisable() {
        XCTAssertFalse(StateDirectoryName.isIsolated("Hipparchus"))
        XCTAssertTrue(StateDirectoryName.isIsolated("HipparchusUITests-7"))
    }

    /// Every refusal must land somewhere the application can actually run, not
    /// merely somewhere different.
    func testEveryRefusalLandsOnTheRealDirectory() {
        for bad in ["", " ", "/", "..", ".", ".x", "a/b", "a\\b", "x..y", "a\0b"] {
            XCTAssertEqual(
                resolve(["--state-directory", bad]), "Hipparchus",
                "\(bad.debugDescription) should fall back"
            )
        }
    }
}
