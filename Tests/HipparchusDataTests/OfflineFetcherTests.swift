import Foundation
import XCTest
@testable import HipparchusData

/// That `--offline` actually refuses, rather than being documented to.
///
/// **These exist because the last thing to claim this did not do it.** The UI
/// tests set a `HIPPARCHUS_UI_TESTS` environment variable for as long as they had
/// existed, and `LaunchedApp` described it as launching the application offline —
/// "a layout test that fetches is a test of somebody else's server". Nothing read
/// the variable. The suite went on being described as offline while every
/// provider in it held a live `URLSessionFetcher`, and the proof was sitting in
/// the tests themselves: `LaunchOrderTests` identified the Locator by a button
/// titled "Europe", which is a rendered MapKit label and could only ever have
/// been there because tiles had come down off the network.
///
/// A switch nothing reads is worse than no switch, because it reads in the source
/// like a guarantee and gets designed against. So the switch is real now, and
/// these are what keep it real.
final class OfflineFetcherTests: XCTestCase {

    private let url = URL(string: "https://example.invalid/tiles/1/2/3.png")!

    /// The refusal is the whole point, so it is asserted rather than assumed.
    func testAnOfflineFetcherRefusesToGet() async {
        let fetcher = URLSessionFetcher(isOffline: true)
        do {
            _ = try await fetcher.data(from: url, timeout: 5)
            XCTFail("an offline fetcher performed a GET")
        } catch let error as HTTPError {
            XCTAssertEqual(error.url, url)
            XCTAssertTrue(
                error.description.contains("--offline"),
                "the refusal should say why it refused, not just that it failed: \(error)"
            )
        } catch {
            XCTFail("expected an HTTPError naming --offline, got \(error)")
        }
    }

    /// Overpass is the one caller that posts, so it is the one that would slip
    /// through a guard written only on the GET path.
    func testAnOfflineFetcherRefusesToPost() async {
        let fetcher = URLSessionFetcher(isOffline: true)
        do {
            _ = try await fetcher.post(["data": "[out:json];"], to: url, timeout: 5)
            XCTFail("an offline fetcher performed a POST")
        } catch let error as HTTPError {
            XCTAssertTrue(
                error.description.contains("--offline"),
                "the refusal should say why it refused: \(error)"
            )
        } catch {
            XCTFail("expected an HTTPError naming --offline, got \(error)")
        }
    }

    /// **The half that stops this being a test of nothing.** A fetcher that
    /// refused everything would pass the two above and break the application, so
    /// the default has to be shown to still be a working one. It is not asked to
    /// reach the network — that would be the flaky test this whole flag exists to
    /// prevent — only to not refuse before it tries.
    func testAFetcherThatWasNotToldToBeOfflineDoesNotRefuse() async {
        let fetcher = URLSessionFetcher(isOffline: false)
        do {
            _ = try await fetcher.data(from: url, timeout: 1)
            // A response would be a surprise from a .invalid host, but it is not
            // this test's business either way.
        } catch let error as HTTPError where error.description.contains("--offline") {
            XCTFail("a fetcher that was not told to be offline refused anyway")
        } catch {
            // Any other failure is the network declining to resolve
            // example.invalid, which is exactly what should happen.
        }
    }

    /// The process running these was not launched with the flag, so the property
    /// every provider defaults to must be off. If this ever fails, the whole
    /// suite has quietly stopped being able to reach its stubs' real counterparts.
    func testTheProcessDefaultReflectsThisRunsArguments() {
        XCTAssertEqual(
            URLSessionFetcher.launchedOffline,
            ProcessInfo.processInfo.arguments.contains("--offline")
        )
    }
}
