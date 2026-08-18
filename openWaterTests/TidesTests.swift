import OpenWaterCore
import XCTest
@testable import openWater

/// The harmonic tide curve's parser, pinned against the real wire format.
///
/// The fixture is a trimmed copy of an actual CO-OPS `predictions` response
/// (Montauk, 8510560, captured 2026-08-18): six-minute rows whose values
/// are strings, on the station's local clock. The property that matters
/// most is the thinning — six-minute harmonics hold the same value across
/// a flat tide top, and the turn detector reads a plateau's two ends as
/// two high waters; every fifth row keeps the curve honest.
final class TidesTests: XCTestCase {

    func testWaterLevelParseThinsToHalfHours() {
        let rows = (0..<11).map { index in
            let minutes = index * 6
            let stamp = String(format: "%02d:%02d", minutes / 60, minutes % 60)
            return "{\"t\":\"2026-08-17 \(stamp)\", \"v\":\"0.6\(index)\"}"
        }
        let fixture = "{ \"predictions\" : [\(rows.joined(separator: ","))]}"

        let points = TidesAndCurrents.parseWaterLevel(Data(fixture.utf8))
        // Indices 0, 5 and 10 survive: one point every thirty minutes.
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].metres, 0.60, accuracy: 0.0001)
        XCTAssertEqual(points[1].metres, 0.65, accuracy: 0.0001)
        XCTAssertEqual(points[2].metres, 0.610, accuracy: 0.0001)
        XCTAssertEqual(points[1].at.timeIntervalSince(points[0].at), 1800, accuracy: 1)
    }

    /// The station curve carries its authority; the model curve carries
    /// its default — the caption switches on exactly this.
    func testCurveSourceDefaultsToModel() {
        XCTAssertEqual(TideCurve(points: []).source, .model)
        let station = TideCurve(points: [],
                                source: .station(name: "Montauk", metres: 1200))
        XCTAssertEqual(station.source, .station(name: "Montauk", metres: 1200))
    }
}
