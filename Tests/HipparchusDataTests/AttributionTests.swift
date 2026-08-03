import XCTest
@testable import HipparchusData

/// What a sheet owes the people whose data drew it.
///
/// The first of these is the one that matters. Attribution used to be a
/// hand-written paragraph in one window, and every source added was one somebody
/// had to remember to type there — four marine sources arrived in a day and
/// NOAA's two were simply missing. **A test is the only thing that turns
/// "remember to" into "cannot forget".**
final class AttributionTests: XCTestCase {

    // MARK: - The check that earns the registry

    /// Every source this application ships either owes a credit or is recorded
    /// as owing none. There is no third state, and "nobody added it yet" is not
    /// one.
    func testEverySourceIsEitherCreditedOrExplicitlyExempt() {
        for source in AttributionRegistry.shippedSources {
            let credited = AttributionRegistry.attribution(forSource: source) != nil
            let exempt = AttributionRegistry.exempt.contains(source)
            XCTAssertTrue(
                credited || exempt,
                "\(source) has no attribution and is not declared exempt — "
                    + "add it to AttributionRegistry.all or to .exempt"
            )
            XCTAssertFalse(credited && exempt, "\(source) is both credited and exempt")
        }
    }

    /// The registry may not credit something that is not a shipped source: an
    /// entry left behind by a removed provider is a claim about data this
    /// application no longer uses.
    func testTheRegistryDoesNotCreditSourcesThatAreNotShipped() {
        for entry in AttributionRegistry.all {
            XCTAssertTrue(
                AttributionRegistry.shippedSources.contains(entry.sourceID),
                "\(entry.sourceID) is credited but is not a shipped source"
            )
        }
    }

    /// The four sources whose absence prompted this. Named individually rather
    /// than counted, because a count passes when the wrong four are present.
    func testTheMarineSourcesAreAllCredited() {
        for source in [
            emodnetBathymetrySourceID,
            SourceID.seaTemperature,
            SourceID.currents,
        ] {
            XCTAssertNotNil(
                AttributionRegistry.attribution(forSource: source),
                "\(source) is uncredited"
            )
        }
    }

    /// A credit with no statement, no licence or no address is not a credit.
    func testEveryEntryIsComplete() {
        for entry in AttributionRegistry.all + AttributionRegistry.tools {
            XCTAssertFalse(entry.name.isEmpty, "\(entry.sourceID) has no name")
            XCTAssertFalse(entry.statement.isEmpty, "\(entry.sourceID) has no statement")
            XCTAssertFalse(entry.licence.isEmpty, "\(entry.sourceID) names no licence")
            XCTAssertTrue(
                entry.url.hasPrefix("https://"), "\(entry.sourceID) has no usable address"
            )
        }
    }

    /// OpenStreetMap's licence is the one with actual teeth here, and it asks
    /// for particular words.
    func testOpenStreetMapGetsTheWordsItsLicenceAsksFor() throws {
        let osm = try XCTUnwrap(AttributionRegistry.attribution(forSource: SourceID.overpass))
        XCTAssertTrue(osm.statement.contains("OpenStreetMap contributors"))
        XCTAssertTrue(osm.licence.contains("ODbL"))
    }

    // MARK: - What a particular sheet owes

    /// A sheet credits what it used. Padding the list with sources that drew
    /// nothing makes the true entries harder to trust.
    func testASheetCreditsOnlyWhatItUsed() {
        let credits = AttributionRegistry.attributions(
            forSources: [SourceID.terrainTiles, SourceID.overpass]
        )
        let names = credits.map(\.sourceID)
        XCTAssertEqual(Set(names), [SourceID.terrainTiles, SourceID.overpass])
        XCTAssertFalse(names.contains(emodnetBathymetrySourceID))
    }

    /// Two datasets from one server are still two credits.
    ///
    /// It is tempting to collapse them — both arrive through NOAA CoastWatch
    /// ERDDAP — but **the server is not the source**. MUR is NASA JPL's analysis
    /// and the currents are NOAA/NESDIS's, so merging them would drop a producer
    /// on the grounds that somebody else hosts their data.
    func testTwoDatasetsFromOneServerAreStillTwoCredits() {
        let statement = AttributionRegistry.statement(
            forSources: [SourceID.seaTemperature, SourceID.currents]
        )
        XCTAssertTrue(statement.contains("NASA JPL MUR"), statement)
        XCTAssertTrue(statement.contains("NOAA/NESDIS"), statement)
    }

    /// What dedup is actually for: the same statement twice, which is a repeat
    /// rather than two producers.
    func testAnIdenticalStatementIsNotRepeated() {
        let doubled = AttributionRegistry.attributions(
            forSources: [SourceID.overpass, SourceID.overpass]
        )
        XCTAssertEqual(doubled.count, 1)
    }

    /// A source nobody has registered is dropped, not guessed at. An invented
    /// credit is worse than a missing one, because it is wrong on purpose.
    func testAnUnknownSourceIsDroppedRatherThanInvented() {
        XCTAssertTrue(
            AttributionRegistry.attributions(forSources: ["some_future_thing"]).isEmpty
        )
    }

    /// A generated field owes nobody anything, and an empty statement is how a
    /// caller tells that from a failure.
    func testASheetThatOwesNothingSaysNothing() {
        XCTAssertEqual(
            AttributionRegistry.statement(forSources: [SourceID.simulatedTerrain]), ""
        )
        XCTAssertEqual(AttributionRegistry.statement(forSources: []), "")
    }

    /// The registry's order is the reading order, not the order providers were
    /// written in, and it should not depend on the order a caller asks.
    func testTheOrderIsTheRegistrysAndNotTheCallers() {
        let forwards = AttributionRegistry.attributions(
            forSources: [SourceID.overpass, SourceID.usgsEarthquakes]
        )
        let backwards = AttributionRegistry.attributions(
            forSources: [SourceID.usgsEarthquakes, SourceID.overpass]
        )
        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards.first?.sourceID, SourceID.overpass)
    }
}
