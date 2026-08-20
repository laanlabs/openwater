import CoreLocation
import MapKit
import XCTest
@testable import openWater

/// The bundled coastline, checked against water people actually sail on.
///
/// San Francisco Bay is the fixture on purpose. It is the case the two earlier
/// masks both failed — an eleven-kilometre sample cannot tell the bay from the
/// hills either side of it — and it has the properties that catch the mistakes
/// worth catching: land north *and* south of open water, so a vertically
/// flipped raster shows up immediately; a strait 1.6 km wide that must stay
/// open; and islands in the middle of it that must not.
final class CoastlineTests: XCTestCase {

    /// A generous box around the bay, the Gate and the ocean outside it.
    private let bay = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.85, longitude: -122.40),
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))

    private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The asset is in the bundle at all. Everything below is vacuous without
    /// it, and the failure mode in the app — no mask, wash over everything —
    /// is quiet enough that only this would catch a build that dropped it.
    func testCoastlineShips() {
        XCTAssertTrue(Coastline.isAvailable,
                      "coastline.bin missing from the bundle — see scripts/build-coastline.py")
    }

    func testBayWaterIsWaterAndTheHillsAreNot() throws {
        try XCTSkipUnless(Coastline.isAvailable)
        let mask = Coastline.mask(for: bay)
        XCTAssertFalse(mask.isEmpty)

        let water = [
            ("bay north of the Bay Bridge", 37.8500, -122.3500),
            ("central bay", 37.7800, -122.3300),
            ("San Pablo Bay", 38.0700, -122.4200),
            ("off Crissy Field", 37.8120, -122.4650),
            ("Ocean Beach", 37.7600, -122.5200),
        ]
        for (name, latitude, longitude) in water {
            XCTAssertEqual(mask.isWater(coordinate(latitude, longitude)), true, "\(name) should be water")
        }

        let land = [
            ("downtown San Francisco", 37.7879, -122.4075),
            ("the Marin hills", 37.9200, -122.5800),
            ("downtown Oakland", 37.8044, -122.2712),
            ("Angel Island", 37.8600, -122.4300),
        ]
        for (name, latitude, longitude) in land {
            XCTAssertEqual(mask.isWater(coordinate(latitude, longitude)), false, "\(name) should be land")
        }
    }

    /// The raster is drawn in Core Graphics' space, whose origin is at the
    /// bottom, into a buffer whose first row is the top. Get the flip wrong and
    /// the mask is a coastline upside down — which still looks plausible on a
    /// map, and is wrong everywhere.
    ///
    /// These two are picked to be unambiguous under a flip: land in the north,
    /// open ocean in the south, at nearly the same longitude.
    func testRasterIsNotVerticallyFlipped() throws {
        try XCTSkipUnless(Coastline.isAvailable)
        let mask = Coastline.mask(for: bay)
        XCTAssertEqual(mask.isWater(coordinate(37.9200, -122.5800)), false, "north: Marin hills")
        XCTAssertEqual(mask.isWater(coordinate(37.7300, -122.5600)), true, "south: open Pacific")
    }

    /// The Golden Gate is 1.6 km wide and has the fastest water in the bay
    /// running through it. A generalised shoreline that closed it would put a
    /// wall across the one place this layer exists to describe.
    func testTheGoldenGateStaysOpen() throws {
        try XCTSkipUnless(Coastline.isAvailable)
        let mask = Coastline.mask(for: bay)
        XCTAssertEqual(mask.isWater(coordinate(37.8199, -122.4783)), true)
    }

    /// Outside the rasterized rectangle is "not known", never "land" — the
    /// wash paints where it has no answer, and a false "land" there would eat
    /// the field instead of leaving it alone.
    func testOutsideTheRegionIsUnknown() throws {
        try XCTSkipUnless(Coastline.isAvailable)
        let mask = Coastline.mask(for: bay)
        XCTAssertNil(mask.isWater(coordinate(21.28, -157.83)), "Honolulu is not in this raster")
        XCTAssertNil(mask.isWater(coordinate(37.85, -130.00)))
    }

    /// The empty mask answers nothing at all, which is what the wash falls back
    /// to when the switch is off or the asset is missing.
    func testEmptyMaskKnowsNothing() {
        let mask = WaterMask()
        XCTAssertTrue(mask.isEmpty)
        XCTAssertNil(mask.isWater(coordinate(37.85, -122.35)))
    }

    /// A region far out to sea has no land in it, and must come back all water
    /// rather than empty — "no polygons here" is an answer, not a failure.
    func testOpenOceanIsAllWater() throws {
        try XCTSkipUnless(Coastline.isAvailable)
        let pacific = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 30, longitude: -140),
            span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        let mask = Coastline.mask(for: pacific)
        XCTAssertFalse(mask.isEmpty)
        XCTAssertEqual(mask.isWater(coordinate(30, -140)), true)
        XCTAssertEqual(mask.isWater(coordinate(29.5, -140.5)), true)
    }

    /// A whole-coast view still resolves the coast. The old mask fell to
    /// eleven-kilometre samples exactly here; this one draws the same
    /// shoreline at any zoom, because the shape is bundled rather than sampled.
    func testWideViewStillSeparatesLandFromSea() throws {
        try XCTSkipUnless(Coastline.isAvailable)
        let california = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.0, longitude: -121.5),
            span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6))
        let mask = Coastline.mask(for: california)
        XCTAssertEqual(mask.isWater(coordinate(36.6, -123.5)), true, "open Pacific")
        XCTAssertEqual(mask.isWater(coordinate(36.8, -119.8)), false, "the Central Valley")
    }
}
