import XCTest
@testable import openWater

/// The Spots map clock: an offset of +N hours means the top of *that* hour.
final class MapClockTests: XCTestCase {

    func testAnHourAheadIsTheTopOfTheHourAhead() throws {
        let now = Date()
        let instant = try XCTUnwrap(MapClock.instant(hoursFromNow: 1))
        let expected = try XCTUnwrap(Calendar.current.dateInterval(of: .hour, for: now.addingTimeInterval(3600))?.start)
        // Tolerant of the test straddling a minute boundary, not an hour one.
        XCTAssertEqual(instant.timeIntervalSince(expected), 0, accuracy: 1)
        XCTAssertLessThanOrEqual(instant, now.addingTimeInterval(3600),
                                 "the top of the hour ahead is never later than an hour from now")
        XCTAssertGreaterThan(instant, now)
    }

    func testNowIsNil() {
        XCTAssertNil(MapClock.instant(hoursFromNow: 0))
    }
}
