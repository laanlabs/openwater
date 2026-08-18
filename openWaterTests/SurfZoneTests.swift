import OpenWaterCore
import XCTest
@testable import openWater

/// The surf zone parser, pinned against the product's real shape — a
/// trimmed copy of an actual OKX Surf Zone Forecast (captured 2026-08-18):
/// an office-wide text, zone blocks split by `$$`, each opening with codes
/// like "NYZ075-180900-", the area's name, sometimes its beaches, then the
/// forecaster's day sections, then a `&&` footer explaining categories.
final class SurfZoneTests: XCTestCase {

    private let product = """
    000
    FZUS51 KOKX 180004
    SRFOKX

    Surf Zone Forecast for New York
    National Weather Service New York NY
    804 PM EDT Mon Aug 17 2026

    NYZ075-180900-
    Kings (Brooklyn)-
    Including the beaches of Coney Island Beach and Manhattan Beach
    804 PM EDT Mon Aug 17 2026

    .TUESDAY...
    Rip Current Risk............Moderate.
    Surf Height.................Around 2 feet.

    &&

    Rip Current Risk Categories:
    * Low Risk - blah.

    $$

    NYZ081-180900-
    Southeast Suffolk-
    Including the beaches of Montauk Point and Hither Hills
    804 PM EDT Mon Aug 17 2026

    .TUESDAY...
    Rip Current Risk............High.
    Surf Height.................3 to 5 feet.

    &&

    $$
    """

    func testPicksTheZoneTheBeachSitsIn() {
        let forecast = NationalWeatherService.parseSurfZone(
            product: product, issued: Date(), zone: "NYZ081")
        XCTAssertNotNil(forecast)
        XCTAssertEqual(forecast?.office, "National Weather Service New York NY")
        XCTAssertTrue(forecast?.area?.contains("Southeast Suffolk") ?? false)
        XCTAssertTrue(forecast?.area?.contains("Montauk Point") ?? false)
        XCTAssertTrue(forecast?.text.contains("High") ?? false)
        XCTAssertTrue(forecast?.text.hasPrefix(".TUESDAY") ?? false,
                      "the quote starts at the forecaster's first day section")
        XCTAssertFalse(forecast?.text.contains("Categories") ?? true,
                       "the categories footer stays out of the quote")
    }

    func testUnknownZoneFallsBackToTheFirstBlock() {
        let forecast = NationalWeatherService.parseSurfZone(
            product: product, issued: Date(), zone: "CTZ999")
        XCTAssertTrue(forecast?.area?.contains("Brooklyn") ?? false,
                      "a forecast for the neighbouring beach beats none")
    }

    func testNoZoneBlocksMeansNoCard() {
        XCTAssertNil(NationalWeatherService.parseSurfZone(
            product: "AFDOKX\nJust a discussion, no zones here.",
            issued: Date(), zone: nil))
    }
}
