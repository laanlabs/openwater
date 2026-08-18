import XCTest
@testable import OpenWaterCore

/// The planned-route geometry, pinned before any UI leans on it.
///
/// The reference route is Viento → Hood River: two legs down the Columbia,
/// real coordinates, so the numbers here mean something on a chart. The
/// properties pinned are the ones the route-weather feature will silently
/// trust: cumulative distances match the leg sums, a point N metres along
/// round-trips through the same forward projection, sampling honors its cap
/// and always keeps both ends, and progress clamps rather than wandering
/// off either end of the line.
final class RoutePathTests: XCTestCase {

    // Viento State Park → Mid-river bend → Hood River Event Site.
    private let viento = Geo.Coordinate(latitude: 45.6970, longitude: -121.7930)
    private let midRiver = Geo.Coordinate(latitude: 45.7080, longitude: -121.6300)
    private let eventSite = Geo.Coordinate(latitude: 45.7120, longitude: -121.5150)

    private var path: RoutePath {
        RoutePath(waypoints: [viento, midRiver, eventSite])
    }

    func testCumulativeDistanceMatchesLegSums() {
        let legOne = Geo.distance(viento, midRiver)
        let legTwo = Geo.distance(midRiver, eventSite)
        XCTAssertEqual(path.cumulativeDistance.count, 3)
        XCTAssertEqual(path.cumulativeDistance[0], 0)
        XCTAssertEqual(path.cumulativeDistance[1], legOne, accuracy: 0.5)
        XCTAssertEqual(path.totalDistance, legOne + legTwo, accuracy: 1.0)
        // A real downwinder distance — sanity that the coordinates are real.
        XCTAssertGreaterThan(path.totalDistance, 15_000)
        XCTAssertLessThan(path.totalDistance, 30_000)
    }

    func testZeroLengthLegsAreDropped() {
        let doubled = RoutePath(waypoints: [viento, viento, midRiver, midRiver, eventSite])
        XCTAssertEqual(doubled.waypoints.count, 3)
        XCTAssertEqual(doubled.totalDistance, path.totalDistance, accuracy: 0.1)
    }

    func testCoordinateAtDistanceRoundTrips() {
        // A point placed 5 km along must sit 5 km from the start when the
        // distance is walked back leg by leg.
        let metres = 5000.0
        guard let there = path.coordinate(atDistance: metres) else {
            return XCTFail("no coordinate on a real route")
        }
        // 5 km is inside leg one, so straight-line from Viento equals the
        // along-route distance.
        XCTAssertEqual(Geo.distance(viento, there), metres, accuracy: 5)
    }

    func testCoordinateClampsToEnds() {
        XCTAssertEqual(path.coordinate(atDistance: -500), viento)
        let end = path.coordinate(atDistance: path.totalDistance + 9999)
        XCTAssertEqual(Geo.distance(end ?? viento, eventSite), 0, accuracy: 0.5)
    }

    func testBearingFollowsTheLegs() {
        let early = path.bearing(atDistance: 1000)
        let late = path.bearing(atDistance: path.totalDistance - 1000)
        XCTAssertEqual(early ?? 0, Geo.bearing(from: viento, to: midRiver), accuracy: 0.1)
        XCTAssertEqual(late ?? 0, Geo.bearing(from: midRiver, to: eventSite), accuracy: 0.1)
    }

    func testSamplingHonorsCapAndKeepsEnds() {
        let samples = path.sampled(every: 2000, maxPoints: 12)
        XCTAssertLessThanOrEqual(samples.count, 12)
        XCTAssertGreaterThanOrEqual(samples.count, 2)
        XCTAssertEqual(samples.first?.distance ?? -1, 0)
        XCTAssertEqual(samples.last?.distance ?? -1, path.totalDistance, accuracy: 0.5)
        XCTAssertEqual(Geo.distance(samples.last!.coordinate, eventSite), 0, accuracy: 1)

        // A short hop under the spacing still yields its two endpoints.
        let hop = RoutePath(waypoints: [viento, midRiver])
        XCTAssertEqual(hop.sampled(every: 50_000, maxPoints: 12).count, 2)

        // The cap wins over the spacing: a long route at tight spacing.
        let tight = path.sampled(every: 100, maxPoints: 12)
        XCTAssertEqual(tight.count, 12)
    }

    func testProgressClampsAndArrives() {
        let start = Date(timeIntervalSince1970: 1_755_000_000)
        // 14 kn ≈ 7.2 m/s, a wingfoil cruise.
        let progress = RouteProgress(path: path, departure: start,
                                     speed: .assumed(metresPerSecond: 7.2))

        // Before departure: parked at the start.
        XCTAssertEqual(progress.distance(at: start.addingTimeInterval(-3600)), 0)
        // Mid-run: distance is elapsed × speed.
        XCTAssertEqual(progress.distance(at: start.addingTimeInterval(600)),
                       7.2 * 600, accuracy: 0.001)
        // Long after: parked at the finish, and the ETA agrees.
        XCTAssertEqual(progress.distance(at: start.addingTimeInterval(86_400)),
                       path.totalDistance)
        XCTAssertEqual(progress.eta.timeIntervalSince(start),
                       path.totalDistance / 7.2, accuracy: 0.001)
    }

    func testAbsurdSpeedIsGuarded() {
        let progress = RouteProgress(path: path, departure: Date(timeIntervalSince1970: 0),
                                     speed: .assumed(metresPerSecond: -3))
        // A negative speed is floored, never a time machine.
        XCTAssertGreaterThanOrEqual(
            progress.distance(at: Date(timeIntervalSince1970: 60)), 0)
        XCTAssertTrue(progress.eta > Date(timeIntervalSince1970: 0))
    }
}
